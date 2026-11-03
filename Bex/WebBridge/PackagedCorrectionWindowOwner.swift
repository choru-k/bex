import Foundation

/// Implemented by the native window session below and continuation-controlled tests.
/// A close request must revoke synchronously. Its drain must await all owned work.
@MainActor
protocol PackagedCorrectionWindowSession: AnyObject, Sendable {
  var isClosed: Bool { get }
  func prepare() async throws
  func present()
  func close()
  func closeAndWait() async
}

/// One app-owned, normally compiled lifetime controller. Construction is inert.
/// There is no production call to requestOpen: the only composition hook is #if false.
/// This is lifecycle wiring, not evidence of native resource or network isolation.
@MainActor
final class PackagedCorrectionWindowOwner {
  enum Phase: Equatable { case idle, opening, open, closing, stopped }
  typealias SessionFactory = @MainActor (@escaping @MainActor @Sendable () -> Void)
    -> any PackagedCorrectionWindowSession

  private struct Current: Sendable {
    let id: UUID
    let session: any PackagedCorrectionWindowSession
    var prepared = false
  }

  private let makeSession: SessionFactory
  private var current: Current?
  private var desiredOpen: UUID?
  private var preparation: Task<Void, Error>?
  private var worker: Task<Void, Never>?
  private var stopped = false
  private(set) var phase: Phase = .idle
  private(set) var lastOpenFailed = false
  var hasOutstandingWork: Bool { current != nil || worker != nil }

  /// Test seam uses the very same owner, not a parallel lifecycle model.
  /// The factory is retained, never invoked by initialization.
  init(makeSession: @escaping SessionFactory) { self.makeSession = makeSession }

  /// Repeated opens focus one admitted session or coalesce into one pending reopen.
  /// A revoked/closed session is never reused, even if its window still exists.
  func requestOpen() {
    guard !stopped else { return }
    if let desiredOpen {
      if let current, current.id == desiredOpen {
        if !current.session.isClosed {
          if current.prepared { current.session.present() }
          return
        }
      } else {
        return // The newest explicit open is already waiting for the old drain.
      }
    }
    desiredOpen = UUID()
    lastOpenFailed = false
    preparation?.cancel()
    current?.session.close()
    startWorkerIfNeeded()
  }

  /// Cancels a pending open as well as a visible session, synchronously revoking it.
  /// Reopening later is permitted but cannot overtake this session's full drain.
  func close() {
    desiredOpen = nil
    preparation?.cancel()
    current?.session.close()
    if current != nil { startWorkerIfNeeded() }
  }

  /// Joins owner work; caller cancellation never cancels the owned cleanup task.
  /// A newer explicit open may be serviced after the closed session has drained.
  func closeAndWait() async {
    close()
    await worker?.value
  }

  /// Stops admission immediately, before the application begins waiting to quit.
  /// No timeout, cancelled waiter or late open can replace completed termination.
  func shutdown() {
    stopped = true
    close()
    if !hasOutstandingWork { phase = .stopped }
  }

  func shutdownAndWait() async {
    shutdown()
    await worker?.value
  }

  private func sessionDidClose(id: UUID) {
    // A stale close callback from the old window cannot cancel a newer reopen.
    guard current?.id == id, desiredOpen == id else { return }
    close()
  }

  private func startWorkerIfNeeded() {
    guard worker == nil else { return }
    // This task owns the complete serialized transition. Only the prepare child
    // receives cancellation; draining is never replaced by a cancellation request.
    worker = Task { @MainActor [self] in
      await reconcile()
    }
  }

  private func reconcile() async {
    // Clear ownership before this async function returns, not after awaiting it:
    // an intervening close/open must never mistake a finished worker for a live one.
    defer { worker = nil }
    while true {
      if let active = current {
        if desiredOpen == active.id, !active.session.isClosed, !stopped {
          phase = .opening
          let prepare = Task { @MainActor in try await active.session.prepare() }
          preparation = prepare
          let result = await prepare.result
          preparation = nil
          if case .success = result, desiredOpen == active.id,
             !active.session.isClosed, !stopped {
            current?.prepared = true
            phase = .open
            active.session.present()
            // Presentation can synchronously deliver window-close callbacks.
            if desiredOpen == active.id, !active.session.isClosed, !stopped { return }
            continue
          }
          // Construction failure or account revocation does not automatically retry.
          // A newer explicit open is preserved, but must still wait for this drain.
          if desiredOpen == active.id {
            desiredOpen = nil
            if case .failure(let error) = result {
              lastOpenFailed = !(error is CancellationError)
            }
          }
        }
        if desiredOpen == active.id { desiredOpen = nil }
        phase = .closing
        active.session.close()
        await active.session.closeAndWait()
        current = nil
      }
      guard let id = desiredOpen, !stopped else {
        phase = stopped ? .stopped : .idle
        return
      }
      let session = makeSession { [weak self] in self?.sessionDidClose(id: id) }
      current = Current(id: id, session: session)
      // The next loop is the sole place preparation starts. No replacement session
      // is constructed until the prior full closeAndWait has actually returned.
    }
  }

  deinit {
    // Idle open sessions still need cleanup if their app owner is released. Active
    // construction/drain keeps this owner alive in its worker until that finishes.
    if let session = current?.session {
      Task { @MainActor in
        session.close()
        await session.closeAndWait()
      }
    }
  }
}
