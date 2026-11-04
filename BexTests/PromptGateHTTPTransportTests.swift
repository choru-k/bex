import Foundation
import XCTest

@testable import Bex

/// UNCOMPILED / UNRUN in cloud. Synthetic transports, explicit terminal events,
/// manual clocks and callback gates only. No socket, app, helper or provider launch.
@MainActor
final class PromptGateHTTPTransportTests: XCTestCase {
  func testCreditsRemainOwnedThroughActorDispatchAfterSocketDrain() async throws {
    let callback = PromptGateTestSignal()
    let closed = PromptGateTestSignal()
    let (owner, listener, _) = makeOwner(onRequest: { _, _ in await callback.wait() },
      onClose: { _ in await closed.wait() })
    _ = try await owner.start()
    let peers = (0..<8).map { _ in PromptGateFakeConnection() }
    for peer in peers { let offered = await listener.offer(peer); XCTAssertTrue(offered) }
    for peer in peers {
      await peer.completeReceive(request)
      await peer.completeReceive(nil, complete: true)
      await peer.emitCancelled()
    }
    var state = await owner.snapshot()
    XCTAssertEqual(state.connections, 8, "terminal I/O cannot release actor callback ownership")
    XCTAssertEqual(listener.credits, 0)
    let excess = await listener.offer(PromptGateFakeConnection())
    XCTAssertFalse(excess)
    await callback.signal()
    state = await owner.snapshot()
    XCTAssertEqual(state.connections, 8, "close notifications have their own bounded ownership")
    await closed.signal()
    try await waitUntil { await owner.snapshot().connections == 0 }
    XCTAssertEqual(listener.credits, 8)
    try await stopAndDrain(owner, listener: listener, peers: [])
  }

  func testStopIncludesQueuedAcceptAndBothIOCompletionOrders() async throws {
    let (owner, listener, _) = makeOwner()
    _ = try await owner.start()
    let first = PromptGateFakeConnection()
    let queued = PromptGateFakeConnection()
    _ = await listener.offer(first)
    let reservation = await listener.reserve(queued)
    let id = try XCTUnwrap(reservation)
    let stop = Task { await owner.stop() }
    try await waitUntil { await owner.snapshot().stopWaiters == 1 }
    await listener.deliverReserved(id)
    XCTAssertEqual(queued.records.receiveCalls, 0)
    XCTAssertEqual(queued.records.cancelCalls, 1)
    await first.emitCancelled()
    var state = await owner.snapshot()
    XCTAssertEqual(state.connections, 2)
    await first.completeReceive(request, failed: true)
    await queued.emitCancelled()
    try await waitUntil { await owner.snapshot().connections == 0 }
    state = await owner.snapshot()
    XCTAssertEqual(state.stopWaiters, 1, "listener terminal acknowledgement is still outstanding")
    await listener.emit(.cancelled)
    await stop.value
    XCTAssertEqual(listener.credits, 0)
  }

  func testReadDispatchAndResponseDeadlinesDoNotSlideOrPretendToDrain() async throws {
    let requests = PromptGateRequestCapture()
    let (owner, listener, clock) = makeOwner(onRequest: { id, request in await requests.record(id, request) })
    _ = try await owner.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    let reading = clock.deadlines.last!
    await peer.completeReceive(Data("POST ".utf8))
    XCTAssertEqual(clock.deadlines.last!.delay, 10)
    XCTAssertTrue(clock.deadlines.last === reading, "partial bytes do not extend the absolute read budget")
    await reading.fire()
    await peer.emitCancelled()
    var state = await owner.snapshot()
    XCTAssertEqual(state.connections, 1)
    await peer.completeReceive(nil, failed: true)
    try await waitUntil { await owner.snapshot().connections == 0 }

    let valid = PromptGateFakeConnection()
    _ = await listener.offer(valid)
    let oldDeadline = clock.deadlines.last!
    await valid.completeReceive(request)
    try await waitUntil { await requests.id != nil }
    let id = await requests.id!
    let dispatchDeadline = clock.deadlines.last!
    XCTAssertEqual(dispatchDeadline.delay, 5)
    let held = await owner.hold(id)
    XCTAssertTrue(held)
    await oldDeadline.fire(evenIfCancelled: true)
    await dispatchDeadline.fire(evenIfCancelled: true)
    XCTAssertEqual(valid.records.cancelCalls, 0)
    let sent = Task { await owner.respond(id, status: 200, body: Data()) }
    try await waitUntil { !valid.records.responses.isEmpty }
    await clock.deadlines.last!.fire()
    let success = await sent.value
    XCTAssertFalse(success, "timeout is not successful acknowledgement delivery")
    await valid.emitCancelled()
    state = await owner.snapshot()
    XCTAssertEqual(state.connections, 1, "pending read and send still belong to this connection")
    await valid.completeSend()
    await valid.completeReceive(nil, failed: true)
    try await waitUntil { await owner.snapshot().connections == 0 }
    try await stopAndDrain(owner, listener: listener, peers: [])
  }

  func testMalformedRequestsHaveEmptyResponseAndNeverReachHandler() async throws {
    let requests = PromptGateRequestCapture()
    let (owner, listener, _) = makeOwner(onRequest: { id, request in await requests.record(id, request) })
    _ = try await owner.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await peer.completeReceive(Data("POST /v1/review HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nContent-Length: -1\r\n\r\nsensitive-body".utf8))
    XCTAssertTrue(peer.records.responses[0].contains("400 Bad Request"))
    XCTAssertTrue(peer.records.responses[0].contains("Content-Length: 0\r\n"))
    XCTAssertFalse(peer.records.responses[0].contains("sensitive-body"))
    let requestID = await requests.id
    XCTAssertNil(requestID)
    try await stopAndDrain(owner, listener: listener, peers: [peer])
  }

  func testFailedSendDoesNotReportSuccessfulAckAndCompletionIsSingleUse() async throws {
    let requests = PromptGateRequestCapture()
    let (owner, listener, _) = makeOwner(onRequest: { id, request in await requests.record(id, request) })
    _ = try await owner.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await peer.completeReceive(request)
    try await waitUntil { await requests.id != nil }
    let id = await requests.id!
    let response = Task { await owner.respond(id, status: 200, body: Data()) }
    try await waitUntil { !peer.records.responses.isEmpty }
    let duplicate = await owner.respond(id, status: 200, body: Data())
    XCTAssertFalse(duplicate)
    await peer.completeSend(succeeded: false)
    let success = await response.value
    XCTAssertFalse(success)
    XCTAssertEqual(peer.records.responses.count, 1)
    try await stopAndDrain(owner, listener: listener, peers: [peer])
  }

  func testFailedListenerAfterReadyClosesAdmissionAndNotifiesOwnerOnce() async throws {
    let terminal = PromptGateTerminationCapture()
    let listener = PromptGateFakeListener()
    let owner = PromptGateHTTPTransport(makeListener: { listener }, scheduler: PromptGateFakeScheduler(),
      onRequest: { _, _ in }, onClose: { _ in }, onTermination: { terminal.record() })
    _ = try await owner.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await listener.emit(.failed)
    await listener.emit(.failed)
    XCTAssertEqual(terminal.count, 1)
    XCTAssertEqual(listener.credits, 0)
    XCTAssertEqual(peer.records.cancelCalls, 1)
    try await stopAndDrain(owner, listener: listener, peers: [peer])
  }

  func testStartupTimeoutKeepsListenerOwnedUntilCancelledAndIgnoresLateReady() async throws {
    let listener = PromptGateFakeListener(automaticallyReady: false)
    let clock = PromptGateFakeScheduler()
    let owner = PromptGateHTTPTransport(makeListener: { listener }, scheduler: clock,
      onRequest: { _, _ in }, onClose: { _ in })
    let start = Task { try await owner.start() }
    try await waitUntil { !clock.deadlines.isEmpty }
    await clock.deadlines[0].fire()
    do { _ = try await start.value; XCTFail("startup should fail") } catch {}
    await listener.emit(.ready)
    let state = await owner.snapshot()
    XCTAssertTrue(state.stopping)
    try await stopAndDrain(owner, listener: listener, peers: [])
  }

  private var request: Data {
    Data("POST /v1/review HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nContent-Length: 2\r\n\r\n{}".utf8)
  }
  private func makeOwner(
    onRequest: @escaping @Sendable (UUID, PromptHTTPRequestParser.Request) async -> Void = { _, _ in },
    onClose: @escaping @Sendable (UUID) async -> Void = { _ in }
  ) -> (PromptGateHTTPTransport, PromptGateFakeListener, PromptGateFakeScheduler) {
    let listener = PromptGateFakeListener()
    let clock = PromptGateFakeScheduler()
    return (PromptGateHTTPTransport(makeListener: { listener }, scheduler: clock,
      onRequest: onRequest, onClose: onClose), listener, clock)
  }
  private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1_000 {
      if await predicate() { return }
      await Task.yield()
    }
    XCTFail("synthetic callback registration did not arrive")
    throw PromptGateTestFailure.registrationDidNotArrive
  }
  private func stopAndDrain(_ owner: PromptGateHTTPTransport, listener: PromptGateFakeListener,
    peers: [PromptGateFakeConnection]) async throws {
    let stop = Task { await owner.stop() }
    try await waitUntil { await owner.snapshot().stopWaiters > 0 }
    await listener.emit(.cancelled)
    for peer in peers {
      await peer.emitCancelled()
      await peer.completeReceive(nil, failed: true)
      await peer.completeSend()
    }
    await stop.value
    let state = await owner.snapshot()
    XCTAssertEqual(state.connections, 0)
  }
}

private actor PromptGateRequestCapture {
  var id: UUID?
  func record(_ id: UUID, _ request: PromptHTTPRequestParser.Request) { self.id = id }
}
private final class PromptGateTerminationCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var count: Int { lock.withLock { calls } }
  func record() { lock.withLock { calls += 1 } }
}

private final class PromptGateFakeListener: PromptGateListenerTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let automaticallyReady: Bool
  private var queue: DispatchQueue?
  private var stateHandler: (@Sendable (PromptGateListenerState) -> Void)?
  private var connectionHandler: (@Sendable (any PromptGateConnectionTransport) -> Void)?
  private var remaining = 0
  private var starts = 0
  private var constructions = 0
  private var cancellations = 0
  private var reserved: [UUID: PromptGateFakeConnection] = [:]
  init(automaticallyReady: Bool = true) { self.automaticallyReady = automaticallyReady }
  var newConnectionLimit: Int {
    get { lock.withLock { remaining } }
    set { lock.withLock { remaining = newValue } }
  }
  var port: UInt16? { 4321 }
  var credits: Int { newConnectionLimit }
  var startCalls: Int { lock.withLock { starts } }
  var factoryCalls: Int { lock.withLock { constructions } }
  func factoryResult() -> any PromptGateListenerTransport {
    lock.withLock { constructions += 1 }
    return self
  }
  var cancelCalls: Int { lock.withLock { cancellations } }
  func start(queue: DispatchQueue, state: @escaping @Sendable (PromptGateListenerState) -> Void,
    connection: @escaping @Sendable (any PromptGateConnectionTransport) -> Void) {
    lock.withLock { self.queue = queue; stateHandler = state; connectionHandler = connection; starts += 1 }
    if automaticallyReady { queue.async { state(.ready) } }
  }
  func cancel() { lock.withLock { cancellations += 1 } } // Terminal acknowledgement is explicit.
  func reserve(_ connection: PromptGateFakeConnection) async -> UUID? {
    await onQueue {
      self.lock.withLock {
        guard self.remaining > 0 else { return nil }
        self.remaining -= 1
        let id = UUID()
        self.reserved[id] = connection
        return id
      }
    }
  }
  func deliverReserved(_ id: UUID) async {
    await onQueue {
      let pair = self.lock.withLock { (self.reserved.removeValue(forKey: id), self.connectionHandler) }
      if let connection = pair.0 { pair.1?(connection) }
    }
  }
  func offer(_ connection: PromptGateFakeConnection) async -> Bool {
    guard let id = await reserve(connection) else { return false }
    await deliverReserved(id)
    return true
  }
  func emit(_ state: PromptGateListenerState) async {
    await onQueue { self.lock.withLock { self.stateHandler }?(state) }
  }
  private func onQueue<T: Sendable>(_ action: @escaping @Sendable () -> T) async -> T {
    let queue = lock.withLock { self.queue! }
    return await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: action()) }
    }
  }
}

private final class PromptGateFakeConnection: PromptGateConnectionTransport, @unchecked Sendable {
  struct Records: Sendable {
    var startCalls = 0
    var receiveCalls = 0
    var maximumReceive = 0
    var cancelCalls = 0
    var responses: [String] = []
  }
  private let lock = NSLock()
  private var queue: DispatchQueue?
  private var stateHandler: (@Sendable (PromptGateConnectionState) -> Void)?
  private var receiveHandler: (@Sendable (Data?, Bool, Bool) -> Void)?
  private var sendHandler: (@Sendable (Bool) -> Void)?
  private var history = Records()
  var records: Records { lock.withLock { history } }
  func start(queue: DispatchQueue, state: @escaping @Sendable (PromptGateConnectionState) -> Void) {
    lock.withLock { self.queue = queue; stateHandler = state; history.startCalls += 1 }
  }
  func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void) {
    lock.withLock {
      precondition(receiveHandler == nil)
      history.receiveCalls += 1
      history.maximumReceive = maximumLength
      receiveHandler = completion
    }
  }
  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    lock.withLock {
      precondition(sendHandler == nil)
      history.responses.append(String(decoding: data, as: UTF8.self))
      sendHandler = completion
    }
  }
  func cancel() { lock.withLock { history.cancelCalls += 1 } }
  func emitCancelled() async {
    await onQueue { self.lock.withLock { self.stateHandler }?(.cancelled) }
  }
  func completeReceive(_ data: Data?, complete: Bool = false, failed: Bool = false) async {
    await onQueue {
      let handler = self.lock.withLock { let value = self.receiveHandler; self.receiveHandler = nil; return value }
      handler?(data, complete, failed)
    }
  }
  func completeSend(succeeded: Bool = true) async {
    await onQueue {
      let handler = self.lock.withLock { let value = self.sendHandler; self.sendHandler = nil; return value }
      handler?(succeeded)
    }
  }
  private func onQueue(_ action: @escaping @Sendable () -> Void) async {
    let queue = lock.withLock { self.queue! }
    await withCheckedContinuation { continuation in
      queue.async { action(); continuation.resume() }
    }
  }
}

private final class PromptGateFakeScheduler: PromptGateScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [PromptGateFakeDeadline] = []
  var deadlines: [PromptGateFakeDeadline] { lock.withLock { stored } }
  func schedule(after seconds: TimeInterval, queue: DispatchQueue,
    action: @escaping @Sendable () -> Void) -> any PromptGateDeadline {
    let deadline = PromptGateFakeDeadline(delay: seconds, queue: queue, action: action)
    lock.withLock { stored.append(deadline) }
    return deadline
  }
}
private final class PromptGateFakeDeadline: PromptGateDeadline, @unchecked Sendable {
  private let lock = NSLock()
  private let queue: DispatchQueue
  private let action: @Sendable () -> Void
  private var cancelled = false
  let delay: TimeInterval
  var isCancelled: Bool { lock.withLock { cancelled } }
  init(delay: TimeInterval, queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
    self.delay = delay
    self.queue = queue
    self.action = action
  }
  func cancel() { lock.withLock { cancelled = true } }
  func fire(evenIfCancelled: Bool = false) async {
    await withCheckedContinuation { continuation in
      queue.async {
        if evenIfCancelled || !self.lock.withLock({ self.cancelled }) { self.action() }
        continuation.resume()
      }
    }
  }
}

private enum PromptGateTestFailure: Error { case registrationDidNotArrive }
private actor PromptGateTestSignal {
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if signalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func signal() {
    signalled = true
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }
}

/// Same synthetic transport seams, now through the real server actor. Rendezvous
/// storage is in-memory: tests never create credentials/files or bind a listener.
@MainActor
final class PromptGateIPCSyntheticServerTests: XCTestCase {
  func testDisconnectDefersInvalidationUntilLateHandlerEffectsFinish() async throws {
    let (server, listener, store, _) = makeServer()
    let handler = PromptGateApplicationHandler()
    await server.setHandlers(onRequest: { await handler.request($0) },
      onInvalidation: { await handler.invalidate($0) })
    try await server.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await peer.completeReceive(try reviewWire(token: XCTUnwrap(store.value).authenticationToken))
    try await waitUntil { await handler.entered }
    await peer.completeReceive(nil, complete: true)
    try await waitUntil { await server.snapshot().invalidationActive }
    let before = await handler.invalidations
    XCTAssertEqual(before, 0)
    await handler.finish(true)
    try await waitUntil { await handler.invalidations == 1 }
    let after = await server.snapshot()
    XCTAssertFalse(after.requestHandlerActive)
    XCTAssertNil(after.pendingConnectionID)
    try await stopAndDrain(server, listener: listener, peers: [peer])
  }

  func testStopWaitsForLateHandlerBeforeFinalInvalidationAndRestart() async throws {
    let (server, listener, store, _) = makeServer()
    let handler = PromptGateApplicationHandler()
    await server.setHandlers(onRequest: { await handler.request($0) },
      onInvalidation: { await handler.invalidate($0) })
    try await server.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await peer.completeReceive(try reviewWire(token: XCTUnwrap(store.value).authenticationToken))
    try await waitUntil { await handler.entered }
    let stop = Task { await server.stop() }
    try await waitUntil { await server.snapshot().stopping }
    await listener.emit(.cancelled)
    await peer.emitCancelled()
    await peer.completeReceive(nil, failed: true)
    let blocked = await server.snapshot()
    XCTAssertTrue(blocked.stopping)
    XCTAssertTrue(blocked.requestHandlerActive)
    XCTAssertNil(store.value)
    do { try await server.start(); XCTFail("restart cannot overlap handler drain") } catch {}
    let before = await handler.invalidations
    XCTAssertEqual(before, 0)
    await handler.finish(true)
    await stop.value
    let after = await handler.invalidations
    XCTAssertEqual(after, 1)
  }

  func testFailedStartupKeepsOwnerInstalledUntilStopJoinsDrain() async throws {
    let (server, listener, _, factory) = makeServer(automaticallyReady: false)
    let start = Task { try await server.start() }
    try await waitUntil { listener.startCalls == 1 }
    await listener.emit(.failed)
    try await waitUntil { listener.cancelCalls > 0 }
    do { try await server.start(); XCTFail("old owner is still draining") } catch {}
    XCTAssertEqual(factory.count, 1)
    let stop = Task { await server.stop() }
    await listener.emit(.cancelled)
    do { try await start.value; XCTFail("failed startup") } catch {}
    await stop.value
    let state = await server.snapshot()
    XCTAssertFalse(state.hasTransport)
    XCTAssertFalse(state.ready)
  }

  func testListenerFailureAfterReadyWithdrawsPublishedRendezvous() async throws {
    let (server, listener, store, _) = makeServer()
    try await server.start()
    XCTAssertNotNil(store.value)
    await listener.emit(.failed)
    try await waitUntil { await server.snapshot().stopping }
    XCTAssertNil(store.value)
    let state = await server.snapshot()
    XCTAssertFalse(state.ready)
    await listener.emit(.cancelled)
    try await waitUntil { !(await server.snapshot().stopping) }
    let final = await server.snapshot()
    XCTAssertFalse(final.hasTransport)
  }

  func testUnauthenticatedBodyNeverReachesApplicationHandler() async throws {
    let (server, listener, _, _) = makeServer()
    let calls = PromptGateTerminationCapture()
    await server.setHandlers(onRequest: { _ in calls.record(); return true }, onInvalidation: { _ in })
    try await server.start()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await peer.completeReceive(try reviewWire(token: String(repeating: "x", count: 64)))
    try await waitUntil { !peer.records.responses.isEmpty }
    XCTAssertTrue(peer.records.responses[0].contains("401 Unauthorized"))
    XCTAssertTrue(peer.records.responses[0].hasSuffix("\r\n\r\n"))
    XCTAssertEqual(calls.count, 0)
    try await stopAndDrain(server, listener: listener, peers: [peer])
  }

  func testDuplicateCompleteCannotReplaceAckAndOMPRequiresDeliveryIdentity() async throws {
    let (server, listener, store, _) = makeServer()
    await server.setHandlers(onRequest: { _ in true }, onInvalidation: { _ in })
    try await server.start()
    let token = try XCTUnwrap(store.value).authenticationToken
    let requestID = UUID()
    let review = PromptGateFakeConnection()
    _ = await listener.offer(review)
    await review.completeReceive(try reviewWire(token: token, requestID: requestID, client: .ohMyPi))
    try await waitUntil {
      let state = await server.snapshot()
      return state.pendingConnectionID != nil && !state.requestHandlerActive
    }
    let approval = Task {
      try await server.complete(requestID: requestID, outcome: .approved, awaitAcknowledgement: true,
        approvedPrompt: "Synthetic approved prompt", integrationID: "synthetic-integration")
    }
    try await waitUntil { !review.records.responses.isEmpty }
    do {
      try await server.complete(requestID: requestID, outcome: .approved, awaitAcknowledgement: true,
        approvedPrompt: "Different synthetic prompt", integrationID: "synthetic-integration")
      XCTFail("duplicate complete must fail")
    } catch {}
    let body = try XCTUnwrap(review.records.responses[0].components(separatedBy: "\r\n\r\n").last)
    let response = try JSONDecoder().decode(HookReviewResponseEnvelope.self, from: Data(body.utf8))
    let acknowledgment = HookAcknowledgmentEnvelope(version: 1, authenticationToken: token,
      requestID: requestID, acknowledgmentToken: try XCTUnwrap(response.acknowledgmentToken),
      integrationID: "wrong-integration", deliveryToken: response.deliveryToken, deliveryStatus: "delivered")
    let ack = PromptGateFakeConnection()
    _ = await listener.offer(ack)
    await ack.completeReceive(wire(path: "/v1/ack", body: try JSONEncoder().encode(acknowledgment)))
    try await waitUntil { !ack.records.responses.isEmpty }
    XCTAssertTrue(ack.records.responses[0].contains("403 Forbidden"))
    XCTAssertEqual(review.records.responses.count, 1)
    approval.cancel()
    do { try await approval.value; XCTFail("cancelled approval") } catch {}
    try await stopAndDrain(server, listener: listener, peers: [review, ack])
  }

  func testPrecancelledApprovalClosesHeldConnectionWithoutInstallingContinuation() async throws {
    let (server, listener, store, _) = makeServer()
    await server.setHandlers(onRequest: { _ in true }, onInvalidation: { _ in })
    try await server.start()
    let requestID = UUID()
    let peer = PromptGateFakeConnection()
    _ = await listener.offer(peer)
    await peer.completeReceive(try reviewWire(token: XCTUnwrap(store.value).authenticationToken,
      requestID: requestID))
    try await waitUntil {
      let state = await server.snapshot()
      return state.pendingConnectionID != nil && !state.requestHandlerActive
    }
    let gate = PromptGateTestSignal()
    let approval = Task {
      await gate.wait()
      try await server.complete(requestID: requestID, outcome: .approved, awaitAcknowledgement: true,
        approvedPrompt: nil, integrationID: nil)
    }
    approval.cancel()
    await gate.signal()
    do { try await approval.value; XCTFail("pre-cancelled approval") } catch {}
    try await waitUntil { peer.records.cancelCalls == 1 }
    let state = await server.snapshot()
    XCTAssertNil(state.pendingConnectionID)
    XCTAssertTrue(peer.records.responses.isEmpty)
    try await stopAndDrain(server, listener: listener, peers: [peer])
  }

  private func makeServer(automaticallyReady: Bool = true)
    -> (PromptGateIPCServer, PromptGateFakeListener, PromptGateMemoryRendezvous, PromptGateTerminationCapture) {
    let listener = PromptGateFakeListener(automaticallyReady: automaticallyReady)
    let clock = PromptGateFakeScheduler()
    let store = PromptGateMemoryRendezvous()
    let factory = PromptGateTerminationCapture()
    let server = PromptGateIPCServer(makeTransport: { request, close, termination in
      factory.record()
      return PromptGateHTTPTransport(makeListener: { listener }, scheduler: clock,
        onRequest: request, onClose: close, onTermination: termination)
    }, rendezvousStorage: store)
    return (server, listener, store, factory)
  }
  private func reviewWire(token: String, requestID: UUID = UUID(), client: PromptClient = .claudeCode) throws -> Data {
    let request = HookReviewRequest(requestID: requestID, client: client, integrationID: "synthetic-integration",
      prompt: "Synthetic prompt", sessionID: "synthetic-session", cwd: "/synthetic", helperPID: 1)
    let envelope = HookReviewEnvelope(version: 1, authenticationToken: token, request: request)
    return wire(path: "/v1/review", body: try JSONEncoder().encode(envelope))
  }
  private func wire(path: String, body: Data) -> Data {
    Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
  }
  private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1_000 {
      if await predicate() { return }
      await Task.yield()
    }
    XCTFail("synthetic callback registration did not arrive")
    throw PromptGateTestFailure.registrationDidNotArrive
  }
  private func stopAndDrain(_ server: PromptGateIPCServer, listener: PromptGateFakeListener,
    peers: [PromptGateFakeConnection]) async throws {
    let stop = Task { await server.stop() }
    try await waitUntil { await server.snapshot().stopping }
    await listener.emit(.cancelled)
    for peer in peers {
      await peer.emitCancelled()
      await peer.completeReceive(nil, failed: true)
      await peer.completeSend()
    }
    await stop.value
  }
}

private final class PromptGateMemoryRendezvous: PromptGateRendezvousStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: HookRendezvous?
  var value: HookRendezvous? { lock.withLock { stored } }
  func publish(_ value: HookRendezvous) throws { lock.withLock { stored = value } }
  func remove(ifTokenMatches token: String) {
    lock.withLock { if stored?.authenticationToken == token { stored = nil } }
  }
}
private actor PromptGateApplicationHandler {
  private(set) var entered = false
  private(set) var invalidations = 0
  private var continuation: CheckedContinuation<Bool, Never>?
  func request(_ request: HookReviewRequest) async -> Bool {
    entered = true
    return await withCheckedContinuation { continuation = $0 }
  }
  func finish(_ accepted: Bool) {
    let owned = continuation
    continuation = nil
    owned?.resume(returning: accepted)
  }
  func invalidate(_ requestID: UUID) { invalidations += 1 }
}
