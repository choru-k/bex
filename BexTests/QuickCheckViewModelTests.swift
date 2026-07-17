import Foundation
import XCTest

@testable import Bex

actor QuickCheckGrammarStub: GrammarServicing {
  private var delayCheck = false

  func setDelayCheck(_ value: Bool) {
    delayCheck = value
  }

  func check(
    text: String,
    provider: LLMProvider,
    model: String,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    if delayCheck {
      try await Task.sleep(nanoseconds: 5_000_000_000)
    }
    return GrammarResult(
      corrected: "this is a test",
      explanation: "Changed subject-verb agreement."
    )
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    provider: LLMProvider,
    model: String
  ) async throws -> String {
    XCTAssertEqual(intent, .formal)
    return "This is a test."
  }

  func generateProfile(
    context: ProfileContext,
    provider: LLMProvider,
    model: String
  ) async throws -> String {
    "Generated profile"
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    [ModelOption(id: provider.defaultModel, name: provider.defaultModel)]
  }
}

@MainActor
final class RecordingPasteboard: PasteboardWriting {
  private(set) var value: String?

  func write(_ string: String) throws {
    value = string
  }
}

@MainActor
final class QuickCheckViewModelTests: XCTestCase {
  func testCheckCopyAndFormalRewriteUpdateOneHistoryEntry() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(
      fixture.viewModel.result,
      GrammarResult(
        corrected: "this is a test",
        explanation: "Changed subject-verb agreement."
      )
    )
    XCTAssertTrue(
      fixture.viewModel.diff.contains { $0.kind == .removed && $0.text == "are" }
    )
    XCTAssertTrue(
      fixture.viewModel.diff.contains { $0.kind == .inserted && $0.text == "is" }
    )

    var history = try await fixture.data.loadHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].original, "this are a test")
    XCTAssertEqual(history[0].corrected, "this is a test")
    XCTAssertEqual(history[0].explanation, "Changed subject-verb agreement.")

    fixture.viewModel.copy(closeAfter: false)
    XCTAssertEqual(fixture.pasteboard.value, "this is a test")

    fixture.viewModel.rewrite(.formal)
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.result?.corrected, "This is a test.")
    XCTAssertEqual(
      fixture.viewModel.result?.explanation,
      "Changed subject-verb agreement.\n\nRewrite applied: More Formal"
    )
    history = try await fixture.data.loadHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].corrected, "This is a test.")
    XCTAssertEqual(
      history[0].explanation,
      "Changed subject-verb agreement.\n\nRewrite applied: More Formal"
    )

    try await fixture.keychain.deleteAPIKey(for: .openAI)
  }

  func testCloseCancelsCheckWithoutErrorOrHistory() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }
    await fixture.grammar.setDelayCheck(true)

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    fixture.viewModel.close()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertNil(fixture.viewModel.result)
    XCTAssertNil(fixture.viewModel.userVisibleError)
    let history = try await fixture.data.loadHistory()
    XCTAssertTrue(history.isEmpty)

    try await fixture.keychain.deleteAPIKey(for: .openAI)
  }

  func testDebouncedDraftRestoresInNewViewModel() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "draft survives"
    try await Task.sleep(nanoseconds: 350_000_000)

    let restored = QuickCheckViewModel(
      preferences: fixture.preferences,
      keychain: fixture.keychain,
      data: fixture.data,
      grammar: fixture.grammar,
      pasteboard: fixture.pasteboard,
      onClose: {}
    )
    await restored.loadContext()
    XCTAssertEqual(restored.input, "draft survives")

    try await fixture.keychain.deleteAPIKey(for: .openAI)
  }

  private func makeFixture() async throws -> Fixture {
    let identifier = UUID().uuidString
    let suite = "com.bex.desktop.tests.quick-check.\(identifier)"
    let preferences = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexQuickCheckTests-\(identifier)")
    let data = BexDataStore(fileURL: directory.appendingPathComponent("data.json"))
    let keychain = KeychainStore(service: "com.bex.desktop.tests.quick-check.\(identifier)")
    try await keychain.saveAPIKey("test-key", for: .openAI)
    let grammar = QuickCheckGrammarStub()
    let pasteboard = RecordingPasteboard()
    let viewModel = QuickCheckViewModel(
      preferences: preferences,
      keychain: keychain,
      data: data,
      grammar: grammar,
      pasteboard: pasteboard,
      onClose: {}
    )
    return Fixture(
      suite: suite,
      directory: directory,
      preferences: preferences,
      keychain: keychain,
      data: data,
      grammar: grammar,
      pasteboard: pasteboard,
      viewModel: viewModel
    )
  }
}

@MainActor
private struct Fixture {
  let suite: String
  let directory: URL
  let preferences: PreferencesStore
  let keychain: KeychainStore
  let data: BexDataStore
  let grammar: QuickCheckGrammarStub
  let pasteboard: RecordingPasteboard
  let viewModel: QuickCheckViewModel

  func removeFiles() {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}
