import Foundation
import XCTest

@testable import Bex

/// UNCOMPILED / UNRUN in cloud. All transports and clocks are synthetic: no socket,
/// URLSession, credentials, provider, application activation or wall-clock sleeps.
@MainActor
final class CodexLoopbackListenerTests: XCTestCase {
  func testEveryDelimiterSplitAndTrailingBodyRetainOnlyHeaders() {
    let header = Data(request.utf8)
    for split in 1..<header.count {
      var parser = CodexLoopbackHeaders()
      XCTAssertEqual(parser.append(header.prefix(split)), .incomplete)
      XCTAssertEqual(parser.append(header.dropFirst(split) + Data("ignored body".utf8)), .complete)
      XCTAssertEqual(parser.count, header.count)
      guard case .callback(let url) = parser.request(port: 1455) else {
        XCTFail("split \(split) must preserve the callback"); continue
      }
      XCTAssertEqual(url.absoluteString, "http://localhost:1455/auth/callback?code=test&state=state")
    }
  }

  func testHeaderCapIsCheckedBeforeAppendIncludingTerminator() {
    let prefix = "GET /auth/callback?code=test&state=state HTTP/1.1\r\nHost: localhost:1455\r\nX-Pad: "
    let limit = CodexLoopbackListener.maximumHeaderBytes
    let exact = Data((prefix + String(repeating: "a", count: limit - prefix.utf8.count - 4) + "\r\n\r\n").utf8)
    var parser = CodexLoopbackHeaders()
    XCTAssertEqual(feed(exact, into: &parser), .complete)
    XCTAssertEqual(parser.count, limit)
    guard case .callback = parser.request(port: 1455) else { return XCTFail("exact cap is valid") }

    var oversized = CodexLoopbackHeaders()
    let tooLong = Data((prefix + String(repeating: "a", count: limit - prefix.utf8.count - 3) + "\r\n\r\n").utf8)
    XCTAssertEqual(feed(tooLong, into: &oversized), .tooLarge)
    XCTAssertEqual(oversized.count, 0, "rejected bytes must be released")
    XCTAssertEqual(oversized.append(Data("\r\n\r\n".utf8)), .tooLarge)

    var unterminated = CodexLoopbackHeaders()
    XCTAssertEqual(feed(Data(repeating: 65, count: limit), into: &unterminated), .tooLarge)
    XCTAssertEqual(unterminated.count, 0)
  }

  func testDeliveredChunkCapIsIndependentOfRetainedHeaderCap() {
    var parser = CodexLoopbackHeaders()
    XCTAssertEqual(parser.append(Data("GET ".utf8)), .incomplete)
    let hugeDelivery = Data(repeating: 65, count: CodexLoopbackListener.maximumReceiveBytes + 1)
    XCTAssertEqual(parser.append(hugeDelivery), .tooLarge)
    XCTAssertEqual(parser.count, 0, "oversized delivery is rejected before copying any of it")
  }

  func testMalformedAuthorityVersionHeadersAndIncompleteRequestsFailClosed() {
    let invalidRequests = [
      "GET @evil.example/auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
      "GET //evil.example/auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
      "GET /auth/callback#fragment HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
      "GET /auth/callback\\path HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
      "GET  /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n\r\n",
      "GET /auth/callback HTTP/7.0\r\nHost: localhost:1455\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\nHost: other.example:1455\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\nHost: localhost:1455\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n Bad: folded\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\nContent-Length: 1\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\nTransfer-Encoding: chunked\r\n\r\n",
      "GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\nX: a\u{0}b\r\n\r\n"
    ]
    for text in invalidRequests {
      var parser = CodexLoopbackHeaders()
      XCTAssertEqual(parser.append(Data(text.utf8)), .complete)
      guard case .invalid = parser.request(port: 1455) else {
        XCTFail("malformed request must fail"); continue
      }
    }
    var incomplete = CodexLoopbackHeaders()
    _ = incomplete.append(Data("GET /auth/callback HTTP/1.1\r\nHost: localhost:1455\r\n".utf8))
    guard case .invalid = incomplete.request(port: 1455) else { return XCTFail("no partial parse") }
  }

  func testHeaderParsingKeepsIPv4IPv6AndHTTP10CompatibilityWithoutChangingCallbackURI() {
    for host in ["localhost:1455", "127.0.0.1:1455", "[::1]:1455"] {
      var parser = CodexLoopbackHeaders()
      _ = parser.append(Data("GET /auth/callback?error=denied HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8))
      guard case .callback(let url) = parser.request(port: 1455) else { return XCTFail("loopback Host") }
      XCTAssertEqual(url.host, "localhost")
    }
    var oldHTTP = CodexLoopbackHeaders()
    _ = oldHTTP.append(Data("GET /auth/callback?code=x HTTP/1.0\r\n\r\n".utf8))
    guard case .callback = oldHTTP.request(port: 1455) else { return XCTFail("HTTP/1.0 remains valid") }
  }

  func testFourCreditsIncludeQueuedAcceptsAndReturnOnlyAfterActualDrain() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let peers = (0..<4).map { _ in LoopbackFakeConnection() }
    var reservations: [UUID] = []
    for peer in peers {
      let reservation = await transport.reserve(peer)
      reservations.append(try XCTUnwrap(reservation))
    }
    let excess = await transport.reserve(LoopbackFakeConnection())
    XCTAssertNil(excess, "queued but not delivered connections already consume capacity")
    for id in reservations { await transport.deliverReserved(id) }
    var state = await listener.snapshot()
    XCTAssertEqual(state.connections, 4)
    XCTAssertTrue(peers.allSatisfy { $0.records.maximumReceive == 4_096 })

    await peers[0].completeReceive(Data("GET /missing HTTP/1.1\r\nHost: localhost:1455\r\n\r\n".utf8))
    await peers[0].emitCancelled()
    XCTAssertEqual(transport.credits, 0, "cancelled state cannot release a pending send")
    await peers[0].completeSend()
    state = await listener.snapshot()
    XCTAssertEqual(state.connections, 3)
    XCTAssertEqual(transport.credits, 1)
    let replacement = LoopbackFakeConnection()
    let offered = await transport.offer(replacement)
    XCTAssertTrue(offered)
    try await stopAndDrain(listener, transport: transport, peers: Array(peers.dropFirst()) + [replacement])
  }

  func testStopWaitsForListenerStateAndAllReceiveCompletionsInEitherOrder() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let first = LoopbackFakeConnection()
    let second = LoopbackFakeConnection()
    _ = await transport.offer(first)
    _ = await transport.offer(second)
    let stop1 = Task { await listener.stop() }
    let stop2 = Task { await listener.stop() }
    try await waitForStopWaiters(2, listener)
    await first.emitCancelled()
    await second.completeReceive(nil, failed: true)
    var state = await listener.snapshot()
    XCTAssertEqual(state.connections, 2)
    XCTAssertEqual(state.stopWaiters, 2)
    await first.completeReceive(Data(request.utf8), failed: true)
    await second.emitCancelled()
    state = await listener.snapshot()
    XCTAssertEqual(state.connections, 0)
    XCTAssertEqual(state.stopWaiters, 2, "listener cancellation is an independent frontier")
    await transport.emit(.cancelled)
    await stop1.value
    await stop2.value
    state = await listener.snapshot()
    XCTAssertEqual(state.stopWaiters, 0)
    XCTAssertEqual(first.records.responses.count, 0, "late callback data must not be parsed")
    XCTAssertEqual(transport.credits, 0)
    await assertCancelled { _ = try await listener.waitForCallback() }
  }

  func testSuccessClosesAdmissionAndCancelsSiblingsButTracksResponseAndQueuedAccept() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let winner = LoopbackFakeConnection()
    let sibling = LoopbackFakeConnection()
    let queued = LoopbackFakeConnection()
    _ = await transport.offer(winner)
    _ = await transport.offer(sibling)
    let reservation = await transport.reserve(queued)
    let pending = try XCTUnwrap(reservation)
    let callback = Task { try await listener.waitForCallback() }
    await winner.completeReceive(Data(request.utf8))
    let url = try await callback.value
    XCTAssertEqual(url.host, "localhost")
    XCTAssertEqual(winner.records.responses.count, 1)
    XCTAssertTrue(winner.records.responses[0].contains("Callback received. Return to Bex to finish sign-in."))
    XCTAssertFalse(winner.records.responses[0].contains("is connected"))
    XCTAssertEqual(sibling.records.cancelCalls, 1)
    await transport.deliverReserved(pending)
    XCTAssertEqual(queued.records.startCalls, 1)
    XCTAssertEqual(queued.records.receiveCalls, 0, "queued accept after success cannot read")
    XCTAssertEqual(queued.records.cancelCalls, 1)
    await transport.emit(.cancelled)
    let secondWait = try await listener.waitForCallback()
    XCTAssertEqual(secondWait, url, "captured URL survives expected listener cancellation")
    let stop = Task { await listener.stop() }
    try await waitForStopWaiters(1, listener)
    await winner.emitCancelled()
    await sibling.emitCancelled()
    await queued.emitCancelled()
    var state = await listener.snapshot()
    XCTAssertEqual(state.connections, 2, "send/receive callbacks still own both slots")
    await sibling.completeReceive(Data(request.utf8))
    XCTAssertEqual(sibling.records.responses.count, 0)
    await winner.completeSend()
    await stop.value
    state = await listener.snapshot()
    XCTAssertEqual(state.connections, 0)
  }

  func testInvalidStatesAndDuplicateParametersDoNotConsumeWaitingLogin() async throws {
    let (listener, transport, clock) = makeListener()
    try await listener.start()
    let callback = Task { try await listener.waitForCallback() }
    try await waitUntil { await listener.snapshot().callbackWaiting }
    let attemptDeadline = clock.deadlines[0]
    let queries = [
      "code=test", "code=test&state", "code=test&state=", "code=test&state=wrong",
      "code=test&state=STATE", "code=test&State=state", "code=test&state=state%00",
      "code=test&state=%2573tate", "error=denied", "error=denied&state=wrong",
      "code=test&state=state&state=state", "code=test&state=wrong&state=state",
      "code=test&state=state&st%61te=state", "code=test&code=other&state=state",
      "code=test&%63ode=other&state=state", "error=a&error=b&state=state",
      "code=test&state=state&extra=a&extra=b"
    ]
    for query in queries {
      let peer = LoopbackFakeConnection()
      let offered = await transport.offer(peer)
      guard offered else {
        XCTFail("rejected callbacks must return capacity")
        throw LoopbackTestFailure.registrationDidNotArrive
      }
      await peer.completeReceive(callbackRequest(query))
      let response = try XCTUnwrap(peer.records.responses.first)
      XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
      XCTAssertTrue(response.hasSuffix("\r\n\r\nInvalid callback"))
      XCTAssertFalse(response.contains(query), "do not reflect untrusted query data")
      var state = await listener.snapshot()
      XCTAssertFalse(state.admissionClosed)
      XCTAssertTrue(state.callbackWaiting)
      XCTAssertTrue(state.listenerPending)
      XCTAssertEqual(state.retainedHeaderBytes, 0)
      XCTAssertEqual(transport.cancelCalls, 0)
      XCTAssertFalse(attemptDeadline.isCancelled, "rejection must preserve the original attempt deadline")
      XCTAssertEqual(clock.deadlines.filter { $0.delay == 300_000_000_000 }.count, 1,
        "rejected requests must not extend the attempt lifetime")
      await peer.emitCancelled()
      state = await listener.snapshot()
      XCTAssertEqual(state.connections, 1, "rejected response still owns its pending send")
      await peer.completeSend()
      state = await listener.snapshot()
      XCTAssertEqual(state.connections, 0)
    }
    let winner = LoopbackFakeConnection()
    let offered = await transport.offer(winner)
    guard offered else {
      XCTFail("valid retry must be admitted")
      throw LoopbackTestFailure.registrationDidNotArrive
    }
    await winner.completeReceive(Data(request.utf8))
    let captured = try await callback.value
    XCTAssertEqual(captured.absoluteString, "http://localhost:1455/auth/callback?code=test&state=state")
    XCTAssertTrue(winner.records.responses.first?.contains("200 OK") == true)
    try await stopAndDrain(listener, transport: transport, peers: [winner])
  }

  func testPercentEncodedStateNameAndValueMatchTheBoundAttempt() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    await peer.completeReceive(callbackRequest("code=test&st%61te=%73tate"))
    let captured = try await listener.waitForCallback()
    let items = URLComponents(url: captured, resolvingAgainstBaseURL: false)?.queryItems
    XCTAssertEqual(items?.first(where: { $0.name == "state" })?.value, "state")
    XCTAssertTrue(peer.records.responses.first?.contains("200 OK") == true)
    try await stopAndDrain(listener, transport: transport, peers: [peer])
  }

  func testMatchingStateOAuthErrorReachesServiceWithoutRequiringCode() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    await peer.completeReceive(callbackRequest("error=access_denied&state=state"))
    let captured = try await listener.waitForCallback()
    XCTAssertEqual(captured.query, "error=access_denied&state=state")
    XCTAssertTrue(peer.records.responses.first?.contains("200 OK") == true)
    try await stopAndDrain(listener, transport: transport, peers: [peer])
  }

  func testOldAttemptStateCannotClaimNewListenerBeforeWaiterRegisters() async throws {
    let transport = LoopbackFakeListener()
    let listener = CodexLoopbackListener(expectedState: "new-state",
      makeTransport: { _ in transport.factoryResult() }, scheduler: LoopbackFakeScheduler())
    try await listener.start()
    let stale = LoopbackFakeConnection()
    let current = LoopbackFakeConnection()
    _ = await transport.offer(stale)
    _ = await transport.offer(current)
    await stale.completeReceive(callbackRequest("code=old&state=old-state"))
    let state = await listener.snapshot()
    XCTAssertFalse(state.admissionClosed)
    XCTAssertFalse(state.callbackWaiting)
    XCTAssertEqual(current.records.cancelCalls, 0, "rejection must preserve another pending connection")
    await current.completeReceive(callbackRequest("code=new&state=new-state"))
    let captured = try await listener.waitForCallback()
    XCTAssertEqual(captured.query, "code=new&state=new-state")
    XCTAssertTrue(stale.records.responses.first?.contains("400 Bad Request") == true)
    XCTAssertTrue(current.records.responses.first?.contains("200 OK") == true)
    try await stopAndDrain(listener, transport: transport, peers: [stale, current])
  }

  func testEmptyExpectedStateFailsBeforeConstructingTransport() async throws {
    let transport = LoopbackFakeListener()
    let clock = LoopbackFakeScheduler()
    let listener = CodexLoopbackListener(expectedState: "",
      makeTransport: { _ in transport.factoryResult() }, scheduler: clock)
    do { try await listener.start(); XCTFail("missing trusted state must fail closed") }
    catch { XCTAssertEqual(error as? BexError, .oauthFailure("OpenAI Codex callback state is unavailable.")) }
    XCTAssertEqual(transport.factoryCalls, 0)
    XCTAssertEqual(transport.startCalls, 0)
    XCTAssertTrue(clock.deadlines.isEmpty)
    await assertCancelled { _ = try await listener.waitForCallback() }
    await listener.stop()
  }

  func testEOFAndErrorNeverPromotePartialHeadersToCallback() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let eof = LoopbackFakeConnection()
    let error = LoopbackFakeConnection()
    _ = await transport.offer(eof)
    _ = await transport.offer(error)
    let partial = Data("GET /auth/callback?code=x HTTP/1.1\r\nHost: localhost:1455\r\n".utf8)
    await eof.completeReceive(partial, complete: true)
    await error.completeReceive(Data(request.utf8), failed: true)
    XCTAssertTrue(eof.records.responses.first?.contains("400 Bad Request") == true)
    XCTAssertTrue(error.records.responses.isEmpty)
    let state = await listener.snapshot()
    XCTAssertFalse(state.admissionClosed)
    try await stopAndDrain(listener, transport: transport, peers: [eof, error])
  }

  func testOversizedDeliveryReturns431AndDoesNotRetainBytesOrReceiveAgain() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    await peer.completeReceive(Data(repeating: 65, count: 4_097))
    let state = await listener.snapshot()
    XCTAssertEqual(state.retainedHeaderBytes, 0)
    XCTAssertEqual(peer.records.receiveCalls, 1)
    XCTAssertTrue(peer.records.responses.first?.contains("431 Request Header Fields Too Large") == true)
    try await stopAndDrain(listener, transport: transport, peers: [peer])
  }

  func testHeaderAndResponseDeadlinesRequestCancelButDoNotPretendToDrain() async throws {
    let (listener, transport, clock) = makeListener()
    try await listener.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    await clock.deadlines[1].fire()
    var state = await listener.snapshot()
    XCTAssertEqual(peer.records.cancelCalls, 1)
    XCTAssertEqual(state.connections, 1)
    XCTAssertEqual(transport.credits, 3)
    await peer.emitCancelled()
    state = await listener.snapshot()
    XCTAssertEqual(state.connections, 1)
    await peer.completeReceive(nil, failed: true)
    XCTAssertEqual(transport.credits, 3, "credits are replenished only after a complete delivery batch")

    let slowSend = LoopbackFakeConnection()
    _ = await transport.offer(slowSend)
    await slowSend.completeReceive(Data("GET /missing HTTP/1.1\r\nHost: localhost:1455\r\n\r\n".utf8))
    await clock.deadlines.last!.fire()
    await slowSend.emitCancelled()
    state = await listener.snapshot()
    XCTAssertEqual(state.connections, 1)
    await slowSend.completeSend()
    state = await listener.snapshot()
    XCTAssertEqual(state.connections, 0)
    try await stopAndDrain(listener, transport: transport, peers: [])
  }

  func testStaleDeadlinesCannotCancelNewResponseOrCapturedCallback() async throws {
    let (listener, transport, clock) = makeListener()
    try await listener.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    let attemptDeadline = clock.deadlines[0]
    let headerDeadline = clock.deadlines[1]
    await peer.completeReceive(Data(request.utf8))
    await attemptDeadline.fire(evenIfCancelled: true)
    await headerDeadline.fire(evenIfCancelled: true)
    XCTAssertEqual(peer.records.cancelCalls, 0, "old timer callbacks are token-guarded")
    let captured = try await listener.waitForCallback()
    XCTAssertEqual(captured.path, "/auth/callback")
    try await stopAndDrain(listener, transport: transport, peers: [peer])
  }

  func testAttemptDeadlineExistsWithoutWaiterAndLateReadyCannotReviveListener() async throws {
    let transport = LoopbackFakeListener(automaticallyReady: false)
    let clock = LoopbackFakeScheduler()
    let listener = CodexLoopbackListener(expectedState: "state", makeTransport: { _ in transport.factoryResult() }, scheduler: clock)
    let start = Task { try await listener.start() }
    try await waitUntil { !clock.deadlines.isEmpty }
    await clock.deadlines[0].fire()
    do { try await start.value; XCTFail("startup must time out") }
    catch { XCTAssertEqual(error as? BexError, .timeout) }
    await transport.emit(.ready)
    let state = await listener.snapshot()
    XCTAssertTrue(state.admissionClosed)
    try await stopAndDrain(listener, transport: transport, peers: [])
    await assertCancelled { try await listener.start() }
  }

  func testDuplicateWaitAndCancelledWaitKeepSingleTerminalOwner() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let first = Task { try await listener.waitForCallback() }
    // A queue barrier alone does not order a separately scheduled Task.
    try await waitUntil { await listener.snapshot().callbackWaiting }
    do { _ = try await listener.waitForCallback(); XCTFail("duplicate waiter") }
    catch { XCTAssertEqual(error as? BexError, .oauthFailure("OpenAI Codex callback already has a waiter.")) }
    first.cancel()
    do { _ = try await first.value; XCTFail("cancelled wait") }
    catch { XCTAssertEqual(error as? BexError, .cancellation) }
    try await stopAndDrain(listener, transport: transport, peers: [])
  }

  func testStopBeforeStartNeverConstructsTransportAndRepeatedStopIsImmediate() async throws {
    let transport = LoopbackFakeListener()
    let clock = LoopbackFakeScheduler()
    let listener = CodexLoopbackListener(expectedState: "state", makeTransport: { _ in transport.factoryResult() }, scheduler: clock)
    await listener.stop()
    await listener.stop()
    await assertCancelled { try await listener.start() }
    XCTAssertEqual(transport.startCalls, 0)
    XCTAssertEqual(transport.factoryCalls, 0)
    XCTAssertTrue(clock.deadlines.isEmpty)
  }

  func testPrecancelledStartNeverConstructsTransport() async throws {
    let transport = LoopbackFakeListener()
    let listener = CodexLoopbackListener(expectedState: "state", makeTransport: { _ in transport.factoryResult() }, scheduler: LoopbackFakeScheduler())
    let gate = LoopbackTestSignal()
    let start = Task {
      await gate.wait()
      try await listener.start()
    }
    start.cancel()
    await gate.signal()
    do { try await start.value; XCTFail("pre-cancelled start") }
    catch { XCTAssertEqual(error as? BexError, .cancellation) }
    await listener.stop()
    XCTAssertEqual(transport.startCalls, 0)
    XCTAssertEqual(transport.factoryCalls, 0)
  }

  func testCancelledStartCannotBeRevivedByLateReadyAndStillNeedsTerminalAck() async throws {
    let transport = LoopbackFakeListener(automaticallyReady: false)
    let clock = LoopbackFakeScheduler()
    let listener = CodexLoopbackListener(expectedState: "state", makeTransport: { _ in transport.factoryResult() }, scheduler: clock)
    let start = Task { try await listener.start() }
    try await waitUntil { transport.startCalls == 1 }
    start.cancel()
    do { try await start.value; XCTFail("cancelled start") }
    catch { XCTAssertEqual(error as? BexError, .cancellation) }
    await transport.emit(.ready)
    let stop = Task { await listener.stop() }
    try await waitForStopWaiters(1, listener)
    let state = await listener.snapshot()
    XCTAssertTrue(state.listenerPending)
    await transport.emit(.cancelled)
    await stop.value
  }

  func testListenerFailureCancelsConnectionsWithoutReleasingTheirCallbacksEarly() async throws {
    let (listener, transport, _) = makeListener()
    try await listener.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    let callback = Task { try await listener.waitForCallback() }
    try await waitUntil { await listener.snapshot().callbackWaiting }
    await transport.emit(.failed)
    do { _ = try await callback.value; XCTFail("listener failure") }
    catch { XCTAssertEqual(error as? BexError,
      .connectionFailure("OpenAI Codex callback port 1455 is unavailable.")) }
    let state = await listener.snapshot()
    XCTAssertEqual(state.connections, 1)
    XCTAssertEqual(state.stoppingConnections, 1)
    try await stopAndDrain(listener, transport: transport, peers: [peer])
  }

  func testReleasingOwnerRequestsCleanupWithoutRetainCycleOrDrainClaim() async throws {
    let transport = LoopbackFakeListener()
    let clock = LoopbackFakeScheduler()
    var listener: CodexLoopbackListener? = CodexLoopbackListener(
      expectedState: "state", makeTransport: { _ in transport.factoryResult() }, scheduler: clock)
    weak var weakOwner = listener
    try await listener!.start()
    let peer = LoopbackFakeConnection()
    _ = await transport.offer(peer)
    let queued = LoopbackFakeConnection()
    let reservation = await transport.reserve(queued)
    let pending = try XCTUnwrap(reservation)
    listener = nil
    // The last queue callback can still be returning after its continuation resumes.
    try await waitUntil { weakOwner == nil }
    XCTAssertNil(weakOwner)
    XCTAssertEqual(peer.records.cancelCalls, 1)
    XCTAssertEqual(transport.cancelCalls, 1)
    await transport.deliverReserved(pending)
    XCTAssertEqual(queued.records.cancelCalls, 1, "weak-owner fallback rejects the delivered connection")
    XCTAssertEqual(queued.records.startCalls, 0)
    await peer.emitCancelled()
    await peer.completeReceive(Data(request.utf8))
    XCTAssertTrue(peer.records.responses.isEmpty)
  }

  private func callbackRequest(_ query: String) -> Data {
    Data("GET /auth/callback?\(query) HTTP/1.1\r\nHost: localhost:1455\r\n\r\n".utf8)
  }

  private var request: String {
    "GET /auth/callback?code=test&state=state HTTP/1.1\r\nHost: localhost:1455\r\n\r\n"
  }

  private func feed(_ data: Data, into parser: inout CodexLoopbackHeaders) -> CodexLoopbackHeaders.Progress {
    var result = CodexLoopbackHeaders.Progress.incomplete
    for offset in stride(from: 0, to: data.count, by: 1_024) {
      result = parser.append(data.subdata(in: offset..<min(data.count, offset + 1_024)))
      XCTAssertLessThanOrEqual(parser.count, CodexLoopbackListener.maximumHeaderBytes)
      if result != .incomplete { break }
    }
    return result
  }

  private func makeListener() -> (CodexLoopbackListener, LoopbackFakeListener, LoopbackFakeScheduler) {
    let transport = LoopbackFakeListener()
    let clock = LoopbackFakeScheduler()
    return (CodexLoopbackListener(expectedState: "state", makeTransport: { _ in transport.factoryResult() }, scheduler: clock), transport, clock)
  }

  private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<1_000 {
      if await predicate() { return }
      await Task.yield()
    }
    XCTFail("synthetic registration did not arrive")
    throw LoopbackTestFailure.registrationDidNotArrive
  }

  private func waitForStopWaiters(_ count: Int, _ listener: CodexLoopbackListener) async throws {
    try await waitUntil { await listener.snapshot().stopWaiters == count }
  }

  private func stopAndDrain(_ listener: CodexLoopbackListener, transport: LoopbackFakeListener,
    peers: [LoopbackFakeConnection]) async throws {
    let stop = Task { await listener.stop() }
    try await waitUntil {
      let state = await listener.snapshot()
      return state.admissionClosed && (state.stopWaiters > 0
        || (!state.listenerPending && state.connections == 0))
    }
    await transport.emit(.cancelled)
    for peer in peers {
      await peer.emitCancelled()
      await peer.completeReceive(nil, failed: true)
      await peer.completeSend()
    }
    await stop.value
    let state = await listener.snapshot()
    XCTAssertEqual(state.connections, 0)
    XCTAssertFalse(state.listenerPending)
  }

  private func assertCancelled(_ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("expected cancellation") }
    catch { XCTAssertEqual(error as? BexError, .cancellation) }
  }
}

private final class LoopbackFakeListener: CodexLoopbackListenerTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let automaticallyReady: Bool
  private var queue: DispatchQueue?
  private var stateHandler: (@Sendable (CodexLoopbackListenerState) -> Void)?
  private var connectionHandler: (@Sendable (any CodexLoopbackConnectionTransport) -> Void)?
  private var remaining = 0
  private var starts = 0
  private var constructions = 0
  private var cancellations = 0
  private var reserved: [UUID: LoopbackFakeConnection] = [:]
  init(automaticallyReady: Bool = true) { self.automaticallyReady = automaticallyReady }
  var newConnectionLimit: Int {
    get { lock.withLock { remaining } }
    set { lock.withLock { remaining = newValue } }
  }
  var credits: Int { newConnectionLimit }
  var startCalls: Int { lock.withLock { starts } }
  var factoryCalls: Int { lock.withLock { constructions } }
  func factoryResult() -> any CodexLoopbackListenerTransport {
    lock.withLock { constructions += 1 }
    return self
  }
  var cancelCalls: Int { lock.withLock { cancellations } }
  func start(queue: DispatchQueue, state: @escaping @Sendable (CodexLoopbackListenerState) -> Void,
    connection: @escaping @Sendable (any CodexLoopbackConnectionTransport) -> Void) {
    lock.withLock { self.queue = queue; stateHandler = state; connectionHandler = connection; starts += 1 }
    if automaticallyReady { queue.async { state(.ready) } }
  }
  func cancel() { lock.withLock { cancellations += 1 } } // Terminal acknowledgement is explicit.
  func reserve(_ connection: LoopbackFakeConnection) async -> UUID? {
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
  func offer(_ connection: LoopbackFakeConnection) async -> Bool {
    guard let id = await reserve(connection) else { return false }
    await deliverReserved(id)
    return true
  }
  func emit(_ state: CodexLoopbackListenerState) async {
    await onQueue { self.lock.withLock { self.stateHandler }?(state) }
  }
  private func onQueue<T: Sendable>(_ action: @escaping @Sendable () -> T) async -> T {
    let queue = lock.withLock { self.queue! }
    return await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: action()) }
    }
  }
}

private final class LoopbackFakeConnection: CodexLoopbackConnectionTransport, @unchecked Sendable {
  struct Records: Sendable {
    var startCalls = 0
    var receiveCalls = 0
    var maximumReceive = 0
    var cancelCalls = 0
    var responses: [String] = []
  }
  private let lock = NSLock()
  private var queue: DispatchQueue?
  private var stateHandler: (@Sendable (CodexLoopbackConnectionState) -> Void)?
  private var receiveHandler: (@Sendable (Data?, Bool, Bool) -> Void)?
  private var sendHandler: (@Sendable () -> Void)?
  private var history = Records()
  var records: Records { lock.withLock { history } }
  func start(queue: DispatchQueue, state: @escaping @Sendable (CodexLoopbackConnectionState) -> Void) {
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
  func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
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
  func completeSend() async {
    await onQueue {
      let handler = self.lock.withLock { let value = self.sendHandler; self.sendHandler = nil; return value }
      handler?()
    }
  }
  private func onQueue(_ action: @escaping @Sendable () -> Void) async {
    let queue = lock.withLock { self.queue! }
    await withCheckedContinuation { continuation in
      queue.async { action(); continuation.resume() }
    }
  }
}

private final class LoopbackFakeScheduler: CodexLoopbackScheduling, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [LoopbackFakeDeadline] = []
  var deadlines: [LoopbackFakeDeadline] { lock.withLock { stored } }
  func schedule(after nanoseconds: UInt64, queue: DispatchQueue,
    action: @escaping @Sendable () -> Void) -> any CodexLoopbackDeadline {
    let deadline = LoopbackFakeDeadline(delay: nanoseconds, queue: queue, action: action)
    lock.withLock { stored.append(deadline) }
    return deadline
  }
}
private final class LoopbackFakeDeadline: CodexLoopbackDeadline, @unchecked Sendable {
  private let lock = NSLock()
  private let queue: DispatchQueue
  private let action: @Sendable () -> Void
  private var cancelled = false
  let delay: UInt64
  var isCancelled: Bool { lock.withLock { cancelled } }
  init(delay: UInt64, queue: DispatchQueue, action: @escaping @Sendable () -> Void) {
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

private enum LoopbackTestFailure: Error { case registrationDidNotArrive }
private actor LoopbackTestSignal {
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
