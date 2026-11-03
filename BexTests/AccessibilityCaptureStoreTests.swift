import Foundation
import XCTest
@testable import Bex

@MainActor
final class AccessibilityCaptureStoreTests: XCTestCase {
  func testHelloIsBoundedAndContainsNoCaptureOrTrustState() throws {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let challenge = UUID()
    let request = AccessibilityAgentRequest(operation: .hello, challenge: challenge)
    let response = store.handle(request)
    XCTAssertNil(response.failure)
    XCTAssertNotNil(response.session)
    XCTAssertEqual(response.challenge, challenge)
    XCTAssertNil(response.captured)
    XCTAssertNil(response.trusted)
    XCTAssertEqual(observer.captureCount, 0)
    XCTAssertLessThan(try AccessibilityAgentCodec.encode(response).count, 1024)
  }

  func testCaptureBeforeHelloAndWrongSessionCannotReadAnything() {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let request = AccessibilityAgentRequest(operation: .capture, session: UUID())
    XCTAssertEqual(store.handle(request).failure, .unauthorized)
    _ = store.handle(AccessibilityAgentRequest(operation: .hello, challenge: UUID()))
    XCTAssertEqual(store.handle(request).failure, .unauthorized)
    XCTAssertEqual(observer.captureCount, 0)
  }

  func testCaptureAndConsumptionAreConnectionBoundAndSingleUse() throws {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let session = try handshake(store)
    let capture = try XCTUnwrap(store.handle(AccessibilityAgentRequest(operation: .capture, session: session)).captured)
    XCTAssertEqual(capture.original, "Original draft")
    let consume = AccessibilityAgentRequest(operation: .consume, session: session, capture: capture.token)
    XCTAssertNil(store.handle(consume).failure)
    XCTAssertEqual(store.handle(consume).failure, .stale)
    let otherStore = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let otherSession = try handshake(otherStore)
    XCTAssertEqual(otherStore.handle(AccessibilityAgentRequest(operation: .validate, session: otherSession, capture: capture.token)).failure, .stale)
  }

  func testRepeatedHelloCannotReplaceLiveSession() throws {
    let store = AccessibilityCaptureStore(observer: FakeAXObserver(), callerProcessID: 10)
    let session = try handshake(store)
    let second = store.handle(AccessibilityAgentRequest(operation: .hello, challenge: UUID()))
    XCTAssertEqual(second.failure, .unauthorized)
    XCTAssertEqual(store.session, session)
  }

  func testObservedDriftPermanentlyRevokesCapture() throws {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let session = try handshake(store)
    let capture = try XCTUnwrap(store.handle(AccessibilityAgentRequest(operation: .capture, session: session)).captured)
    observer.field.stale = true
    let validate = AccessibilityAgentRequest(operation: .validate, session: session, capture: capture.token)
    XCTAssertEqual(store.handle(validate).failure, .stale)
    observer.field.stale = false
    XCTAssertEqual(store.handle(validate).failure, .stale)
  }

  func testRevokedPermissionDoesNotReviveOldCaptureAfterRegrant() throws {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let session = try handshake(store)
    let capture = try XCTUnwrap(store.handle(AccessibilityAgentRequest(operation: .capture, session: session)).captured)
    observer.isTrusted = false
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .status, session: session)).trusted, false)
    observer.isTrusted = true
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .validate, session: session, capture: capture.token)).failure, .stale)
  }

  func testExpiryCapacityAndDiscardReleaseBoundedStorage() throws {
    let clock = AXTestClock()
    let store = AccessibilityCaptureStore(observer: FakeAXObserver(), callerProcessID: 10, limit: 1, now: { clock.date })
    let session = try handshake(store)
    let request = AccessibilityAgentRequest(operation: .capture, session: session)
    let first = try XCTUnwrap(store.handle(request).captured)
    XCTAssertEqual(store.handle(request).failure, .capacity)
    _ = store.handle(AccessibilityAgentRequest(operation: .discard, session: session, capture: first.token))
    let second = try XCTUnwrap(store.handle(request).captured)
    clock.date.addTimeInterval(AccessibilityAgentContract.captureLifetime + 1)
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .consume, session: session, capture: second.token)).failure, .stale)
    XCTAssertNotNil(store.handle(request).captured)
  }

  func testCloseRejectsAllRequestsAndCannotBeReopened() throws {
    let store = AccessibilityCaptureStore(observer: FakeAXObserver(), callerProcessID: 10)
    let session = try handshake(store)
    store.close()
    XCTAssertNil(store.session)
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .capture, session: session)).failure, .cancelled)
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .hello, challenge: UUID())).failure, .cancelled)
  }

  func testCallerCannotCaptureItselfOrOversizedText() throws {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let session = try handshake(store)
    observer.field.processID = 10
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .capture, session: session)).failure, .unsupported)
    observer.field.processID = 20
    observer.field.original = String(repeating: "x", count: AccessibilityAgentContract.maximumDraftBytes + 1)
    XCTAssertEqual(store.handle(AccessibilityAgentRequest(operation: .capture, session: session)).failure, .unsupported)
  }

  func testInvalidWireShapeAndOversizedBodiesAreRejected() throws {
    let request = AccessibilityAgentRequest(operation: .hello, session: UUID(), challenge: UUID())
    XCTAssertFalse(request.hasValidShape)
    let store = AccessibilityCaptureStore(observer: FakeAXObserver(), callerProcessID: 10)
    XCTAssertEqual(store.handle(request).failure, .malformed)
    XCTAssertThrowsError(try AccessibilityAgentCodec.decode(AccessibilityAgentRequest.self,
      from: Data(repeating: 0, count: AccessibilityAgentContract.maximumMessageBytes + 1)))
    XCTAssertThrowsError(try AccessibilityAgentCodec.decode(AccessibilityAgentRequest.self, from: Data()))
    XCTAssertThrowsError(try AccessibilityAgentCodec.decode(AccessibilityAgentRequest.self, from: Data("{\"operation\":\"replace\"}".utf8)))
  }

  func testSigningRequirementsAreExactAndValidWithoutActivatingService() throws {
    let app = try AccessibilityAgentIdentity.requirement(for: .app)
    let helper = try AccessibilityAgentIdentity.requirement(for: .helper)
    XCTAssertTrue(app.contains("anchor apple generic"))
    XCTAssertTrue(app.contains("identifier \"com.bex.desktop\""))
    XCTAssertTrue(helper.contains("identifier \"com.bex.accessibility\""))
    XCTAssertTrue(app.contains("certificate leaf[subject.OU] = \"ESURPGU29C\""))
    XCTAssertNotEqual(app, helper)
  }

  func testCaptureAndFinalRevalidationShareOneBudgetAndExpiredRequestsNeverObserve() throws {
    let observer = FakeAXObserver()
    let store = AccessibilityCaptureStore(observer: observer, callerProcessID: 10)
    let session = try handshake(store)
    let request = AccessibilityAgentRequest(operation: .capture, session: session)
    let deadline = AccessibilityObservationDeadline()
    XCTAssertNotNil(store.handle(request, deadline: deadline).captured)
    XCTAssertEqual(observer.lastDeadline, deadline.end)
    XCTAssertEqual(observer.field.lastDeadline, deadline.end)
    let previousCount = observer.captureCount
    XCTAssertEqual(store.handle(request, deadline: AccessibilityObservationDeadline(end: 0)).failure, .timeout)
    XCTAssertEqual(observer.captureCount, previousCount)
  }

  private func handshake(_ store: AccessibilityCaptureStore) throws -> UUID {
    try XCTUnwrap(store.handle(AccessibilityAgentRequest(operation: .hello, challenge: UUID())).session)
  }
}

@MainActor
private final class AXTestClock { var date = Date(timeIntervalSince1970: 10_000) }

@MainActor
private final class FakeAXObserver: AccessibilityAgentObserving {
  var isTrusted = true
  var captureCount = 0
  var lastDeadline: UInt64?
  let field = FakeAXField()
  func capture(excluding processID: Int32, before deadline: AccessibilityObservationDeadline) throws -> any AccessibilityCapturedField {
    lastDeadline = deadline.end
    captureCount += 1
    return field
  }
}

@MainActor
private final class FakeAXField: AccessibilityCapturedField {
  var processID: Int32 = 20
  let bundleIdentifier = "test.destination"
  let applicationName = "Test destination"
  let launchDate = Date(timeIntervalSince1970: 100)
  var original = "Original draft"
  var stale = false
  var lastDeadline: UInt64?
  func revalidate(before deadline: AccessibilityObservationDeadline) throws {
    lastDeadline = deadline.end
    try deadline.check()
    if stale { throw AccessibilityAgentFailure.stale }
  }
}
