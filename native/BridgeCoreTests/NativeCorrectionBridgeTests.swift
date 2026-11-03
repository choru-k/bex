import Foundation
import XCTest
@testable import NativeBridgeCore

@MainActor
private final class Harness {
    let session = UUID().uuidString
    var events: [NativeCorrectionBridge.Event] = []
    var replies: [[String: Any]] = []
    var core: NativeCorrectionBridge!
    init() throws {
        core = try NativeCorrectionBridge(providerName: "Test provider", emit: { [weak self] json in
            self?.replies.append(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        }, dispatch: { [weak self] in self?.events.append($0) })
    }
    func send(_ kind: String, id: String = UUID().uuidString, request: [String: Any]? = nil,
              session: String? = nil, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["bridgeVersion": 1, "sessionID": session ?? self.session, "requestID": id, "kind": kind]
        if let request { object["request"] = request }
        object.merge(extra) { _, new in new }
        core.receive(json(object))
        return id
    }
    func hello() { _ = send("hello") }
    func begin(_ text: String = "I has a book.") -> NativeCorrectionBridge.Job {
        _ = send("correct", request: request(text))
        guard case let .consentRequired(job, _, _) = events.last! else { fatalError("Expected consent") }
        return job
    }
    func json(_ object: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
    func request(_ text: String = "I has a book.") -> [String: Any] {
        ["protocolVersion": 1, "text": text, "policy": ["vocabulary": "familiar", "maxNotes": 1, "alternatives": true, "focus": "general"], "source": NSNull()]
    }
    func result(_ original: String = "I has a book.", corrected: String = "I have a book.") -> String {
        json(["protocolVersion": 1, "original": original, "corrected": corrected, "notes": [], "provenance": "provider"])
    }
}

final class NativeCorrectionBridgeTests: XCTestCase {
    @MainActor func testHandshakeAndNativeConsentGate() async throws {
        let h = try Harness()
        _ = h.send("correct", request: h.request())
        XCTAssertTrue(h.events.isEmpty)
        h.hello()
        XCTAssertEqual(h.replies.last?["kind"] as? String, "capabilities")
        let job = h.begin()
        h.core.complete(job, resultJSON: h.result()) // premature completion cannot bypass consent
        XCTAssertEqual(h.replies.count, 1)
        h.core.resolveConsent(job, granted: true)
        guard case .correctionAuthorized = h.events.last! else { return XCTFail("Provider was not authorized") }
        h.core.resolveConsent(job, granted: true)
        XCTAssertEqual(h.events.count, 2)
        h.core.complete(job, resultJSON: h.result())
        XCTAssertEqual(h.replies.last?["kind"] as? String, "result")
        h.core.complete(job, resultJSON: h.result())
        XCTAssertEqual(h.replies.count, 2)
    }

    @MainActor func testDenialReplayAndSessionIsolation() async throws {
        let h = try Harness(); h.hello()
        let job = h.begin()
        h.core.resolveConsent(job, granted: false)
        XCTAssertEqual(h.replies.last?["code"] as? String, "consent-denied")
        _ = h.send("correct", id: job.requestID, request: h.request())
        _ = h.send("correct", request: h.request(), session: UUID().uuidString)
        _ = h.send("hello", session: UUID().uuidString)
        h.core.resolveConsent(job, granted: true)
        XCTAssertEqual(h.events.count, 1)
        XCTAssertEqual(h.replies.count, 2)
    }

    @MainActor func testStrictInputAndBounds() async throws {
        let h = try Harness(); h.hello()
        var cases = [[String: Any]]()
        var r = h.request(); r["endpoint"] = "https://example.invalid"; cases.append(r)
        r = h.request(); r["source"] = nil; cases.append(r)
        r = h.request(); r["protocolVersion"] = true; cases.append(r)
        r = h.request(); r["policy"] = ["vocabulary": "familiar", "maxNotes": true, "alternatives": true, "focus": "general"]; cases.append(r)
        r = h.request(); r["source"] = ["title": "Book", "section": "", "excerpt": " "]; cases.append(r)
        r = h.request(); r["source"] = ["title": String(repeating: "😀", count: 81), "section": "", "excerpt": "Excerpt"]; cases.append(r)
        cases.append(h.request(String(repeating: "😀", count: 6_001)))
        cases.append(h.request("\u{FEFF}"))
        for invalid in cases { _ = h.send("correct", request: invalid) }
        _ = h.send("correct", request: h.request(), extra: ["consent": true])
        _ = h.send("correct", id: "not-a-uuid", request: h.request())
        h.core.receive(String(repeating: "x", count: 128_001))
        XCTAssertTrue(h.events.isEmpty)
        _ = h.begin(String(repeating: "😀", count: 6_000))
        XCTAssertEqual(h.events.count, 1)
    }

    @MainActor func testCancellationDuringConsentRetainsCapacity() async throws {
        let h = try Harness(); h.hello()
        let jobs = (0..<4).map { _ in h.begin() }
        for job in jobs { _ = h.send("cancel", id: job.requestID) }
        XCTAssertEqual(h.events.count, 8)
        for job in jobs { h.core.resolveConsent(job, granted: true) }
        let overloadedID = h.send("correct", request: h.request())
        XCTAssertEqual(h.replies.last?["code"] as? String, "unavailable")
        XCTAssertEqual(h.events.count, 8)
        h.core.acknowledgeCancellation(jobs[0])
        _ = h.send("correct", id: overloadedID, request: h.request())
        XCTAssertEqual(h.events.count, 8)
        _ = h.begin()
        XCTAssertEqual(h.events.count, 9)
        // Replayed cancelled ID cannot take a newly freed slot.
        _ = h.send("correct", id: jobs[0].requestID, request: h.request())
        XCTAssertEqual(h.events.count, 9)
    }

    @MainActor func testProviderCancelExpirationAndCloseSuppressStaleResults() async throws {
        let h = try Harness(); h.hello()
        let cancelled = h.begin()
        h.core.resolveConsent(cancelled, granted: true)
        _ = h.send("cancel", id: cancelled.requestID)
        h.core.complete(cancelled, resultJSON: h.result())
        XCTAssertEqual(h.replies.count, 1)
        let expired = h.begin()
        h.core.expire(expired)
        XCTAssertEqual(h.replies.last?["code"] as? String, "unavailable")
        h.core.resolveConsent(expired, granted: true)
        h.core.acknowledgeCancellation(expired)
        let closed = h.begin()
        h.core.resolveConsent(closed, granted: true)
        h.core.close(); h.core.close()
        h.core.complete(closed, resultJSON: h.result())
        h.hello()
        XCTAssertEqual(h.replies.count, 2)
    }

    @MainActor func testResultsRejectCanonicalEquivalenceAndFixtureProvenance() async throws {
        let h = try Harness(); h.hello()
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let job = h.begin(composed)
        h.core.resolveConsent(job, granted: true)
        h.core.complete(job, resultJSON: h.result(decomposed, corrected: composed))
        XCTAssertEqual(h.replies.last?["code"] as? String, "provider-failed")
        let fixture = h.begin()
        h.core.resolveConsent(fixture, granted: true)
        h.core.complete(fixture, resultJSON: h.result().replacingOccurrences(of: "provider", with: "fixture"))
        XCTAssertEqual(h.replies.last?["code"] as? String, "provider-failed")
        let forgedNote = h.begin(composed)
        h.core.resolveConsent(forgedNote, granted: true)
        h.core.complete(forgedNote, resultJSON: h.json(["protocolVersion": 1, "original": composed, "corrected": "coffee", "provenance": "provider", "notes": [["kind": "correction", "category": "expression", "before": decomposed, "after": "coffee", "reason": "Test"]]]))
        XCTAssertEqual(h.replies.last?["code"] as? String, "provider-failed")
    }

    @MainActor func testRedactedFailure() async throws {
        let h = try Harness(); h.hello()
        let job = h.begin()
        h.core.resolveConsent(job, granted: true)
        h.core.complete(job, resultJSON: "secret arbitrary provider error")
        XCTAssertEqual(Set(h.replies.last!.keys), ["bridgeVersion", "sessionID", "requestID", "kind", "code"])
        XCTAssertEqual(h.replies.last?["code"] as? String, "provider-failed")
        XCTAssertFalse(h.json(h.replies.last!).contains("secret"))
    }

    @MainActor func testSynchronousReentrancy() async throws {
        var core: NativeCorrectionBridge!
        var responseKinds = [String]()
        let helper = try Harness()
        core = try NativeCorrectionBridge(providerName: "Test", emit: { json in
            let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            responseKinds.append(object["kind"] as! String)
        }, dispatch: { event in
            switch event {
            case let .consentRequired(job, _, _): core.resolveConsent(job, granted: true)
            case let .correctionAuthorized(job, _): core.complete(job, resultJSON: helper.result())
            case let .cancellationRequested(job): core.acknowledgeCancellation(job)
            }
        })
        let session = UUID().uuidString
        core.receive(helper.json(["bridgeVersion": 1, "sessionID": session, "requestID": UUID().uuidString, "kind": "hello"]))
        core.receive(helper.json(["bridgeVersion": 1, "sessionID": session, "requestID": UUID().uuidString, "kind": "correct", "request": helper.request()]))
        XCTAssertEqual(responseKinds, ["capabilities", "result"])
    }

    @MainActor func testReplayStorageIsBoundedAndClosesFailSafe() async throws {
        let h = try Harness(); h.hello()
        for _ in 1..<NativeCorrectionBridge.maximumRequestsPerSession {
            let job = h.begin(); h.core.resolveConsent(job, granted: false)
        }
        let count = h.events.count
        _ = h.send("correct", request: h.request())
        _ = h.send("correct", request: h.request())
        XCTAssertEqual(h.events.count, count)
    }
    @MainActor func testSharedRendererWireVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/native-bridge-v1.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let h = try Harness(); h.hello()
            _ = h.send("correct", request: item["request"] as! [String: Any])
            guard case let .consentRequired(job, _, _) = h.events.last! else { return XCTFail("Missing consent") }
            h.core.resolveConsent(job, granted: true)
            h.core.complete(job, resultJSON: h.json(item["result"] as! [String: Any]))
            XCTAssertEqual(h.replies.last?["kind"] as? String,
                           item["acceptResult"] as! Bool ? "result" : "error", item["name"] as! String)
        }
    }

    @MainActor func testCloseInsideConsentCallbackCannotAuthorizeWork() async throws {
        var core: NativeCorrectionBridge!
        var authorized = false
        var cancelled = false
        let h = try Harness()
        core = try NativeCorrectionBridge(providerName: "Test", emit: { _ in }, dispatch: { event in
            switch event {
            case let .consentRequired(job, _, _):
                core.close()
                core.resolveConsent(job, granted: true)
            case .correctionAuthorized: authorized = true
            case let .cancellationRequested(job):
                cancelled = true
                core.acknowledgeCancellation(job)
            }
        })
        core.receive(h.json(["bridgeVersion": 1, "sessionID": h.session, "requestID": UUID().uuidString, "kind": "hello"]))
        core.receive(h.json(["bridgeVersion": 1, "sessionID": h.session, "requestID": UUID().uuidString, "kind": "correct", "request": h.request()]))
        XCTAssertTrue(cancelled)
        XCTAssertFalse(authorized)
    }

    @MainActor func testOutboundEscapingCannotExceedByteBudget() async throws {
        let h = try Harness(); h.hello()
        let original = String(repeating: "/", count: 1_000)
        let job = h.begin(original)
        h.core.resolveConsent(job, granted: true)
        let note: [String: Any] = ["kind": "correction", "category": "expression",
            "before": original, "after": String(repeating: "/", count: 999) + "!",
            "reason": String(repeating: "/", count: 2_000)]
        let object: [String: Any] = ["protocolVersion": 1, "original": original,
            "corrected": original + "!", "provenance": "provider",
            "notes": Array(repeating: note, count: 20)]
        let raw = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        XCTAssertLessThan(raw.count, NativeCorrectionBridge.maximumBytes)
        h.core.complete(job, resultJSON: String(data: raw, encoding: .utf8)!)
        XCTAssertEqual(h.replies.last?["code"] as? String, "provider-failed")
        XCTAssertLessThan(h.json(h.replies.last!).utf8.count, NativeCorrectionBridge.maximumBytes)
    }

}
