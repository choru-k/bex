import Foundation
import XCTest

@testable import Bex

actor RecordingTransport: HTTPTransport {
  struct Stub: Sendable {
    let data: Data
    let status: Int
  }

  private var stubs: [Stub]
  private var requests: [URLRequest] = []

  init(stubs: [Stub]) {
    self.stubs = stubs
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let stub = stubs.removeFirst()
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.status,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    return (stub.data, response)
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }
}

final class ProviderParserDiffStorageTests: XCTestCase {
  func testGrammarParserAcceptsDirectFencedAndEmbeddedJSON() throws {
    let expected = GrammarResult(corrected: "This is a test.", explanation: "Fixed agreement.")
    let object = #"{"corrected":"This is a test.","explanation":"Fixed agreement."}"#

    XCTAssertEqual(try GrammarResponseParser.parse(object), expected)
    XCTAssertEqual(try GrammarResponseParser.parse("```json\n\(object)\n```"), expected)
    XCTAssertEqual(try GrammarResponseParser.parse("Result follows: \(object) End."), expected)
  }

  func testGrammarParserRejectsMissingCorrectedField() {
    XCTAssertThrowsError(try GrammarResponseParser.parse(#"{"explanation":"No correction"}"#)) {
      XCTAssertEqual($0 as? BexError, .invalidResponse)
    }
  }

  func testWordDiffPreservesEveryOriginalAndCorrectedCharacter() {
    let original = "Hello,\tworld!\nThis are  test."
    let corrected = "Hello,\tworld!\nThis is  a test."
    let segments = WordDiff.compute(original: original, corrected: corrected)

    let reconstructedOriginal =
      segments
      .filter { $0.kind != .inserted }
      .map(\.text)
      .joined()
    let reconstructedCorrected =
      segments
      .filter { $0.kind != .removed }
      .map(\.text)
      .joined()

    XCTAssertEqual(reconstructedOriginal, original)
    XCTAssertEqual(reconstructedCorrected, corrected)
    XCTAssertTrue(segments.contains { $0.kind == .removed && $0.text.contains("are") })
    XCTAssertTrue(segments.contains { $0.kind == .inserted && $0.text.contains("is") })
  }

  func testOpenAIClientBuildsExpectedRequestAndParsesResponse() async throws {
    let payload = Data(
      #"{"choices":[{"message":{"content":"{\"corrected\":\"This is a test.\",\"explanation\":\"Fixed agreement.\"}"}}]}"#
        .utf8)
    let transport = RecordingTransport(stubs: [.init(data: payload, status: 200)])
    let client = OpenAIClient(apiKey: "secret", transport: transport)

    let result = try await client.check(
      text: "This are a test.",
      model: "",
      systemPrompt: "system"
    )

    XCTAssertEqual(result.corrected, "This is a test.")
    let requests = await transport.recordedRequests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/json"
    )
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["model"] as? String, LLMProvider.openAI.defaultModel)
    XCTAssertEqual(object["temperature"] as? Double, 0.3)
    XCTAssertEqual(object["reasoning_effort"] as? String, "medium")
    XCTAssertEqual(
      (object["response_format"] as? [String: String])?["type"],
      "json_object"
    )
    let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
    XCTAssertEqual(
      messages,
      [
        ["role": "system", "content": "system"],
        ["role": "user", "content": "This are a test."],
      ]
    )
  }

  func testGrammarServiceUsesPersistedReasoningEffort() async throws {
    let payload = Data(
      #"{"choices":[{"message":{"content":"{\"corrected\":\"This is a test.\",\"explanation\":\"Fixed agreement.\"}"}}]}"#
        .utf8)
    let suite = "com.bex.tests.reasoning-effort-service.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)
    await preferences.setSelectedEffort(.high, for: .openAI)
    let keychain = KeychainStore(service: suite, inMemory: true)
    try await keychain.saveAPIKey("secret", for: .openAI)
    let transport = RecordingTransport(stubs: [.init(data: payload, status: 200)])
    let service = GrammarService(
      factory: ProviderClientFactory(
        preferences: preferences,
        keychain: keychain,
        transport: transport
      )
    )

    _ = try await service.check(
      text: "This are a test.",
      provider: .openAI,
      model: "",
      profilePrompt: nil
    )

    let requests = await transport.recordedRequests()
    let request = try XCTUnwrap(requests.first)
    let body = try XCTUnwrap(request.httpBody)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(object["reasoning_effort"] as? String, "high")
  }

  func testProviderStatusErrorsRemainActionable() throws {
    let unauthorized = HTTPURLResponse(
      url: URL(string: "https://example.invalid")!,
      statusCode: 401,
      httpVersion: nil,
      headerFields: nil
    )!
    XCTAssertThrowsError(
      try ProviderResponse.validateStatus(
        unauthorized,
        data: Data(),
        provider: .openAI
      )
    ) {
      XCTAssertEqual($0 as? BexError, .unauthorized(.openAI))
    }

    let missingModel = HTTPURLResponse(
      url: URL(string: "http://localhost:11434/api/chat")!,
      statusCode: 404,
      httpVersion: nil,
      headerFields: nil
    )!
    let missingOllamaModel = LLMProvider.ollama.defaultModel
    XCTAssertThrowsError(
      try ProviderResponse.validateStatus(
        missingModel,
        data: Data("model not found".utf8),
        provider: .ollama,
        model: missingOllamaModel,
        ollamaURL: "http://localhost:11434"
      )
    ) {
      XCTAssertEqual(
        $0 as? BexError,
        .modelMissing("Model '\(missingOllamaModel)' not found. Run: ollama pull \(missingOllamaModel)")
      )
    }
  }

  func testDataStoreRoundTripsProfileAndUpdatesHistoryInPlace() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexDataStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("data.json")
    let store = BexDataStore(fileURL: fileURL)

    let profile = Profile(id: UUID(), name: "Work", prompt: "Write clearly.")
    let historyID = UUID()
    let history = HistoryEntry(
      id: historyID,
      original: "This are a test.",
      corrected: "This is a test.",
      explanation: "Fixed agreement.",
      provider: .openAI,
      model: LLMProvider.openAI.defaultModel,
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      profileName: profile.name
    )

    try await store.saveProfile(profile)
    try await store.appendHistory(history)
    try await store.updateHistory(
      id: historyID,
      corrected: "This is a concise test.",
      explanation: "Rewrite applied: Shorter"
    )

    let reloaded = BexDataStore(fileURL: fileURL)
    let profiles = try await reloaded.loadProfiles()
    XCTAssertEqual(profiles, [profile])
    let entries = try await reloaded.loadHistory()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].id, historyID)
    XCTAssertEqual(entries[0].corrected, "This is a concise test.")
    XCTAssertEqual(entries[0].explanation, "Rewrite applied: Shorter")

    let encoded = try Data(contentsOf: fileURL)
    XCTAssertEqual(try JSONDecoder().decode(BexData.self, from: encoded).schemaVersion, 1)
  }

  func testDataStoreBacksUpCorruptDataBeforeStartingEmpty() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexCorruptStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("data.json")
    try Data("not-json".utf8).write(to: fileURL)
    let store = BexDataStore(fileURL: fileURL)

    do {
      _ = try await store.loadProfiles()
      XCTFail("Expected the first load to report corrupt local data")
    } catch let error as BexError {
      guard case .storageFailure(let message) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(message.contains("backup was saved"))
    }

    let recoveredProfiles = try await store.loadProfiles()
    XCTAssertEqual(recoveredProfiles, [])
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(files.contains { $0.hasPrefix("data.corrupt-") && $0.hasSuffix(".json") })
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }
}
