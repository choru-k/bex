import Foundation
import XCTest
@testable import Bex

@MainActor
final class IndependentAccessibilityTargetServiceTests: XCTestCase {
  func testCaptureCopiesOnceAndNeverUsesAReplacementOrSubmitOperation() async throws {
    let fixture = IndependentAXFixture()
    let capture = try await fixture.service.captureFrontmostTarget()
    XCTAssertEqual(capture.target.availableDeliveryActions, [.copyCorrection])
    XCTAssertEqual(capture.draft, "Original draft")
    let result = try await fixture.service.deliver("Corrected draft", to: capture.target, action: .copyCorrection)
    XCTAssertEqual(result, .copied)
    XCTAssertEqual(fixture.writer.values, ["Corrected draft"])
    XCTAssertEqual(fixture.client.consumptions.count, 1)
    await assertFails { _ = try await fixture.service.deliver("Again", to: capture.target, action: .copyCorrection) }
    XCTAssertEqual(fixture.writer.values.count, 1)
  }

  func testExplicitManualCopyStillWorksWithoutAnyAgentConnection() async throws {
    let fixture = IndependentAXFixture()
    fixture.client.failure = .unavailable
    let target = try fixture.service.makeStandaloneTarget()
    let result = try await fixture.service.deliver("Manual", to: target, action: .copyCorrection)
    XCTAssertEqual(result, .copied)
    XCTAssertEqual(fixture.client.captureCount, 0)
    XCTAssertEqual(fixture.writer.values, ["Manual"])
    await assertFails { _ = try await fixture.service.captureFrontmostTarget() }
    XCTAssertEqual(fixture.writer.values, ["Manual"], "Failed capture must not silently copy or fall back")
  }

  func testUnissuedMutatedAndDowngradedRemoteTargetsCannotCopy() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    for kind in [PromptTargetKind.capturedField, .copyOnly, .managedDraft] {
      let changed = PromptTarget(id: target.id, kind: kind, processID: target.processID,
        bundleID: target.bundleID, applicationName: target.applicationName, guidance: "Changed")
      await assertFails { _ = try await fixture.service.deliver("Correction", to: changed, action: .copyCorrection) }
    }
    XCTAssertTrue(fixture.writer.values.isEmpty)
    XCTAssertTrue(fixture.client.consumptions.isEmpty)
  }

  func testPasteAndSubmitAreRejectedBeforeRemoteValidation() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    for action in [PromptDeliveryAction.pasteInDestination, .pasteAndSubmit] {
      await assertFails { _ = try await fixture.service.deliver("Correction", to: target, action: action) }
    }
    XCTAssertEqual(fixture.client.validationCount, 0)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testDiscardDuringAwaitedValidationCannotCopy() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    fixture.client.onValidate = { fixture.service.discard(target) }
    await assertFails { _ = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection) }
    XCTAssertTrue(fixture.client.consumptions.isEmpty)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testConcurrentApprovalsReserveOneLocalConsumption() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    fixture.client.pauseConsumption = true
    let first = Task { try await fixture.service.deliver("First", to: target, action: .copyCorrection) }
    await waitUntil { fixture.client.consumptions.count == 1 }
    await assertFails { _ = try await fixture.service.deliver("Second", to: target, action: .copyCorrection) }
    fixture.client.resumeConsumption()
    let firstResult = try await first.value
    XCTAssertEqual(firstResult, .copied)
    XCTAssertEqual(fixture.client.consumptions.count, 1)
    XCTAssertEqual(fixture.writer.values, ["First"])
  }

  func testDiscardDuringConsumptionSuppressesLateClipboardWrite() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    fixture.client.pauseConsumption = true
    let delivery = Task { try await fixture.service.deliver("Correction", to: target, action: .copyCorrection) }
    await waitUntil { fixture.client.consumptions.count == 1 }
    fixture.service.discard(target)
    fixture.client.resumeConsumption()
    await assertFails { _ = try await delivery.value }
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testCancellationDuringConsumptionSuppressesLateClipboardWrite() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    fixture.client.pauseConsumption = true
    let delivery = Task { try await fixture.service.deliver("Correction", to: target, action: .copyCorrection) }
    await waitUntil { fixture.client.consumptions.count == 1 }
    delivery.cancel()
    fixture.client.resumeConsumption()
    await assertFails { _ = try await delivery.value }
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testStopDuringConsumptionIsTerminalAndNeverCopies() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    fixture.client.pauseConsumption = true
    let delivery = Task { try await fixture.service.deliver("Correction", to: target, action: .copyCorrection) }
    await waitUntil { fixture.client.consumptions.count == 1 }
    await fixture.service.stop()
    fixture.client.resumeConsumption()
    await assertFails { _ = try await delivery.value }
    await assertFails { _ = try await fixture.service.captureFrontmostTarget() }
    XCTAssertThrowsError(try fixture.service.makeStandaloneTarget())
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testLateCancelledCaptureReleasesTokenWithoutIssuingTarget() async throws {
    let fixture = IndependentAXFixture()
    let session = try XCTUnwrap(fixture.client.currentSession)
    fixture.client.pauseCapture = true
    let capture = Task { try await fixture.service.captureFrontmostTarget() }
    await waitUntil { fixture.client.captureCount == 1 }
    capture.cancel()
    fixture.client.resumeCapture()
    await assertFails { _ = try await capture.value }
    await waitUntil { fixture.client.discards.count == 1 }
    XCTAssertEqual(fixture.client.discards.first?.1, session)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testLateCaptureCannotBindToReplacementConnectionSession() async throws {
    let fixture = IndependentAXFixture()
    let originalSession = try XCTUnwrap(fixture.client.currentSession)
    fixture.client.pauseCapture = true
    let capture = Task { try await fixture.service.captureFrontmostTarget() }
    await waitUntil { fixture.client.captureCount == 1 }
    fixture.client.currentSession = UUID()
    fixture.client.resumeCapture()
    await assertFails { _ = try await capture.value }
    await waitUntil { fixture.client.discards.count == 1 }
    XCTAssertEqual(fixture.client.discards.first?.1, originalSession)
  }

  func testConnectionReplacementInvalidatesPreviouslyIssuedTarget() async throws {
    let fixture = IndependentAXFixture()
    let target = try await fixture.service.captureFrontmostTarget().target
    fixture.client.currentSession = UUID()
    await assertFails { _ = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection) }
    XCTAssertTrue(fixture.client.consumptions.isEmpty)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testExpiredCaptureCannotCopyAndUncertainClipboardWriteIsNeverRetried() async throws {
    let fixture = IndependentAXFixture()
    let expired = try await fixture.service.captureFrontmostTarget().target
    fixture.clock.date.addTimeInterval(AccessibilityAgentContract.captureLifetime + 1)
    await assertFails { _ = try await fixture.service.deliver("Expired", to: expired, action: .copyCorrection) }
    let current = try await fixture.service.captureFrontmostTarget().target
    fixture.writer.failAfterWriting = true
    do {
      _ = try await fixture.service.deliver("Uncertain", to: current, action: .copyCorrection)
      XCTFail("Expected clipboard uncertainty")
    } catch let failure as PromptDeliveryFailure { XCTAssertEqual(failure.effect, .unknown) }
    await assertFails { _ = try await fixture.service.deliver("Retry", to: current, action: .copyCorrection) }
    XCTAssertEqual(fixture.writer.values, ["Uncertain"])
  }

  private func assertFails(_ body: () async throws -> Void) async {
    do { try await body(); XCTFail("Expected fail-closed rejection") } catch {}
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<1_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Expected the synthetic operation to reach its controlled suspension")
  }
}

@MainActor
private final class IndependentAXFixture {
  let client = FakeAccessibilityAgentClient()
  let writer = AXCopyRecorder()
  let clock = AXAdapterClock()
  lazy var service = IndependentAccessibilityTargetService(client: client, pasteboard: writer, now: { [clock] in clock.date })
}

@MainActor
private final class AXAdapterClock { var date = Date(timeIntervalSince1970: 1000) }

@MainActor
private final class AXCopyRecorder: PasteboardWriting {
  var values: [String] = []
  var failAfterWriting = false
  func write(_ value: String) throws {
    values.append(value)
    if failAfterWriting { throw BexError.storageFailure("Synthetic write failed after changing clipboard") }
  }
}

@MainActor
private final class FakeAccessibilityAgentClient: AccessibilityAgentClientServing {
  var currentSession: UUID? = UUID()
  var failure: AccessibilityAgentFailure?
  var captureCount = 0
  var validationCount = 0
  var consumptions: [(UUID, UUID)] = []
  var discards: [(UUID, UUID)] = []
  var pauseCapture = false
  var pauseConsumption = false
  var onValidate: (() -> Void)?
  private var captureWaiter: CheckedContinuation<Void, Never>?
  private var consumeWaiter: CheckedContinuation<Void, Never>?

  func status() async throws -> Bool { if let failure { throw failure }; return true }
  func capture() async throws -> AccessibilityAgentCapturedResult {
    if let failure { throw failure }
    let session = try XCTUnwrap(currentSession)
    let result = AccessibilityAgentCapturedResult(capture: AccessibilityAgentCapture(token: UUID(),
      processID: 33, bundleIdentifier: "test.destination", applicationName: "Destination",
      launchDate: Date(timeIntervalSince1970: 5), original: "Original draft"), session: session)
    captureCount += 1
    if pauseCapture { await withCheckedContinuation { captureWaiter = $0 } }
    return result
  }
  func validate(_ token: UUID, session: UUID) async throws {
    validationCount += 1
    onValidate?()
    if let failure { throw failure }
    guard currentSession == session else { throw AccessibilityAgentFailure.stale }
  }
  func consume(_ token: UUID, session: UUID) async throws {
    consumptions.append((token, session))
    if pauseConsumption { await withCheckedContinuation { consumeWaiter = $0 } }
    if let failure { throw failure }
  }
  func discard(_ token: UUID, session: UUID) async { discards.append((token, session)) }
  func stop() async { currentSession = nil }
  func resumeCapture() { captureWaiter?.resume(); captureWaiter = nil }
  func resumeConsumption() { consumeWaiter?.resume(); consumeWaiter = nil }
}
