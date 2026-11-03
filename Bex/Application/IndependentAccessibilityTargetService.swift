import Foundation

/// Complete asynchronous capture/Copy adapter, intentionally NOT selected by AppServices.
/// A future production migration must adopt async capture/validation after native validation.
/// The safe existing main-app path remains unchanged; remote failure never falls back to it.
@MainActor
final class IndependentAccessibilityTargetService {
  private struct Issued {
    let target: PromptTarget
    let remote: AccessibilityAgentCapture
    let session: UUID
    let expiresAt: Date
    let generation: UUID
  }
  private let client: any AccessibilityAgentClientServing
  private let manual: PromptTargetService
  private let pasteboard: any PasteboardWriting
  private let now: @MainActor () -> Date
  private var issued: [UUID: Issued] = [:]
  private var consuming: [UUID: Issued] = [:]
  private var generation = UUID()
  private var stopped = false
  private var inFlightCaptures = 0

  init(client: any AccessibilityAgentClientServing = AccessibilityAgentClient(),
       pasteboard: any PasteboardWriting = SystemPasteboard(), now: @escaping @MainActor () -> Date = { Date() }) {
    self.client = client
    self.pasteboard = pasteboard
    self.now = now
    manual = PromptTargetService(pasteboardWriter: pasteboard)
  }

  func accessibilityStatus() async throws -> Bool {
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    let startedGeneration = generation
    let trusted = try await client.status()
    guard !stopped, generation == startedGeneration else { throw AccessibilityAgentFailure.cancelled }
    return trusted
  }

  // No trust/registration IPC. Setup and OS permission requests belong to explicit
  // buttons in the independently installed host application, never to this adapter.
  func makeStandaloneTarget() throws -> PromptTarget {
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    return try manual.makeStandaloneTarget()
  }
  func target(for request: HookReviewRequest) throws -> PromptTarget {
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    return try manual.target(for: request)
  }

  func captureFrontmostTarget() async throws -> PromptCapture {
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    prune()
    guard issued.count + consuming.count + inFlightCaptures < AccessibilityAgentContract.maximumCaptures else {
      throw AccessibilityAgentFailure.capacity
    }
    let startedGeneration = generation
    inFlightCaptures += 1
    defer { inFlightCaptures -= 1 }
    let result = try await client.capture()
    let capture = result.capture
    let session = result.session
    guard !Task.isCancelled, !stopped, generation == startedGeneration,
      client.currentSession == session else {
      Task { @MainActor [client] in await client.discard(capture.token, session: session) }
      throw AccessibilityAgentFailure.cancelled
    }
    let target = PromptTarget(kind: .capturedField, processID: capture.processID,
      bundleID: capture.bundleIdentifier, applicationName: capture.applicationName,
      guidance: "The independent Bex Accessibility service captured this draft. Copy the correction, then replace the intended draft and submit manually.")
    issued[target.id] = Issued(target: target, remote: capture, session: session,
      expiresAt: now().addingTimeInterval(AccessibilityAgentContract.captureLifetime), generation: generation)
    return PromptCapture(draft: capture.original, target: target, source: .capturedField)
  }

  func validateDelivery(to target: PromptTarget, action: PromptDeliveryAction) async throws {
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    if target.kind != .capturedField {
      try manual.validateDelivery(to: target, action: action)
      return
    }
    let entry = try liveEntry(target, action: action)
    try await client.validate(entry.remote.token, session: entry.session)
    // MainActor reentrancy during IPC may discard/replace/expire this review.
    _ = try liveEntry(target, action: action, expectedGeneration: entry.generation)
    try Task.checkCancellation()
  }

  func deliver(_ text: String, to target: PromptTarget, action: PromptDeliveryAction) async throws -> PromptDeliveryOutcome {
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    if target.kind != .capturedField { return try await manual.deliver(text, to: target, action: action) }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BexError.emptyInput }
    try await validateDelivery(to: target, action: action)
    let entry = try liveEntry(target, action: action)
    try Task.checkCancellation()
    // Reserve locally before suspension. Two simultaneous approvals cannot consume
    // the same review, and a cancelled/discarded review cannot copy after a late reply.
    issued.removeValue(forKey: target.id)
    consuming[target.id] = entry
    defer { consuming.removeValue(forKey: target.id) }
    try await client.consume(entry.remote.token, session: entry.session)
    guard !stopped, let reserved = consuming[target.id],
      reserved.target.matchesDeliveryIdentity(target), reserved.generation == generation,
      reserved.expiresAt > now(), client.currentSession == reserved.session
    else { throw BexError.stalePromptTarget }
    try Task.checkCancellation()
    consuming.removeValue(forKey: target.id)
    do { try pasteboard.write(text) }
    catch { throw PromptDeliveryFailure(effect: .unknown, underlyingError: error) }
    return .copied
  }

  func discard(_ target: PromptTarget) {
    guard let entry = issued.removeValue(forKey: target.id) ?? consuming.removeValue(forKey: target.id)
    else { manual.discard(target); return }
    Task { @MainActor [client] in await client.discard(entry.remote.token, session: entry.session) }
  }

  func stop() async {
    stopped = true
    generation = UUID()
    issued.removeAll()
    consuming.removeAll()
    await client.stop()
  }

  private func liveEntry(_ target: PromptTarget, action: PromptDeliveryAction, expectedGeneration: UUID? = nil) throws -> Issued {
    guard !stopped, action == .copyCorrection, let entry = issued[target.id],
      entry.target.matchesDeliveryIdentity(target), entry.expiresAt > now(),
      entry.generation == generation, expectedGeneration == nil || entry.generation == expectedGeneration,
      client.currentSession == entry.session else { throw BexError.stalePromptTarget }
    return entry
  }

  private func prune() {
    for entry in Array(issued.values) where entry.expiresAt <= now() || entry.session != client.currentSession {
      issued.removeValue(forKey: entry.target.id)
      Task { @MainActor [client] in await client.discard(entry.remote.token, session: entry.session) }
    }
  }
}
