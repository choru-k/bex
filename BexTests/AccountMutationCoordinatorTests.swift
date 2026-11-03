import Foundation
import XCTest
@testable import Bex

/// Explicit handshakes control drain/commit ordering. No network, Security calls,
/// WebKit, wall-clock sleeps, or timeout-as-quiescence shortcuts are used.
@MainActor
private final class AccountBarrierLatch {
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
    for waiter in pending { waiter.resume() }
  }
}

@MainActor
private final class AccountBarrierLog {
  var events: [String] = []
}

@MainActor
final class AccountMutationCoordinatorTests: XCTestCase {
  private enum Failure: Error { case synthetic }

  func testReservationCannotSurviveMutationOrCrossCoordinator() async throws {
    let gate = AccountMutationCoordinator()
    let other = AccountMutationCoordinator()
    let reservation = try gate.reserveAdmission()
    XCTAssertThrowsError(try other.validateAdmission(reservation))
    await gate.withMutation { }
    XCTAssertThrowsError(try gate.validateAdmission(reservation))
    let current = try gate.reserveAdmission()
    XCTAssertNoThrow(try gate.validateAdmission(current))
  }

  func testRevokesEveryHostBeforeDrainAndWaitsForWholeLifetimes() async throws {
    let gate = AccountMutationCoordinator()
    let drainStarted = AccountBarrierLatch()
    let release = AccountBarrierLatch()
    let log = AccountBarrierLog()
    let reservation = try gate.reserveAdmission()
    for index in 0..<2 {
      _ = try gate.registerHost(reservation: reservation, revoke: {
        log.events.append("revoke-\(index)")
      }, drain: {
        XCTAssertEqual(log.events.filter { $0.hasPrefix("revoke-") }.count, 2)
        drainStarted.signal()
        await release.wait() // deliberately ignores cancellation
        log.events.append("drain-\(index)")
      })
    }
    let mutation = Task { await gate.withMutation { log.events.append("write") } }
    await drainStarted.wait()
    XCTAssertTrue(gate.isAdmissionClosed)
    XCTAssertEqual(gate.registeredHostCount, 2)
    XCTAssertFalse(log.events.contains("write"))
    XCTAssertThrowsError(try gate.reserveAdmission())
    XCTAssertThrowsError(try gate.registerHost(reservation: reservation,
      revoke: {}, drain: {}))
    mutation.cancel()
    XCTAssertFalse(log.events.contains("write"))
    release.signal()
    await mutation.value
    XCTAssertEqual(log.events.last, "write")
    XCTAssertEqual(log.events.filter { $0.hasPrefix("drain-") }.count, 2)
    XCTAssertEqual(gate.registeredHostCount, 0)
    XCTAssertFalse(gate.isAdmissionClosed)
  }

  func testFIFOStaysClosedBetweenFailedCancelledAndSuccessfulWrites() async throws {
    let gate = AccountMutationCoordinator()
    let started = AccountBarrierLatch()
    let release = AccountBarrierLatch()
    let log = AccountBarrierLog()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      started.signal()
      await release.wait()
    })
    let failed = Task {
      try await gate.withThrowingMutation {
        XCTAssertThrowsError(try gate.reserveAdmission())
        log.events.append("failed")
        throw Failure.synthetic
      }
    }
    await started.wait()
    let cancelled = Task {
      try await gate.withThrowingMutation { log.events.append("cancelled-write") }
    }
    try await waitForQueue(gate, count: 2)
    cancelled.cancel()
    let succeeded = Task {
      await gate.withMutation {
        XCTAssertThrowsError(try gate.reserveAdmission())
        log.events.append("success")
      }
    }
    try await waitForQueue(gate, count: 3)
    release.signal()
    do { try await failed.value; XCTFail("Expected storage failure") }
    catch Failure.synthetic { }
    do { try await cancelled.value; XCTFail("Expected cancellation") }
    catch is CancellationError { }
    await succeeded.value
    XCTAssertEqual(log.events, ["failed", "success"])
    XCTAssertFalse(gate.isAdmissionClosed)
    XCTAssertNoThrow(try gate.reserveAdmission())
  }

  func testLoginIntentAndFailedCommitInvalidateOlderTokens() async throws {
    let gate = AccountMutationCoordinator()
    let domain = "synthetic"
    let old = gate.beginCredentialOperation(domain: domain)
    let current = gate.beginCredentialOperation(domain: domain)
    let oldSaved = try await gate.commitCredential(domain: domain, token: old) {
      XCTFail("Stale login wrote")
    }
    XCTAssertFalse(oldSaved)
    XCTAssertFalse(gate.cancelCredentialOperation(old, domain: domain))
    do {
      _ = try await gate.commitCredential(domain: domain, token: current) {
        throw Failure.synthetic
      }
      XCTFail("Expected synthetic failure")
    } catch Failure.synthetic { }
    let reused = try await gate.commitCredential(domain: domain, token: current) {
      XCTFail("Failed operation token was revived")
    }
    XCTAssertFalse(reused)
    XCTAssertFalse(gate.isAdmissionClosed)
  }

  func testRefreshComparesVersionAndInvalidationIsCheckedAfterDrain() async throws {
    let gate = AccountMutationCoordinator()
    let domain = "synthetic"
    let first = try XCTUnwrap(gate.credentialSnapshot(domain: domain) { "old" })
    let sameVersion = try XCTUnwrap(gate.credentialSnapshot(domain: domain) { "old" })
    let firstSaved = try await gate.commitCredential(domain: domain, token: first.token) { }
    XCTAssertTrue(firstSaved)
    let duplicate = try await gate.commitCredential(domain: domain, token: sameVersion.token) {
      XCTFail("Duplicate refresh wrote")
    }
    XCTAssertFalse(duplicate)

    let snapshot = try XCTUnwrap(gate.credentialSnapshot(domain: domain) { "fresh" })
    let started = AccountBarrierLatch()
    let release = AccountBarrierLatch()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      started.signal()
      await release.wait()
    })
    let pending = Task {
      try await gate.commitCredential(domain: domain, token: snapshot.token) {
        XCTFail("Refresh became stale while draining")
      }
    }
    await started.wait()
    _ = gate.beginCredentialOperation(domain: domain)
    release.signal()
    let committed = try await pending.value
    XCTAssertFalse(committed)
  }

  func testFailedReplacementIntentInvalidatesWithoutWriting() async throws {
    let gate = AccountMutationCoordinator()
    let domain = "synthetic"
    let login = gate.beginCredentialOperation(domain: domain)
    do {
      try await gate.replaceCredential(domain: domain) { throw Failure.synthetic }
      XCTFail("Expected synthetic failure")
    } catch Failure.synthetic { }
    let stale = try await gate.commitCredential(domain: domain, token: login) {
      XCTFail("Failed replacement revived prior login")
    }
    XCTAssertFalse(stale)
    XCTAssertNoThrow(try gate.reserveAdmission())
  }

  func testPartialFailedCommitKeepsSideEffectConsumesTokenAndReleasesNextWriter() async throws {
    let gate = AccountMutationCoordinator()
    let domain = "synthetic"
    let token = gate.beginCredentialOperation(domain: domain)
    let started = AccountBarrierLatch()
    let release = AccountBarrierLatch()
    let log = AccountBarrierLog()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      started.signal()
      await release.wait()
    })
    let partial = Task {
      try await gate.commitCredential(domain: domain, token: token) {
        log.events.append("partial-side-effect")
        throw Failure.synthetic
      }
    }
    await started.wait()
    let next = Task {
      await gate.withMutation {
        XCTAssertTrue(gate.isAdmissionClosed)
        XCTAssertEqual(log.events, ["partial-side-effect"])
        log.events.append("next-write")
      }
    }
    try await waitForQueue(gate, count: 2)
    release.signal()
    do { _ = try await partial.value; XCTFail("Expected partial failure") }
    catch Failure.synthetic { }
    await next.value
    XCTAssertEqual(log.events, ["partial-side-effect", "next-write"])
    let replay = try await gate.commitCredential(domain: domain, token: token) {
      XCTFail("Partially failed token was reused")
    }
    XCTAssertFalse(replay)
    XCTAssertFalse(gate.isAdmissionClosed)
  }

  func testCancelledReplacementInvalidatesOldTokenButNotNewIntentDuringDrain() async throws {
    let gate = AccountMutationCoordinator()
    let domain = "synthetic"
    let old = gate.beginCredentialOperation(domain: domain)
    let started = AccountBarrierLatch()
    let release = AccountBarrierLatch()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      started.signal()
      await release.wait()
    })
    let replacement = Task {
      try await gate.replaceCredential(domain: domain) {
        XCTFail("Cancelled replacement wrote")
      }
    }
    await started.wait()
    let newer = gate.beginCredentialOperation(domain: domain)
    replacement.cancel()
    XCTAssertTrue(gate.isAdmissionClosed)
    release.signal()
    do { try await replacement.value; XCTFail("Expected cancellation") }
    catch is CancellationError { }
    let oldSaved = try await gate.commitCredential(domain: domain, token: old) {
      XCTFail("Cancellation revived older network operation")
    }
    XCTAssertFalse(oldSaved)
    // No replacement commit occurred, so an explicitly newer login intent is
    // still current. This is intentionally different from a failed store commit.
    let newerSaved = try await gate.commitCredential(domain: domain, token: newer) { }
    XCTAssertTrue(newerSaved)
  }

  /// Scheduler-yield polling is only a bounded enqueue observation, never a
  /// substitute for host termination. All drain boundaries use explicit latches.
  private func waitForQueue(_ gate: AccountMutationCoordinator, count: Int) async throws {
    for _ in 0..<10_000 {
      if gate.queuedMutationCount == count { return }
      await Task.yield()
    }
    XCTFail("Mutation did not enqueue")
    throw Failure.synthetic
  }
}
