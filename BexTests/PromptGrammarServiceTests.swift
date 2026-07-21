import Foundation
import XCTest

@testable import Bex

final class PromptGrammarServiceTests: XCTestCase {
  func testProtectorRoundTripsSupportedTechnicalSpansAndLineEndings() throws {
    let text = """
      please run `swift test` with --filter=Fast at /tmp/a.swift and https://example.com/a?q=1.
      keep ${HOME}, {{value}}, <tag>, $TOKEN, and @reviewer unchanged.
      ```swift\r
      let value = foo(bar: 1)\r
      ```
      """
    let protected = PromptTechnicalSpanProtector(identifier: "TEST").protect(text)

    XCTAssertFalse(protected.masked.contains("swift test"))
    XCTAssertFalse(protected.masked.contains("https://example.com"))
    XCTAssertEqual(try protected.restore(protected.masked), text)
  }

  func testProtectorHandlesAdjacentSpansAndRejectsDuplicateMissingReorderedOrInjectedSentinels() throws {
    let protected = PromptTechnicalSpanProtector(identifier: "TEST").protect(
      "Use `/tmp/a`{{value}} and --force."
    )
    XCTAssertGreaterThanOrEqual(protected.sentinels.count, 3)

    let first = try XCTUnwrap(protected.sentinels.first)
    XCTAssertThrowsError(try protected.restore(protected.masked + first))
    XCTAssertThrowsError(
      try protected.restore(protected.masked.replacingOccurrences(of: first, with: ""))
    )

    if protected.sentinels.count >= 2 {
      let second = protected.sentinels[1]
      let reordered = protected.masked
        .replacingOccurrences(of: first, with: "__FIRST__")
        .replacingOccurrences(of: second, with: first)
        .replacingOccurrences(of: "__FIRST__", with: second)
      XCTAssertThrowsError(try protected.restore(reordered))
    }

    XCTAssertThrowsError(
      try protected.restore(protected.masked + " [[[BEX_PROTECTED_ATTACK_0]]]")
    )
  }

  func testProtectorTreatsUnclosedFenceAsTechnicalThroughEndOfInput() throws {
    let text = "Before\n```sh\necho $TOKEN\n--force"
    let protected = PromptTechnicalSpanProtector(identifier: "TEST").protect(text)
    XCTAssertEqual(protected.sentinels.count, 1)
    XCTAssertEqual(try protected.restore(protected.masked), text)
  }

  func testPromptGrammarServiceReturnsNoOpAndEditedResults() async throws {
    let unchangedService = try await makeService(corrected: "This is fine.")
    let unchanged = try await unchangedService.checkPrompt(
      text: "This is fine.",
      provider: .openAI,
      model: ""
    )
    XCTAssertEqual(unchanged.corrected, "This is fine.")

    let editedService = try await makeService(corrected: "This is better.")
    let edited = try await editedService.checkPrompt(
      text: "This are better.",
      provider: .openAI,
      model: ""
    )
    XCTAssertEqual(edited.corrected, "This is better.")
  }

  func testPromptGrammarServiceFailsClosedWhenTechnicalSentinelIsMissingOrInjected() async throws {
    let missing = try await makeService(corrected: "Please inspect the file.")
    await XCTAssertThrowsErrorAsync(
      try await missing.checkPrompt(
        text: "Please inspect /tmp/a.swift.",
        provider: .openAI,
        model: ""
      )
    )

    let injected = try await makeService(corrected: "Text [[[BEX_PROTECTED_ATTACK_0]]]")
    await XCTAssertThrowsErrorAsync(
      try await injected.checkPrompt(
        text: "Text",
        provider: .openAI,
        model: ""
      )
    )
  }

  private func makeService(corrected: String) async throws -> GrammarService {
    let contentData = try JSONSerialization.data(
      withJSONObject: ["corrected": corrected, "explanation": "Checked"]
    )
    let content = try XCTUnwrap(String(data: contentData, encoding: .utf8))
    let payload = try JSONSerialization.data(
      withJSONObject: ["choices": [["message": ["content": content]]]]
    )
    let suite = "com.bex.tests.prompt-grammar.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let preferences = PreferencesStore(defaults: defaults)
    let keychain = KeychainStore(service: suite, inMemory: true)
    let transport = RecordingTransport(stubs: [.init(data: payload, status: 200)])
    try await keychain.saveAPIKey("secret", for: .openAI)
    return GrammarService(
      factory: ProviderClientFactory(
        preferences: preferences,
        keychain: keychain,
        transport: transport
      )
    )
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw", file: file, line: line)
  } catch {
    XCTAssertEqual(error as? BexError, .unsafePromptCorrection, file: file, line: line)
  }
}
