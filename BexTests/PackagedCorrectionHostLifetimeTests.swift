import XCTest
@testable import Bex

/// Synthetic lifecycle tests of the exact owner used by PackagedCorrectionHost.
/// No WebKit, NSWindow, Keychain, preferences, provider or URLSession is constructed.
/// Source only in this cloud executor: Swift compilation/execution has NOT occurred.
@MainActor
final class PackagedCorrectionHostLifetimeTests: XCTestCase {
  @MainActor private final class Signal {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if ready { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
      ready = true
      let pending = waiters
      waiters.removeAll()
      pending.forEach { $0.resume() }
    }
  }

  @MainActor private final class State {
    var revocations = 0
    var drains = 0
    var wrote = false
    var waiterReturned = false
    var loaded = false
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("The synthetic lifecycle did not reach the expected state")
    throw CancellationError()
  }

  func testClosedHostRemainsRegisteredUntilCoordinatorAndTransportBothFinish() async throws {
    let barrier = AccountMutationCoordinator()
    let coordinatorStarted = Signal(), coordinatorReturned = Signal()
    let transportStarted = Signal(), transportReturned = Signal()
    let state = State()
    let lifetime = PackagedCorrectionHostLifetime(barrier: barrier, revoke: {
      state.revocations += 1
    }, drain: {
      coordinatorStarted.signal()
      await coordinatorReturned.wait() // deliberately ignores cancellation
      transportStarted.signal()
      await transportReturned.wait()
    })
    try lifetime.register(reservation: barrier.reserveAdmission())
    lifetime.close()
    XCTAssertTrue(lifetime.isClosed)
    XCTAssertEqual(state.revocations, 1) // synchronous, before close returns
    await coordinatorStarted.wait()
    XCTAssertEqual(barrier.registeredHostCount, 1)
    let mutation = Task { @MainActor in
      await barrier.withMutation { state.wrote = true }
    }
    try await waitUntil { barrier.isAdmissionClosed }
    XCTAssertFalse(state.wrote)
    XCTAssertThrowsError(try barrier.reserveAdmission())
    coordinatorReturned.signal()
    await transportStarted.wait()
    XCTAssertEqual(barrier.registeredHostCount, 1)
    XCTAssertFalse(state.wrote, "Coordinator return is not provider-session termination")
    transportReturned.signal()
    await mutation.value
    XCTAssertTrue(state.wrote)
    XCTAssertEqual(state.revocations, 1)
    XCTAssertEqual(barrier.registeredHostCount, 0)
    XCTAssertNoThrow(try barrier.reserveAdmission())
  }

  func testMutationRevokesBeforeAwaitingAStillRunningDrain() async throws {
    let barrier = AccountMutationCoordinator()
    let drainStarted = Signal(), drainReturned = Signal()
    let state = State()
    let lifetime = PackagedCorrectionHostLifetime(barrier: barrier, revoke: {
      state.revocations += 1
    }, drain: {
      XCTAssertEqual(state.revocations, 1)
      drainStarted.signal()
      await drainReturned.wait()
    })
    try lifetime.register(reservation: barrier.reserveAdmission())
    let mutation = Task { @MainActor in
      await barrier.withMutation { state.wrote = true }
    }
    await drainStarted.wait()
    XCTAssertEqual(state.revocations, 1)
    XCTAssertTrue(lifetime.isClosed)
    XCTAssertFalse(state.wrote)
    XCTAssertEqual(barrier.registeredHostCount, 1)
    drainReturned.signal()
    await mutation.value
    XCTAssertTrue(state.wrote)
  }

  func testCancelledCloseWaiterDoesNotCancelOrRemoveLifetime() async throws {
    let barrier = AccountMutationCoordinator()
    let drainStarted = Signal(), drainReturned = Signal()
    let state = State()
    let lifetime = PackagedCorrectionHostLifetime(barrier: barrier, revoke: {
      state.revocations += 1
    }, drain: {
      state.drains += 1
      drainStarted.signal()
      await drainReturned.wait()
      XCTAssertFalse(Task.isCancelled)
    })
    try lifetime.register(reservation: barrier.reserveAdmission())
    let waiter = Task { @MainActor in
      await lifetime.closeAndWait()
      state.waiterReturned = true
    }
    await drainStarted.wait()
    waiter.cancel()
    lifetime.close()
    XCTAssertFalse(state.waiterReturned)
    XCTAssertEqual(barrier.registeredHostCount, 1)
    drainReturned.signal()
    await waiter.value
    await lifetime.closeAndWait()
    XCTAssertTrue(state.waiterReturned)
    XCTAssertEqual(state.revocations, 1)
    XCTAssertEqual(state.drains, 1)
    XCTAssertEqual(barrier.registeredHostCount, 0)
  }

  func testStaleConstructionCannotRegisterOrLoadAfterMutation() async throws {
    let barrier = AccountMutationCoordinator()
    let reservation = try barrier.reserveAdmission()
    // Represents settings snapshot then suspended WebKit construction. The actual
    // make method's ordering is separately source-checked, not executed by this test.
    await barrier.withMutation { }
    let state = State()
    let lifetime = PackagedCorrectionHostLifetime(barrier: barrier, revoke: { },
      drain: { state.drains += 1 })
    do {
      try lifetime.register(reservation: reservation)
      state.loaded = true
      XCTFail("A stale construction was admitted")
    } catch {
      await lifetime.closeAndWait()
    }
    XCTAssertFalse(state.loaded)
    XCTAssertEqual(state.drains, 1)
    XCTAssertEqual(barrier.registeredHostCount, 0)
  }

  func testAlreadyClosedCandidateCannotRegisterWithFreshReservation() async throws {
    let barrier = AccountMutationCoordinator()
    let state = State()
    let lifetime = PackagedCorrectionHostLifetime(barrier: barrier, revoke: { },
      drain: { state.drains += 1 })
    lifetime.close()
    XCTAssertThrowsError(try lifetime.register(reservation: barrier.reserveAdmission()))
    await lifetime.closeAndWait()
    XCTAssertEqual(state.drains, 1)
    XCTAssertEqual(barrier.registeredHostCount, 0)
  }

  func testDuplicateRegistrationCannotLeaveAnUndrainedSecondEntry() async throws {
    let barrier = AccountMutationCoordinator()
    let lifetime = PackagedCorrectionHostLifetime(barrier: barrier, revoke: { }, drain: { })
    try lifetime.register(reservation: barrier.reserveAdmission())
    XCTAssertThrowsError(try lifetime.register(reservation: barrier.reserveAdmission()))
    XCTAssertEqual(barrier.registeredHostCount, 1)
    await lifetime.closeAndWait()
    XCTAssertEqual(barrier.registeredHostCount, 0)
  }

  func testRegistrationRetainsLifetimeAfterViewOwnerDropsIt() async throws {
    let barrier = AccountMutationCoordinator()
    let drainStarted = Signal(), drainReturned = Signal()
    var lifetime: PackagedCorrectionHostLifetime? = PackagedCorrectionHostLifetime(
      barrier: barrier, revoke: { }, drain: {
        drainStarted.signal()
        await drainReturned.wait()
      })
    weak var retained = lifetime
    try lifetime?.register(reservation: barrier.reserveAdmission())
    lifetime = nil
    XCTAssertNotNil(retained)
    let mutation = Task { @MainActor in await barrier.withMutation { } }
    await drainStarted.wait()
    XCTAssertNotNil(retained)
    XCTAssertEqual(barrier.registeredHostCount, 1)
    drainReturned.signal()
    await mutation.value
    try await waitUntil { retained == nil }
  }
}
