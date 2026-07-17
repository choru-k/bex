import Foundation
import XCTest

@testable import Bex

final class DomainStorageRegressionTests: XCTestCase {
  func testGrammarParserUsesDefaultExplanationAndFirstDuplicatedObject() throws {
    XCTAssertEqual(
      try GrammarResponseParser.parse(#"{"corrected":"Ready"}"#),
      GrammarResult(corrected: "Ready", explanation: "No explanation provided.")
    )
    let first = #"{"corrected":"First","explanation":"One"}"#
    let second = #"{"corrected":"Second","explanation":"Two"}"#
    XCTAssertEqual(
      try GrammarResponseParser.parse(first + second),
      GrammarResult(corrected: "First", explanation: "One")
    )
  }

  func testProviderDefaultsUseRequestedFrontierModels() {
    XCTAssertEqual(LLMProvider.openAI.defaultModel, "gpt-5.6-sol")
    XCTAssertEqual(LLMProvider.openAICodex.defaultModel, "gpt-5.6-sol")
    XCTAssertEqual(LLMProvider.claude.defaultModel, "claude-opus-4-8")
    XCTAssertEqual(LLMProvider.gemini.defaultModel, "gemini-3.5-flash")
    XCTAssertEqual(LLMProvider.ollama.defaultModel, "llama3.3")
  }

  func testReasoningEffortPersistsPerProviderWithMediumDefault() async throws {
    let suite = "com.bex.tests.reasoning-effort.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)

    let defaultOpenAIEffort = await preferences.selectedEffort(for: .openAI)
    XCTAssertEqual(defaultOpenAIEffort, .medium)

    await preferences.setSelectedEffort(.high, for: .openAI)
    await preferences.setSelectedEffort(.low, for: .gemini)

    let openAIEffort = await preferences.selectedEffort(for: .openAI)
    let geminiEffort = await preferences.selectedEffort(for: .gemini)
    let claudeEffort = await preferences.selectedEffort(for: .claude)
    XCTAssertEqual(openAIEffort, .high)
    XCTAssertEqual(geminiEffort, .low)
    XCTAssertEqual(claudeEffort, .medium)
  }

  func testRetiredCodexModelMigratesToSupportedDefault() async throws {
    let suite = "com.bex.tests.codex-model-migration.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let key = "selectedModel.\(LLMProvider.openAICodex.rawValue)"
    defaults.set("gpt-5.1-codex-mini", forKey: key)
    let preferences = PreferencesStore(defaults: defaults)

    let migrated = await preferences.selectedModel(for: .openAICodex)
    XCTAssertEqual(migrated, LLMProvider.openAICodex.defaultModel)
    let remigrated = await preferences.selectedModel(for: .openAICodex)
    XCTAssertEqual(remigrated, LLMProvider.openAICodex.defaultModel)

    await preferences.setSelectedModel("gpt-5.4", for: .openAICodex)
    let supported = await preferences.selectedModel(for: .openAICodex)
    XCTAssertEqual(supported, "gpt-5.4")
  }
  func testRetiredCloudProviderDefaultsMigrateToCurrentModels() async throws {
    for (provider, retiredModel) in [
      (LLMProvider.claude, "claude-opus-4-1-20250805"),
      (LLMProvider.gemini, "gemini-3-pro-preview"),
    ] {
      let suite = "com.bex.tests.model-migration.\(provider.rawValue).\(UUID())"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
      let preferences = PreferencesStore(defaults: defaults)
      await preferences.setSelectedModel(retiredModel, for: provider)

      let migrated = await preferences.selectedModel(for: provider)

      XCTAssertEqual(migrated, provider.defaultModel)
    }
  }

  func testWordDiffHandlesBothEmptyInputBoundaries() {
    let inserted = WordDiff.compute(original: "", corrected: "new text")
    XCTAssertEqual(inserted, [DiffSegment(text: "new text", kind: .inserted)])

    let removed = WordDiff.compute(original: "old text", corrected: "")
    XCTAssertEqual(removed, [DiffSegment(text: "old text", kind: .removed)])

    XCTAssertEqual(WordDiff.compute(original: "", corrected: ""), [])
  }

  func testRealKeychainCRUDUsesIsolatedService() async throws {
    let service = "com.bex.desktop.tests.\(UUID().uuidString)"
    let keychain = KeychainStore(service: service)
    let providers: [LLMProvider] = [.openAI, .claude, .gemini]

    for provider in providers {
      try await keychain.deleteAPIKey(for: provider)
    }
    try await keychain.deleteCodexSession()
    addTeardownBlock {
      for provider in providers {
        try? await keychain.deleteAPIKey(for: provider)
      }
      try? await keychain.deleteCodexSession()
    }

    for provider in providers {
      let initialKey = try await keychain.apiKey(for: provider)
      XCTAssertNil(initialKey)
      try await keychain.saveAPIKey("\(provider.rawValue)-key", for: provider)
      let storedKey = try await keychain.apiKey(for: provider)
      XCTAssertEqual(storedKey, "\(provider.rawValue)-key")
      let hasSetup = try await keychain.hasSetup(for: provider)
      XCTAssertTrue(hasSetup)
      try await keychain.deleteAPIKey(for: provider)
      let deletedKey = try await keychain.apiKey(for: provider)
      XCTAssertNil(deletedKey)
    }

    let session = CodexSession(
      accessToken: "access",
      refreshToken: "refresh",
      expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
      accountID: "account"
    )
    let initialSession = try await keychain.codexSession()
    XCTAssertNil(initialSession)
    try await keychain.saveCodexSession(session)
    let storedSession = try await keychain.codexSession()
    XCTAssertEqual(storedSession, session)
    let hasCodexSetup = try await keychain.hasSetup(for: .openAICodex)
    XCTAssertTrue(hasCodexSetup)
    try await keychain.deleteCodexSession()
    let deletedSession = try await keychain.codexSession()
    XCTAssertNil(deletedSession)
    let hasOllamaSetup = try await keychain.hasSetup(for: .ollama)
    XCTAssertTrue(hasOllamaSetup)
  }

  func testHistoryIsNewestFirstAndPrunedToFiveHundred() async throws {
    let fixture = try StoreFixture(prefix: "BexHistoryLimitTests")
    defer { fixture.remove() }

    for index in 0...BexDataStore.historyLimit {
      try await fixture.store.appendHistory(historyEntry(index: index))
    }

    let history = try await fixture.store.loadHistory()
    XCTAssertEqual(history.count, BexDataStore.historyLimit)
    XCTAssertEqual(history.first?.corrected, "corrected-500")
    XCTAssertEqual(history.last?.corrected, "corrected-1")
    XCTAssertFalse(history.contains { $0.corrected == "corrected-0" })
  }

  func testNewerSchemaRemainsByteForByteUntouchedAndRejectsMutation() async throws {
    let fixture = try StoreFixture(prefix: "BexNewerSchemaTests")
    defer { fixture.remove() }
    let newerData = BexData(
      schemaVersion: BexDataStore.schemaVersion + 1,
      profiles: [Profile(id: UUID(), name: "Future", prompt: "Keep")],
      history: []
    )
    let encoded = try JSONEncoder().encode(newerData)
    try encoded.write(to: fixture.fileURL)
    let store = BexDataStore(fileURL: fixture.fileURL)

    let loadError = await capturedDomainError {
      _ = try await store.loadProfiles()
    }
    XCTAssertEqual(
      loadError,
      .storageFailure("This Bex data was created by a newer version.")
    )
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), encoded)

    let mutationError = await capturedDomainError {
      try await store.saveProfile(Profile(id: UUID(), name: "No", prompt: "Mutation"))
    }
    XCTAssertEqual(
      mutationError,
      .storageFailure("This Bex data was created by a newer version.")
    )
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), encoded)
  }

  func testAtomicReplacementFailurePreservesOriginalAndRemovesTemporaryFile() async throws {
    let fixture = try StoreFixture(prefix: "BexAtomicFailureTests")
    defer { fixture.remove() }
    let original = BexData(
      schemaVersion: BexDataStore.schemaVersion,
      profiles: [Profile(id: UUID(), name: "Original", prompt: "Keep")],
      history: []
    )
    let encoded = try JSONEncoder().encode(original)
    try encoded.write(to: fixture.fileURL)
    let store = BexDataStore(
      fileURL: fixture.fileURL,
      replaceExistingItem: { _, _, _ in
        throw CocoaError(.fileWriteUnknown)
      }
    )
    let loadedProfiles = try await store.loadProfiles()
    XCTAssertEqual(loadedProfiles, original.profiles)

    let error = await capturedDomainError {
      try await store.saveProfile(Profile(id: UUID(), name: "New", prompt: "Fail"))
    }

    XCTAssertEqual(
      error,
      .storageFailure("Bex could not save its local data.")
    )
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), encoded)
    let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
    XCTAssertFalse(files.contains { $0.hasPrefix(".data-") && $0.hasSuffix(".tmp") })
  }

  func testPreferencesAllowOneDefaultAndDeletionClearsActiveAndDefaultIDs() async {
    let suite = "com.bex.desktop.tests.preferences.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)
    let first = UUID()
    let second = UUID()

    await preferences.setDefaultProfileID(first)
    let firstDefaultID = await preferences.defaultProfileID()
    XCTAssertEqual(firstDefaultID, first)
    await preferences.setDefaultProfileID(second)
    let secondDefaultID = await preferences.defaultProfileID()
    XCTAssertEqual(secondDefaultID, second)

    await preferences.setActiveProfileID(second)
    await preferences.profileDeleted(id: second)
    let activeID = await preferences.activeProfileID()
    let defaultID = await preferences.defaultProfileID()
    XCTAssertNil(activeID)
    XCTAssertNil(defaultID)
  }

  private func historyEntry(index: Int) -> HistoryEntry {
    HistoryEntry(
      id: UUID(),
      original: "original-\(index)",
      corrected: "corrected-\(index)",
      explanation: "explanation-\(index)",
      provider: .openAI,
      model: LLMProvider.openAI.defaultModel,
      timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
      profileName: nil
    )
  }
}

private struct StoreFixture {
  let directory: URL
  let fileURL: URL
  let store: BexDataStore

  init(prefix: String) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent("data.json")
    store = BexDataStore(fileURL: fileURL)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private func capturedDomainError(
  _ operation: () async throws -> Void
) async -> BexError? {
  do {
    try await operation()
    return nil
  } catch let error as BexError {
    return error
  } catch {
    return nil
  }
}
