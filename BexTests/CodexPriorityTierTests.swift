import Foundation
import XCTest

@testable import Bex

/// The priority ("Fast") service tier is billed as increased usage against the owner's
/// ChatGPT account. It defaults to ON — the owner's call, made after seeing the ~1.6s
/// median saving — so the load-bearing test is that turning it OFF really does drop the
/// field, rather than sending some "standard" value that would override whatever tier the
/// account already has.
final class CodexPriorityTierTests: XCTestCase {
  private func makeKeychain() async throws -> KeychainStore {
    let keychain = KeychainStore(service: "com.bex.tests.tier.\(UUID())", inMemory: true)
    try await keychain.saveCodexSession(
      CodexSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        expiresAt: Date().addingTimeInterval(3_600),
        accountID: "account-123"
      )
    )
    return keychain
  }

  private func sentBody(usesPriorityTier: Bool) async throws -> [String: Any] {
    let keychain = try await makeKeychain()
    let payload = try JSONSerialization.data(
      withJSONObject: [
        "output_text": #"{"corrected":"This is a test.","explanation":"No changes needed."}"#
      ])
    let transport = ScriptedHTTPTransport([.response(payload, 200)])
    let client = OpenAICodexClient(
      keychain: keychain, transport: transport, usesPriorityTier: usesPriorityTier)

    _ = try await client.check(text: "This are a test.", model: "", systemPrompt: "system prompt")

    let recorded = await transport.recordedRequests()
    let request = try XCTUnwrap(recorded.first)
    let body = try XCTUnwrap(request.httpBody)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
  }

  /// Off must mean the key is not sent at all rather than sent with some "standard" value —
  /// omitting it leaves the account on whatever tier it already has.
  func testTierIsAbsentWhenDisabled() async throws {
    let body = try await sentBody(usesPriorityTier: false)
    XCTAssertNil(body["service_tier"])
  }

  func testTierIsSentWhenEnabled() async throws {
    let body = try await sentBody(usesPriorityTier: true)
    XCTAssertEqual(body["service_tier"] as? String, "priority")
  }

  /// The tier must ride alongside the existing request shape, not replace part of it. This
  /// caught the refactor from an inline body literal to a mutable dictionary.
  func testEnablingTheTierLeavesEveryOtherFieldIntact() async throws {
    let off = try await sentBody(usesPriorityTier: false)
    let on = try await sentBody(usesPriorityTier: true)

    XCTAssertEqual(Set(on.keys).subtracting(off.keys), ["service_tier"])
    XCTAssertEqual(Set(off.keys).subtracting(on.keys), [])
    // Re-serialize with sorted keys rather than comparing `String(describing:)`: dictionary
    // descriptions have no stable ordering, so nested values like `input` compare unequal
    // at random.
    func canonical(_ value: Any?) throws -> String {
      let data = try JSONSerialization.data(
        withJSONObject: ["v": value ?? NSNull()], options: [.sortedKeys])
      return String(decoding: data, as: UTF8.self)
    }
    for key in ["model", "store", "stream", "instructions", "input", "reasoning", "text"] {
      XCTAssertEqual(
        try canonical(off[key]), try canonical(on[key]),
        "\(key) changed when the tier was enabled")
    }
    XCTAssertEqual((on["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
  }

  // MARK: - Preference

  /// An unset key must read as ON. A bare `defaults.bool(forKey:)` returns false for a
  /// missing key, which would have made the shipped default the opposite of the intent.
  func testPreferenceDefaultsToOnAndRoundTrips() async {
    let suite = "com.bex.tests.tier.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)

    let initial = await preferences.codexPriorityTier()
    XCTAssertTrue(initial, "an unset key must read as ON, not as bool(forKey:)'s false")

    await preferences.setCodexPriorityTier(false)
    let disabled = await preferences.codexPriorityTier()
    XCTAssertFalse(disabled, "turning it off must stick, not fall back to the default")

    await preferences.setCodexPriorityTier(true)
    let enabled = await preferences.codexPriorityTier()
    XCTAssertTrue(enabled)
  }
}
