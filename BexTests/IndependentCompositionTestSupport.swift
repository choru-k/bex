import Foundation

@testable import Bex

/// Synthetic MainActor transport only. These tests do not exercise XPC, signing,
/// service installation, TCC, or any real focused application or pasteboard.
@MainActor
final class CompositionAXClient: AccessibilityAgentClientServing {
  var currentSession: UUID? = UUID()
  var failure: AccessibilityAgentFailure?
  var statusValue = true
  var pauseStatus = false
  var pauseCapture = false
  var pauseValidation = false
  var pauseConsumption = false

  private(set) var statusCount = 0
  private(set) var captureCount = 0
  private(set) var validationCount = 0
  private(set) var stopCount = 0
  private(set) var statusObservedCancellation = false
  private(set) var captures: [AccessibilityAgentCapturedResult] = []
  private(set) var validations: [(UUID, UUID)] = []
  private(set) var consumptions: [(UUID, UUID)] = []
  private(set) var discards: [(UUID, UUID)] = []
  var consumeCount: Int { consumptions.count }

  private var statusWaiters: [CheckedContinuation<Void, Never>] = []
  private var captureWaiters: [CheckedContinuation<Void, Never>] = []
  private var validationWaiters: [CheckedContinuation<Void, Never>] = []
  private var consumptionWaiters: [CheckedContinuation<Void, Never>] = []

  func status() async throws -> Bool {
    statusCount += 1
    if pauseStatus { await withCheckedContinuation { statusWaiters.append($0) } }
    // Deliberately remain suspended after cancellation until the test releases
    // the reply. Record transport ownership separately from observer cancellation.
    if Task.isCancelled {
      statusObservedCancellation = true
      currentSession = nil
      throw CancellationError()
    }
    if let failure { throw failure }
    guard currentSession != nil else { throw AccessibilityAgentFailure.cancelled }
    return statusValue
  }

  func capture() async throws -> AccessibilityAgentCapturedResult {
    captureCount += 1
    guard let session = currentSession else { throw AccessibilityAgentFailure.cancelled }
    let result = AccessibilityAgentCapturedResult(
      capture: AccessibilityAgentCapture(
        token: UUID(), processID: 33, bundleIdentifier: "test.destination",
        applicationName: "Synthetic Destination", launchDate: Date(timeIntervalSince1970: 5),
        original: "This are original."
      ),
      session: session
    )
    captures.append(result)
    if pauseCapture { await withCheckedContinuation { captureWaiters.append($0) } }
    if let failure { throw failure }
    // Return the original session even after cancellation or stop so the adapter
    // must reject and discard a late result rather than relying on fake transport.
    return result
  }

  func validate(_ token: UUID, session: UUID) async throws {
    validationCount += 1
    validations.append((token, session))
    if pauseValidation { await withCheckedContinuation { validationWaiters.append($0) } }
    if let failure { throw failure }
    guard currentSession == session else { throw AccessibilityAgentFailure.stale }
  }

  func consume(_ token: UUID, session: UUID) async throws {
    consumptions.append((token, session))
    if pauseConsumption { await withCheckedContinuation { consumptionWaiters.append($0) } }
    if let failure { throw failure }
    guard currentSession == session else { throw AccessibilityAgentFailure.stale }
  }

  func discard(_ token: UUID, session: UUID) async { discards.append((token, session)) }

  func stop() async {
    stopCount += 1
    currentSession = nil
  }

  func resumeStatus() {
    let waiters = statusWaiters
    statusWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func resumeCapture() {
    let waiters = captureWaiters
    captureWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func resumeValidation() {
    let waiters = validationWaiters
    validationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func resumeConsumption() {
    let waiters = consumptionWaiters
    consumptionWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  /// Failure-path cleanup also permits an operation not yet scheduled to finish.
  func resumeAll() {
    pauseStatus = false
    pauseCapture = false
    pauseValidation = false
    pauseConsumption = false
    resumeStatus()
    resumeCapture()
    resumeValidation()
    resumeConsumption()
  }
}

@MainActor
final class CompositionCopyRecorder: PasteboardWriting {
  private(set) var values: [String] = []
  var failAfterWriting = false

  func write(_ value: String) throws {
    values.append(value)
    if failAfterWriting { throw BexError.storageFailure("Synthetic clipboard failure") }
  }
}
