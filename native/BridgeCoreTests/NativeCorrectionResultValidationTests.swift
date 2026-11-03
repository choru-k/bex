import Foundation
import XCTest
@testable import NativeBridgeCore

final class NativeCorrectionResultValidationTests: XCTestCase {
    private func result(original: String = "I is ready.", corrected: String = "I am ready.",
                        notes: [[String: Any]] = []) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "protocolVersion": 1, "original": original, "corrected": corrected,
            "notes": notes, "provenance": "provider",
        ], options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor func testValidCanonicalRoundTripAndExactOriginal() async throws {
        let raw = try result()
        let canonical = try NativeCorrectionBridge.validateResultJSON(raw, original: "I is ready.")
        XCTAssertNoThrow(try NativeCorrectionBridge.validateResultJSON(canonical, original: "I is ready."))
        let object = try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any]
        XCTAssertEqual(object?["original"] as? String, "I is ready.")
        XCTAssertEqual(object?["corrected"] as? String, "I am ready.")
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON(raw, original: "other"))
        let decomposed = "cafe\u{301}"
        let unicode = try result(original: decomposed, corrected: decomposed)
        XCTAssertNoThrow(try NativeCorrectionBridge.validateResultJSON(unicode, original: decomposed))
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON(unicode, original: "caf\u{00E9}"))
    }

    @MainActor func testRejectsMalformedSchemaAndInputByteLimit() async throws {
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON("not JSON", original: "text"))
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON("{}", original: "text"))
        let raw = try result()
        let padded = String(repeating: " ", count: NativeCorrectionBridge.maximumBytes) + raw
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON(padded, original: "I is ready."))
        let extra = String(raw.dropLast()) + ",\"unexpected\":true}"
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON(String(extra), original: "I is ready."))
    }

    @MainActor func testCanonicalEncodingCannotExceedOutputByteLimit() async throws {
        let original = String(repeating: "/", count: 1_000)
        let note: [String: Any] = ["kind": "correction", "category": "expression",
            "before": original, "after": String(repeating: "/", count: 999) + "!",
            "reason": String(repeating: "/", count: 2_000)]
        let raw = try result(original: original, corrected: original + "!",
                             notes: Array(repeating: note, count: 20))
        XCTAssertLessThan(raw.utf8.count, NativeCorrectionBridge.maximumBytes)
        XCTAssertThrowsError(try NativeCorrectionBridge.validateResultJSON(raw, original: original))
    }
}
