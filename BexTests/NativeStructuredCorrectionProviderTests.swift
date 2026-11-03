import XCTest
import NativeBridgeCore
@testable import Bex

private func wireJSON(_ object: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

private func request(_ text: String = "I is ready.", maxNotes: Int = 1,
                     alternatives: Bool = true, source: [String: String]? = nil) throws -> BridgeRequest {
  let data = try JSONSerialization.data(withJSONObject: [
    "protocolVersion": 1, "text": text,
    "policy": ["vocabulary": "stretch", "maxNotes": maxNotes,
               "alternatives": alternatives, "focus": "verb-forms"] as [String: Any],
    "source": source.map { $0 as Any } ?? NSNull(),
  ])
  return try JSONDecoder().decode(BridgeRequest.self, from: data)
}

private func payload(_ text: String) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func goodResponse(_ text: String, notes: [[String: String]] = []) throws -> String {
  let input = try XCTUnwrap(payload(text)["userText"] as? String)
  return try wireJSON(["corrected": input.replacingOccurrences(of: "I is", with: "I am"), "notes": notes])
}

private let validNote = ["kind": "correction", "category": "verb-forms",
  "before": "I is", "after": "I am", "reason": "Use am with I."]

private actor StructuredFakeClient: LLMProviderClient {
  private let response: @Sendable (String) throws -> String
  private(set) var messages: [String] = []
  init(response: @escaping @Sendable (String) throws -> String = { try goodResponse($0) }) {
    self.response = response
  }
  func generate(text: String, model: String, systemPrompt: String,
                effort: ReasoningEffort) async throws -> String {
    messages.append(text)
    return try response(text)
  }
  func check(text: String, model: String, systemPrompt: String,
             effort: ReasoningEffort) async throws -> GrammarResult {
    XCTFail("Structured adapter must use generate, never check")
    throw BexError.invalidResponse
  }
  func fetchModels() async throws -> [ModelOption] {
    XCTFail("Adapter must not fetch models")
    throw BexError.invalidResponse
  }
}

@MainActor
final class NativeStructuredCorrectionProviderTests: XCTestCase {
  private func adapter(_ client: StructuredFakeClient,
                       provider: LLMProvider = .openAI) throws -> NativeStructuredCorrectionProvider {
    NativeStructuredCorrectionProvider(
      destination: try OutboundDestination(provider: provider, model: "fixture-model"),
      effort: .low, makeClient: { client })
  }

  private func rejected(_ client: StructuredFakeClient, _ input: BridgeRequest) async throws {
    let service = try adapter(client)
    do { _ = try await service.correct(input); XCTFail("Expected rejection") }
    catch { /* Entire response rejected; no partial/fabricated feedback. */ }
  }

  func testInitializationIsInertAndCodexFailsBeforeFactory() async throws {
    var factories = 0
    let client = StructuredFakeClient()
    let service = NativeStructuredCorrectionProvider(
      destination: try OutboundDestination(provider: .openAICodex, model: "fixture"),
      effort: .low, makeClient: { factories += 1; return client })
    XCTAssertEqual(factories, 0)
    do { _ = try await service.correct(request()); XCTFail("Codex must fail closed") }
    catch { }
    XCTAssertEqual(factories, 0)
    let messages = await client.messages
    XCTAssertTrue(messages.isEmpty)
  }

  func testMasksOriginalAndAllSourceFieldsPreservesPolicyAndRestoresExactly() async throws {
    let client = StructuredFakeClient(response: { try goodResponse($0, notes: [validNote]) })
    let service = try adapter(client)
    let original = "I is ready. `秘密 e\u{301} 👩🏽‍💻` /private/path --secret=x"
    let result = try payload(await service.correct(request(original, source: [
      "title": "Read `private-title`", "section": "See /private/section",
      "excerpt": "Use `private-excerpt` as a placeholder.",
    ])))
    XCTAssertEqual(Array(try XCTUnwrap(result["original"] as? String).utf16), Array(original.utf16))
    XCTAssertEqual(Array(try XCTUnwrap(result["corrected"] as? String).utf16),
      Array(original.replacingOccurrences(of: "I is", with: "I am").utf16))
    XCTAssertEqual(result["provenance"] as? String, "provider")
    let messages = await client.messages
    let sent = try XCTUnwrap(messages.first)
    for heldBack in ["秘密", "/private/path", "--secret=x", "private-title", "/private/section", "private-excerpt"] {
      XCTAssertFalse(sent.contains(heldBack))
    }
    let object = try payload(sent)
    let policy = try XCTUnwrap(object["policy"] as? [String: Any])
    XCTAssertEqual(policy["vocabulary"] as? String, "stretch")
    XCTAssertEqual(policy["focus"] as? String, "verb-forms")
    XCTAssertEqual(policy["maxNotes"] as? Int, 1)
    XCTAssertEqual(policy["alternatives"] as? Bool, true)
    XCTAssertNotNil(object["source"] as? [String: String])
  }

  func testZeroNotesStillReturnsCompleteCorrection() async throws {
    let service = try adapter(StructuredFakeClient())
    let result = try payload(await service.correct(request(maxNotes: 0)))
    XCTAssertEqual(result["corrected"] as? String, "I am ready.")
    XCTAssertEqual((result["notes"] as? [Any])?.count, 0)
  }

  func testRejectsMissingDuplicateReorderedAndSourceSentinels() async throws {
    let input = try request("I is `alpha` and `beta`.", source: [
      "title": "Reference", "section": "", "excerpt": "Use `gamma`.",
    ])
    for operation in 0..<4 {
      let client = StructuredFakeClient { text in
        let object = try payload(text)
        let masked = try XCTUnwrap(object["userText"] as? String)
        let regex = try NSRegularExpression(pattern: #"\[\[\[BEX_PROTECTED_[^\]]+\]\]\]"#)
        let spans = regex.matches(in: masked, range: NSRange(location: 0, length: (masked as NSString).length))
          .map { (masked as NSString).substring(with: $0.range) }
        let first = try XCTUnwrap(spans.first)
        var changed = masked
        switch operation {
        case 0: changed = masked.replacingOccurrences(of: first, with: "")
        case 1: changed += first
        case 2: changed = masked.replacingOccurrences(of: first, with: "TEMP")
          .replacingOccurrences(of: spans[1], with: first).replacingOccurrences(of: "TEMP", with: spans[1])
        default:
          changed += try XCTUnwrap((object["source"] as? [String: String])?["excerpt"])
        }
        return try wireJSON(["corrected": changed, "notes": []])
      }
      try await rejected(client, input)
    }
  }

  func testRejectsSentinelAndAmbiguousNoteSpans() async throws {
    let sentinelNote = StructuredFakeClient { text in
      let masked = try XCTUnwrap(payload(text)["userText"] as? String)
      var note = validNote
      note["before"] = masked
      return try goodResponse(text, notes: [note])
    }
    try await rejected(sentinelNote, request("I is `secret`."))
    let ambiguous = StructuredFakeClient { try goodResponse($0, notes: [validNote]) }
    try await rejected(ambiguous, request("I is ready. I is here."))
    let markerReason = StructuredFakeClient { text in
      var note = validNote; note["reason"] = "BEX_PROTECTED_fake"
      return try goodResponse(text, notes: [note])
    }
    try await rejected(markerReason, request())
  }

  func testRejectsPolicyViolationsMalformedAndExtraFields() async throws {
    try await rejected(StructuredFakeClient { try goodResponse($0, notes: [validNote]) }, request(maxNotes: 0))
    try await rejected(StructuredFakeClient { text in
      var note = validNote; note["kind"] = "alternative"
      return try goodResponse(text, notes: [note])
    }, request(alternatives: false))
    try await rejected(StructuredFakeClient { _ in "not json" }, request())
    try await rejected(StructuredFakeClient { _ in
      try wireJSON(["corrected": "I am ready.", "notes": [], "original": "forged"])
    }, request())
    try await rejected(StructuredFakeClient { text in
      var note = validNote; note["extra"] = "unexpected"
      return try goodResponse(text, notes: [note])
    }, request())
  }

  func testReservedInputFailsBeforeFactory() async throws {
    var factories = 0
    let client = StructuredFakeClient()
    let service = NativeStructuredCorrectionProvider(
      destination: try OutboundDestination(provider: .openAI, model: "fixture"),
      effort: .low, makeClient: { factories += 1; return client })
    do { _ = try await service.correct(request("BEX_PROTECTED_fake")); XCTFail("Expected rejection") }
    catch { }
    XCTAssertEqual(factories, 0)
  }

  func testCancellationBeforeAndAfterFactoryNeverGenerates() async throws {
    var factories = 0
    let client = StructuredFakeClient()
    let input = try request()
    let service = NativeStructuredCorrectionProvider(
      destination: try OutboundDestination(provider: .openAI, model: "fixture"),
      effort: .low, makeClient: { factories += 1; return client })
    let task = Task { @MainActor in try await service.correct(input) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(factories, 0)

    let cancelInFactory = NativeStructuredCorrectionProvider(
      destination: try OutboundDestination(provider: .openAI, model: "fixture"),
      effort: .low, makeClient: {
        factories += 1
        withUnsafeCurrentTask { $0?.cancel() }
        return client
      })
    let second = Task { @MainActor in try await cancelInFactory.correct(input) }
    do { _ = try await second.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(factories, 1)
    let messages = await client.messages
    XCTAssertTrue(messages.isEmpty)
  }

  func testProviderErrorsAreRedactedAndCancellationPreserved() async throws {
    let service = try adapter(StructuredFakeClient { _ in
      throw NSError(domain: "private-provider-body", code: 99,
                    userInfo: [NSLocalizedDescriptionKey: "synthetic secret"])
    })
    do { _ = try await service.correct(request()); XCTFail("Expected failure") }
    catch {
      guard case BexError.invalidResponse = error else { return XCTFail("Unredacted error") }
    }
    let cancelled = try adapter(StructuredFakeClient { _ in throw CancellationError() })
    do { _ = try await cancelled.correct(request()); XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testCancellationAfterGenerateDiscardsOtherwiseValidResult() async throws {
    let service = try adapter(StructuredFakeClient { text in
      withUnsafeCurrentTask { $0?.cancel() }
      return try goodResponse(text)
    })
    let input = try request()
    let task = Task { @MainActor in try await service.correct(input) }
    do { _ = try await task.value; XCTFail("Cancelled result must not escape") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testRejectsOversizedResultAndCanonicalEquivalentNote() async throws {
    try await rejected(StructuredFakeClient { _ in String(repeating: "x", count: 128_001) }, request())
    let client = StructuredFakeClient { text in
      try goodResponse(text, notes: [["kind": "alternative", "category": "expression",
        "before": "caf\u{00E9}", "after": "coffee shop", "reason": "Optional wording."]])
    }
    try await rejected(client, request("Visit the cafe\u{301}."))
  }
}
