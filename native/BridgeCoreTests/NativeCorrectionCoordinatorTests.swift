import Foundation
import XCTest
@testable import NativeBridgeCore

@MainActor private final class ManualDeadlines: NativeDeadlineScheduler {
    @MainActor final class Entry: NativeDeadline {
        let nanoseconds: UInt64
        var action: (@MainActor () -> Void)?
        init(_ nanoseconds: UInt64, _ action: @escaping @MainActor () -> Void) {
            self.nanoseconds = nanoseconds; self.action = action
        }
        func cancel() { action = nil }
        func fire() { let callback = action; action = nil; callback?() }
    }
    var entries: [Entry] = []
    var liveCount: Int { entries.filter { $0.action != nil }.count }
    func schedule(nanoseconds: UInt64, action: @escaping @MainActor () -> Void) -> NativeDeadline {
        let entry = Entry(nanoseconds, action)
        entries.append(entry)
        return entry
    }
}

// Intentionally ignores cancellation: completion is controlled only by the test.
@MainActor private final class ControlledConsent: NativeCorrectionConsentService {
    var requests: [BridgeRequest] = []
    var providerNames: [String] = []
    var continuations: [CheckedContinuation<Bool, Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func requestConsent(for request: BridgeRequest, providerName: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(request); providerNames.append(providerName); continuations.append(continuation)
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
@MainActor private final class ControlledProvider: NativeCorrectionProviderService {
    var requests: [BridgeRequest] = []
    var continuations: [CheckedContinuation<String, Error>] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func correct(_ request: BridgeRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(request); continuations.append(continuation)
            let ready = waiters.filter { requests.count >= $0.0 }
            waiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
@MainActor private final class ExecutionHarness {
    let consent = ControlledConsent()
    let provider = ControlledProvider()
    let deadlines = ManualDeadlines()
    let session = UUID().uuidString
    var replies: [[String: Any]] = []
    var coordinator: NativeCorrectionCoordinator!
    init() throws {
        coordinator = try NativeCorrectionCoordinator(providerName: "Bound provider", consent: consent,
            provider: provider, consentTimeoutNanoseconds: 10, providerTimeoutNanoseconds: 20,
            scheduler: deadlines, emit: { [weak self] json in
                self?.replies.append(try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
            })
        _ = send("hello")
    }
    func send(_ kind: String, id: String = UUID().uuidString, session: String? = nil) -> String {
        var message: [String: Any] = ["bridgeVersion": 1, "sessionID": session ?? self.session,
                                      "requestID": id, "kind": kind]
        if kind == "correct" {
            message["request"] = ["protocolVersion": 1, "text": "I has API_v2.",
                "policy": ["vocabulary": "stretch", "maxNotes": 2, "alternatives": true, "focus": "verb-forms"],
                "source": ["title": "Reference", "section": "Section", "excerpt": "Exact API_v2 excerpt."]]
        }
        coordinator.receiveTrustedDocumentMessage(json(message))
        return id
    }
    func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    var result: String {
        json(["protocolVersion": 1, "original": "I has API_v2.", "corrected": "I have API_v2.",
              "notes": [], "provenance": "provider"])
    }
}

@MainActor private final class ImmediateConsent: NativeCorrectionConsentService {
    func requestConsent(for request: BridgeRequest, providerName: String) async throws -> Bool { true }
}
@MainActor private final class ImmediateProvider: NativeCorrectionProviderService {
    let result: String
    init(result: String) { self.result = result }
    func correct(_ request: BridgeRequest) async throws -> String { result }
}
@MainActor private final class CancellationAwareConsent: NativeCorrectionConsentService {
    private var started = false
    private var stopped = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var stopWaiter: CheckedContinuation<Void, Never>?
    func requestConsent(for request: BridgeRequest, providerName: String) async throws -> Bool {
        started = true; startWaiter?.resume(); startWaiter = nil
        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
        catch {
            stopped = true; stopWaiter?.resume(); stopWaiter = nil
            throw error
        }
        return false
    }
    func waitStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func waitStopped() async {
        if !stopped { await withCheckedContinuation { stopWaiter = $0 } }
    }
}

final class NativeCorrectionCoordinatorTests: XCTestCase {
    @MainActor func testFullRequestAndImmutableProviderPassThrough() async throws {
        let h = try ExecutionHarness()
        _ = h.send("correct")
        await h.consent.waitForCalls(1)
        XCTAssertEqual(h.provider.requests.count, 0)
        XCTAssertEqual(h.consent.providerNames, ["Bound provider"])
        XCTAssertEqual(h.deadlines.entries.map(\.nanoseconds), [10])
        h.consent.continuations[0].resume(returning: true)
        await h.provider.waitForCalls(1)
        XCTAssertEqual(h.provider.requests[0], h.consent.requests[0])
        XCTAssertEqual(h.provider.requests[0].source?.excerpt, "Exact API_v2 excerpt.")
        XCTAssertEqual(h.provider.requests[0].policy.focus, "verb-forms")
        XCTAssertEqual(h.deadlines.entries.map(\.nanoseconds), [10, 20])
        XCTAssertEqual(h.deadlines.liveCount, 1)
        // An old consent timer cannot expire the new provider stage.
        h.deadlines.entries[0].fire()
        h.provider.continuations[0].resume(returning: h.result)
        await h.coordinator.waitForCurrentOperations()
        XCTAssertEqual(h.replies.last?["kind"] as? String, "result")
        XCTAssertTrue(h.coordinator.isQuiescent)
        XCTAssertEqual(h.deadlines.liveCount, 0)
        h.coordinator.close()
    }

    @MainActor func testConsentDenialAndFailureNeverInvokeProvider() async throws {
        let h = try ExecutionHarness()
        _ = h.send("correct")
        await h.consent.waitForCalls(1)
        h.consent.continuations[0].resume(returning: false)
        await h.coordinator.waitForCurrentOperations()
        XCTAssertEqual(h.replies.last?["code"] as? String, "consent-denied")
        _ = h.send("correct")
        await h.consent.waitForCalls(2)
        h.consent.continuations[1].resume(throwing: BridgeValidation.invalid)
        await h.coordinator.waitForCurrentOperations()
        XCTAssertEqual(h.replies.last?["code"] as? String, "consent-denied")
        XCTAssertTrue(h.provider.requests.isEmpty)
        XCTAssertEqual(h.deadlines.liveCount, 0)
        h.coordinator.close()
    }

    @MainActor func testCancelBeforeTaskStartsDoesNotOpenConsent() async throws {
        let h = try ExecutionHarness()
        let id = h.send("correct")
        _ = h.send("cancel", id: id)
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 1)
        await h.coordinator.waitForCurrentOperations()
        XCTAssertTrue(h.consent.requests.isEmpty)
        XCTAssertTrue(h.provider.requests.isEmpty)
        XCTAssertTrue(h.coordinator.isQuiescent)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.deadlines.liveCount, 0)
        h.coordinator.close()
    }

    @MainActor func testNoncooperativeConsentCancellationRetainsFourSlots() async throws {
        let h = try ExecutionHarness()
        let ids = (0..<4).map { _ in h.send("correct") }
        await h.consent.waitForCalls(4)
        for id in ids { _ = h.send("cancel", id: id) }
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 4)
        XCTAssertEqual(h.deadlines.liveCount, 0)
        _ = h.send("correct")
        XCTAssertEqual(h.replies.last?["code"] as? String, "unavailable")
        for continuation in h.consent.continuations { continuation.resume(returning: true) }
        await h.coordinator.waitForCurrentOperations()
        XCTAssertTrue(h.provider.requests.isEmpty)
        XCTAssertTrue(h.coordinator.isQuiescent)
        _ = h.send("correct")
        await h.consent.waitForCalls(5)
        h.consent.continuations[4].resume(returning: false)
        await h.coordinator.waitForCurrentOperations()
        h.coordinator.close()
    }

    @MainActor func testConsentDeadlineIgnoresLateGrantWithoutRendererCancel() async throws {
        let h = try ExecutionHarness()
        _ = h.send("correct")
        await h.consent.waitForCalls(1)
        h.deadlines.entries[0].fire()
        XCTAssertEqual(h.replies.last?["code"] as? String, "unavailable")
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 1)
        h.consent.continuations[0].resume(returning: true)
        await h.coordinator.waitForCurrentOperations()
        XCTAssertTrue(h.provider.requests.isEmpty)
        XCTAssertEqual(h.replies.count, 2)
        XCTAssertTrue(h.coordinator.isQuiescent)
        h.coordinator.close()
    }

    @MainActor func testProviderDeadlineAndLateResultDoNotReleaseEarlyOrEmitTwice() async throws {
        let h = try ExecutionHarness()
        _ = h.send("correct")
        await h.consent.waitForCalls(1)
        h.consent.continuations[0].resume(returning: true)
        await h.provider.waitForCalls(1)
        h.deadlines.entries[1].fire()
        XCTAssertEqual(h.replies.last?["code"] as? String, "unavailable")
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 1)
        h.provider.continuations[0].resume(returning: h.result)
        await h.coordinator.waitForCurrentOperations()
        XCTAssertEqual(h.replies.count, 2)
        XCTAssertTrue(h.coordinator.isQuiescent)
        XCTAssertEqual(h.deadlines.liveCount, 0)
        h.coordinator.close()
    }

    @MainActor func testProviderErrorAndMalformedResultAreFixedFailures() async throws {
        let h = try ExecutionHarness()
        for index in 0..<2 {
            _ = h.send("correct")
            await h.consent.waitForCalls(index + 1)
            h.consent.continuations[index].resume(returning: true)
            await h.provider.waitForCalls(index + 1)
            if index == 0 { h.provider.continuations[index].resume(throwing: BridgeValidation.invalid) }
            else { h.provider.continuations[index].resume(returning: "not JSON") }
            await h.coordinator.waitForCurrentOperations()
            XCTAssertEqual(h.replies.last?["code"] as? String, "provider-failed")
        }
        XCTAssertEqual(h.deadlines.liveCount, 0)
        h.coordinator.close()
    }

    @MainActor func testCloseDuringConsentRevokesLateGrantAndNewAdmission() async throws {
        let h = try ExecutionHarness()
        _ = h.send("correct")
        await h.consent.waitForCalls(1)
        h.coordinator.close()
        _ = h.send("hello", session: UUID().uuidString)
        _ = h.send("correct")
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 1)
        h.consent.continuations[0].resume(returning: true)
        await h.coordinator.closeAndWait()
        XCTAssertTrue(h.coordinator.isQuiescent)
        XCTAssertTrue(h.provider.requests.isEmpty)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.deadlines.liveCount, 0)
    }

    @MainActor func testCloseDuringProviderDropsLateResultAndRejectsStaleSession() async throws {
        let h = try ExecutionHarness()
        _ = h.send("correct", session: UUID().uuidString)
        XCTAssertTrue(h.coordinator.isQuiescent)
        _ = h.send("correct")
        await h.consent.waitForCalls(1)
        h.consent.continuations[0].resume(returning: true)
        await h.provider.waitForCalls(1)
        h.coordinator.close()
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 1)
        h.provider.continuations[0].resume(returning: h.result)
        await h.coordinator.closeAndWait()
        XCTAssertTrue(h.coordinator.isQuiescent)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.deadlines.liveCount, 0)
    }

    @MainActor func testProviderCancellationRetainsCapacityUntilReturn() async throws {
        let h = try ExecutionHarness()
        let ids = (0..<4).map { _ in h.send("correct") }
        await h.consent.waitForCalls(4)
        for continuation in h.consent.continuations { continuation.resume(returning: true) }
        await h.provider.waitForCalls(4)
        for id in ids { _ = h.send("cancel", id: id) }
        _ = h.send("correct")
        XCTAssertEqual(h.replies.last?["code"] as? String, "unavailable")
        XCTAssertEqual(h.coordinator.outstandingOperationCount, 4)
        XCTAssertEqual(h.deadlines.liveCount, 0)
        // All ignored cancellation; only real returns free their slots.
        for continuation in h.provider.continuations { continuation.resume(returning: h.result) }
        await h.coordinator.waitForCurrentOperations()
        XCTAssertTrue(h.coordinator.isQuiescent)
        XCTAssertEqual(h.replies.count, 2)
        _ = h.send("correct")
        await h.consent.waitForCalls(5)
        h.consent.continuations[4].resume(returning: false)
        await h.coordinator.waitForCurrentOperations()
        h.coordinator.close()
    }

    @MainActor func testImmediateServicesCompleteWithoutRemovingNewPhase() async throws {
        let h = try ExecutionHarness()
        let clock = ManualDeadlines()
        var replies: [String] = []
        let coordinator = try NativeCorrectionCoordinator(providerName: "Bound provider",
            consent: ImmediateConsent(), provider: ImmediateProvider(result: h.result),
            consentTimeoutNanoseconds: 10, providerTimeoutNanoseconds: 20, scheduler: clock,
            emit: { replies.append($0) })
        // Reuse only the synthetic envelope generator, not its previous coordinator.
        h.coordinator.close()
        h.coordinator = coordinator
        _ = h.send("hello")
        _ = h.send("correct")
        await coordinator.waitForCurrentOperations() // consent snapshot
        await coordinator.waitForCurrentOperations() // provider, if not already finished
        XCTAssertTrue(coordinator.isQuiescent)
        XCTAssertEqual(replies.count, 2)
        XCTAssertTrue(replies.last?.contains("\"kind\":\"result\"") == true)
        XCTAssertEqual(clock.entries.map(\.nanoseconds), [10, 20])
        XCTAssertEqual(clock.liveCount, 0)
        coordinator.close()
    }

    @MainActor func testDroppingOwnerRequestsCancellationWithoutRetainCycle() async throws {
        let h = try ExecutionHarness()
        let consent = CancellationAwareConsent()
        h.coordinator.close()
        h.coordinator = try NativeCorrectionCoordinator(providerName: "Bound provider",
            consent: consent, provider: ImmediateProvider(result: h.result), emit: { _ in })
        _ = h.send("hello")
        _ = h.send("correct")
        await consent.waitStarted()
        weak var weakCoordinator = h.coordinator
        h.coordinator = nil
        XCTAssertNil(weakCoordinator)
        await consent.waitStopped()
    }

    @MainActor func testRejectDisabledOrUnboundedHostTimeouts() throws {
        for duration in [UInt64(0), UInt64.max] {
            XCTAssertThrowsError(try NativeCorrectionCoordinator(providerName: "Provider",
                consent: ControlledConsent(), provider: ControlledProvider(),
                consentTimeoutNanoseconds: duration, emit: { _ in }))
        }
    }
}
