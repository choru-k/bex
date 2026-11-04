import XCTest
@testable import Bex

/// Synthetic tests of the actual app-owned controller. No AppKit window, WebKit,
/// provider, credential store, settings read, socket or production app is invoked.
/// Authored only: this cloud executor has not compiled or executed these tests.
@MainActor
final class PackagedCorrectionWindowOwnerTests: XCTestCase {
  @MainActor private final class Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if released { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      released = true
      let pending = waiters
      waiters.removeAll()
      pending.forEach { $0.resume() }
    }
  }

  private enum SyntheticFailure: Error { case construction }

  @MainActor private final class Session: PackagedCorrectionWindowSession {
    let prepareGate: Gate?
    let drainGate: Gate?
    let barrier: AccountMutationCoordinator?
    var didClose: (@MainActor @Sendable () -> Void)?
    var onPresent: (@MainActor () -> Void)?
    var failsPreparation = false
    var closed = false
    var prepares = 0
    var presentations = 0
    var revocations = 0
    var drains = 0
    var preparationWasCancelled = false
    var drainWasCancelled = false
    var drainFinished = false
    var lifetime: PackagedCorrectionHostLifetime?
    var isClosed: Bool { closed || lifetime?.isClosed == true }

    init(prepareGate: Gate? = nil, drainGate: Gate? = nil,
         barrier: AccountMutationCoordinator? = nil) {
      self.prepareGate = prepareGate
      self.drainGate = drainGate
      self.barrier = barrier
    }
    func prepare() async throws {
      prepares += 1
      await prepareGate?.wait() // Deliberately non-cooperative construction.
      preparationWasCancelled = Task.isCancelled
      if failsPreparation { throw SyntheticFailure.construction }
      if let barrier {
        let lifetime = PackagedCorrectionHostLifetime(barrier: barrier,
          revoke: { [weak self] in self?.revocations += 1 },
          drain: { [drainGate] in await drainGate?.wait() })
        try lifetime.register(reservation: barrier.reserveAdmission())
        self.lifetime = lifetime
      }
    }
    func present() {
      guard !isClosed else { return }
      presentations += 1
      onPresent?()
    }
    func close() {
      guard !closed else { return }
      closed = true
      lifetime?.close()
      didClose?()
    }
    func closeAndWait() async {
      close()
      drains += 1
      await lifetime?.closeAndWait()
      await drainGate?.wait() // Deliberately ignores cancellation.
      drainWasCancelled = Task.isCancelled
      drainFinished = true
    }
  }

  @MainActor private final class Harness {
    var sessions: [Session] = []
    var configure: @MainActor (Int) -> Session = { _ in Session() }
    func owner() -> PackagedCorrectionWindowOwner {
      PackagedCorrectionWindowOwner { [self] onClose in
        let session = configure(sessions.count)
        session.didClose = onClose
        sessions.append(session)
        return session
      }
    }
  }

  @MainActor private final class Flag { var value = false }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("The synthetic owner did not reach the expected state")
    throw CancellationError()
  }

  func testCompositionAndDormantShutdownHaveNoFactoryOrTaskWork() async {
    let harness = Harness(), owner = harness.owner()
    XCTAssertEqual(owner.phase, .idle)
    XCTAssertFalse(owner.hasOutstandingWork)
    XCTAssertTrue(harness.sessions.isEmpty)
    owner.shutdown()
    XCTAssertEqual(owner.phase, .stopped)
    XCTAssertFalse(owner.hasOutstandingWork)
    owner.requestOpen()
    await owner.shutdownAndWait()
    XCTAssertTrue(harness.sessions.isEmpty)
  }

  func testRepeatedOpenCoalescesConstructionThenFocusesOneWindow() async throws {
    let gate = Gate(), harness = Harness()
    harness.configure = { _ in Session(prepareGate: gate) }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { harness.sessions.first?.prepares == 1 }
    for _ in 0..<20 { owner.requestOpen() }
    XCTAssertEqual(harness.sessions.count, 1)
    XCTAssertEqual(harness.sessions[0].presentations, 0)
    gate.release()
    try await waitUntil { owner.phase == .open }
    owner.requestOpen()
    XCTAssertEqual(harness.sessions.count, 1)
    XCTAssertEqual(harness.sessions[0].prepares, 1)
    XCTAssertEqual(harness.sessions[0].presentations, 2)
    await owner.shutdownAndWait()
  }

  func testCloseReopenWaitsForConstructionAndFullDrainBeforeReplacement() async throws {
    let prepare = Gate(), drain = Gate(), harness = Harness()
    harness.configure = { index in index == 0
      ? Session(prepareGate: prepare, drainGate: drain) : Session() }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { harness.sessions.first?.prepares == 1 }
    let first = harness.sessions[0]
    owner.close()
    owner.requestOpen()
    owner.requestOpen()
    XCTAssertTrue(first.closed)
    XCTAssertEqual(harness.sessions.count, 1)
    prepare.release()
    try await waitUntil { first.drains == 1 }
    XCTAssertTrue(first.preparationWasCancelled)
    XCTAssertEqual(first.presentations, 0)
    XCTAssertEqual(harness.sessions.count, 1)
    first.didClose?() // A stale close must not discard the pending explicit open.
    drain.release()
    try await waitUntil { owner.phase == .open && harness.sessions.count == 2 }
    XCTAssertFalse(first.drainWasCancelled)
    first.didClose?() // Nor may it close the replacement after it has opened.
    XCTAssertFalse(harness.sessions[1].closed)
    XCTAssertEqual(harness.sessions[1].presentations, 1)
    await owner.shutdownAndWait()
  }

  func testCloseCancelsPendingReopenDuringDrain() async throws {
    let drain = Gate(), harness = Harness()
    harness.configure = { _ in Session(drainGate: drain) }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { owner.phase == .open }
    owner.close()
    owner.requestOpen()
    try await waitUntil { harness.sessions[0].drains == 1 }
    owner.close()
    drain.release()
    try await waitUntil { !owner.hasOutstandingWork }
    XCTAssertEqual(owner.phase, .idle)
    XCTAssertEqual(harness.sessions.count, 1)
  }

  func testShutdownDuringConstructionNeverPresentsOrReadmits() async throws {
    let prepare = Gate(), drain = Gate(), harness = Harness()
    harness.configure = { _ in Session(prepareGate: prepare, drainGate: drain) }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { harness.sessions.first?.prepares == 1 }
    owner.shutdown()
    XCTAssertTrue(harness.sessions[0].closed)
    owner.requestOpen()
    let returned = Flag()
    let waiter = Task { @MainActor in
      await owner.shutdownAndWait()
      returned.value = true
    }
    prepare.release()
    try await waitUntil { harness.sessions[0].drains == 1 }
    XCTAssertFalse(returned.value)
    XCTAssertEqual(harness.sessions[0].presentations, 0)
    owner.requestOpen()
    drain.release()
    await waiter.value
    XCTAssertTrue(returned.value)
    XCTAssertEqual(owner.phase, .stopped)
    XCTAssertFalse(owner.hasOutstandingWork)
    XCTAssertEqual(harness.sessions.count, 1)
  }

  func testCloseScheduledByPresentationCannotMissTheFinishingWorker() async throws {
    let harness = Harness(), drain = Gate()
    let owner = harness.owner()
    harness.configure = { _ in
      let session = Session(drainGate: drain)
      session.onPresent = { [weak owner] in
        Task { @MainActor [weak owner] in owner?.close() }
      }
      return session
    }
    owner.requestOpen()
    try await waitUntil { harness.sessions.first?.drains == 1 }
    XCTAssertEqual(harness.sessions[0].presentations, 1)
    drain.release()
    try await waitUntil { !owner.hasOutstandingWork }
    XCTAssertEqual(owner.phase, .idle)
  }

  func testShutdownBeforePreparationStartsCreatesNoSession() async {
    let harness = Harness(), owner = harness.owner()
    owner.requestOpen()
    owner.shutdown()
    await owner.shutdownAndWait()
    XCTAssertTrue(harness.sessions.isEmpty)
    XCTAssertFalse(owner.hasOutstandingWork)
    XCTAssertEqual(owner.phase, .stopped)
  }

  func testCancelledCloseWaiterCannotSkipOrCancelDrain() async throws {
    let drain = Gate(), harness = Harness()
    harness.configure = { _ in Session(drainGate: drain) }
    let owner = harness.owner(), returned = Flag()
    owner.requestOpen()
    try await waitUntil { owner.phase == .open }
    let waiter = Task { @MainActor in
      await owner.closeAndWait()
      returned.value = true
    }
    try await waitUntil { harness.sessions[0].drains == 1 }
    waiter.cancel()
    XCTAssertFalse(returned.value)
    XCTAssertTrue(owner.hasOutstandingWork)
    drain.release()
    await waiter.value
    XCTAssertTrue(returned.value)
    XCTAssertFalse(harness.sessions[0].drainWasCancelled)
    XCTAssertFalse(owner.hasOutstandingWork)
  }

  func testFailedConstructionDrainsWithoutAutomaticRetry() async throws {
    let drain = Gate(), harness = Harness()
    harness.configure = { _ in
      let session = Session(drainGate: drain)
      session.failsPreparation = true
      return session
    }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { harness.sessions.first?.drains == 1 }
    XCTAssertTrue(owner.lastOpenFailed)
    XCTAssertEqual(harness.sessions[0].presentations, 0)
    drain.release()
    try await waitUntil { !owner.hasOutstandingWork }
    XCTAssertEqual(owner.phase, .idle)
    XCTAssertEqual(harness.sessions.count, 1)
  }

  func testAccountRevocationRequiresExplicitOpenAndFreshEpoch() async throws {
    let barrier = AccountMutationCoordinator(), drain = Gate(), harness = Harness()
    harness.configure = { index in Session(drainGate: index == 0 ? drain : nil,
      barrier: barrier) }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { owner.phase == .open }
    let first = harness.sessions[0], wrote = Flag()
    let mutation = Task { @MainActor in
      await barrier.withMutation { wrote.value = true }
    }
    try await waitUntil { barrier.isAdmissionClosed }
    XCTAssertTrue(first.isClosed)
    XCTAssertEqual(first.revocations, 1)
    XCTAssertFalse(wrote.value)
    XCTAssertEqual(harness.sessions.count, 1)
    drain.release()
    await mutation.value
    XCTAssertTrue(wrote.value)
    XCTAssertEqual(barrier.registeredHostCount, 0)
    XCTAssertEqual(harness.sessions.count, 1, "Mutation must not automatically reopen a host")
    owner.requestOpen()
    try await waitUntil { owner.phase == .open && harness.sessions.count == 2 }
    XCTAssertEqual(first.drains, 1)
    XCTAssertEqual(barrier.registeredHostCount, 1)
    XCTAssertFalse(harness.sessions[1].isClosed)
    await owner.shutdownAndWait()
    XCTAssertEqual(barrier.registeredHostCount, 0)
  }

  func testAlreadyClosedSessionFailsClosedInsteadOfReconstructionLoop() async throws {
    let harness = Harness()
    harness.configure = { _ in
      let session = Session()
      session.closed = true
      return session
    }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { !owner.hasOutstandingWork }
    XCTAssertEqual(harness.sessions.count, 1)
    XCTAssertEqual(harness.sessions[0].prepares, 0)
    XCTAssertEqual(harness.sessions[0].drains, 1)
  }

  func testSynchronousCloseDuringPresentationStillDrains() async throws {
    let harness = Harness(), drain = Gate()
    harness.configure = { _ in
      let session = Session(drainGate: drain)
      session.onPresent = { [weak session] in session?.close() }
      return session
    }
    let owner = harness.owner()
    owner.requestOpen()
    try await waitUntil { harness.sessions.first?.drains == 1 }
    XCTAssertTrue(owner.hasOutstandingWork)
    drain.release()
    try await waitUntil { !owner.hasOutstandingWork }
    XCTAssertEqual(harness.sessions.count, 1)
    XCTAssertEqual(owner.phase, .idle)
  }

  func testDroppingIdleOpenOwnerStillClosesAndDrainsItsSession() async throws {
    let harness = Harness(), drain = Gate()
    harness.configure = { _ in Session(drainGate: drain) }
    var owner: PackagedCorrectionWindowOwner? = harness.owner()
    weak var weakOwner = owner
    owner?.requestOpen()
    try await waitUntil { owner?.phase == .open }
    // Let the construction worker finish and relinquish its transient strong owner.
    for _ in 0..<10 { await Task.yield() }
    owner = nil
    try await waitUntil { weakOwner == nil && harness.sessions[0].drains == 1 }
    XCTAssertTrue(harness.sessions[0].closed)
    drain.release()
    try await waitUntil { harness.sessions[0].drainFinished }
    XCTAssertFalse(harness.sessions[0].drainWasCancelled)
  }
}
