import Darwin
import Foundation

actor PromptGateIPCServer: PromptGateIPCServicing, HookReviewResponding {
  typealias TransportFactory = @Sendable (
    @escaping @Sendable (UUID, PromptHTTPRequestParser.Request) async -> Void,
    @escaping @Sendable (UUID) async -> Void,
    @escaping @Sendable () -> Void
  ) -> PromptGateHTTPTransport
  private struct Pending {
    let request: HookReviewRequest
    let connectionID: UUID
    var waitingForAcknowledgment = false
    var acknowledgmentToken: String?
    var approvedPrompt: String?
    var deliveryToken: String?
    var acknowledgmentContinuation: CheckedContinuation<Void, Error>?
    var deadline: Task<Void, Never>?
  }

  private let rendezvousURL: URL
  private let deadlineSeconds: TimeInterval
  private let makeTransport: TransportFactory
  private let rendezvousStorage: (any PromptGateRendezvousStorage)?
  private var transport: PromptGateHTTPTransport?
  private var generation: UUID?
  private var ready = false
  private var stopping = false
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private var authenticationToken = ""
  private var pending: Pending?
  // A disconnected request does not release an uncooperative application handler's
  // slot. Bound handler work independently from connection/I/O ownership.
  private var requestHandlerID: UUID?
  private var invalidationHandlerID: UUID?
  private var deferredInvalidation: Pending?
  private var onRequest: (@Sendable (HookReviewRequest) async -> Bool)?
  private var onInvalidation: (@Sendable (UUID) async -> Void)?

  init(
    rendezvousURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/PromptGate", isDirectory: true)
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName),
    deadlineSeconds: TimeInterval = 3_500,
    makeTransport: @escaping TransportFactory = { request, close, termination in
      PromptGateHTTPTransport(onRequest: request, onClose: close, onTermination: termination)
    },
    rendezvousStorage: (any PromptGateRendezvousStorage)? = nil
  ) {
    self.rendezvousURL = rendezvousURL
    self.makeTransport = makeTransport
    self.rendezvousStorage = rendezvousStorage
    self.deadlineSeconds = deadlineSeconds.isFinite ? min(max(deadlineSeconds, 1), 3_500) : 3_500
  }

  func setHandlers(
    onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
    onInvalidation: @escaping @Sendable (UUID) async -> Void
  ) {
    self.onRequest = onRequest
    self.onInvalidation = onInvalidation
  }

  func start() async throws {
    guard !stopping else { throw deliveryFailure }
    if transport != nil {
      guard ready else { throw deliveryFailure }
      return
    }
    let lifetime = UUID()
    generation = lifetime
    authenticationToken = Self.randomToken()
    let service = makeTransport({ [weak self] id, request in
      await self?.received(request, id: id, generation: lifetime)
    }, { [weak self] id in
      await self?.connectionClosed(id: id, generation: lifetime)
    }, { [weak self] in
      Task { await self?.transportTerminated(generation: lifetime) }
    })
    transport = service
    do {
      let port = try await service.start()
      guard generation == lifetime, !stopping else { throw deliveryFailure }
      try writeRendezvous(port: port)
      ready = true
    } catch {
      // Stop/restart may have replaced the owner while start was suspended.
      if generation == lifetime {
        generation = nil
        ready = false
        authenticationToken = ""
      }
      await service.stop()
      if transport === service { transport = nil }
      throw deliveryFailure
    }
  }

  private func transportTerminated(generation: UUID) async {
    guard self.generation == generation else { return }
    await stop()
  }

  func stop() async {
    if stopping {
      await withCheckedContinuation { stopWaiters.append($0) }
      return
    }
    stopping = true
    let service = transport
    let current = pending
    let token = authenticationToken
    generation = nil
    ready = false
    transport = nil
    authenticationToken = ""
    pending = nil
    current?.deadline?.cancel()
    current?.acknowledgmentContinuation?.resume(throwing: deliveryFailure)
    removeOwnRendezvous(token: token)
    // Close admission and drain all owned I/O before allowing a new listener.
    await service?.stop()
    if let current { await invalidate(current) }
    stopping = false
    let waiters = stopWaiters
    stopWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func complete(
    requestID: UUID,
    outcome: HookReviewOutcome,
    awaitAcknowledgement: Bool,
    approvedPrompt: String?,
    integrationID: String?
  ) async throws {
    guard var current = pending, current.request.requestID == requestID,
      !current.waitingForAcknowledgment, let service = transport
    else { throw deliveryFailure }
    let id = current.connectionID

    guard outcome == .approved, awaitAcknowledgement else {
      current.deadline?.cancel()
      pending = nil
      await sendReviewResponse(outcome, token: nil, id: id, service: service)
      return
    }
    if current.request.client == .ohMyPi {
      guard let approvedPrompt, !approvedPrompt.isEmpty,
        let integrationID, integrationID == current.request.integrationID
      else { throw BexError.promptDeliveryFailed("The OMP approval identity is invalid.") }
      current.approvedPrompt = approvedPrompt
      current.deliveryToken = Self.randomToken()
    }
    let acknowledgmentToken = Self.randomToken()
    let response = reviewResponse(.approved, token: acknowledgmentToken, request: current.request,
      approvedPrompt: current.approvedPrompt, deliveryToken: current.deliveryToken)
    guard let response, response.count <= HookProtocolConstants.maximumMessageBytes else {
      throw BexError.promptDeliveryFailed("The approved prompt is too large.")
    }
    current.deadline?.cancel()
    current.deadline = nil
    current.waitingForAcknowledgment = true
    current.acknowledgmentToken = acknowledgmentToken
    pending = current

    // Every continuation and cleanup belongs to this connection, not merely a
    // caller-controlled request UUID that might be reused in a later request.
    defer {
      // Covers cancellation before continuation installation too: the transport
      // hold must never survive after its actor pending owner has been removed.
      service.close(id)
      if pending?.connectionID == id {
        pending?.deadline?.cancel()
        pending = nil
      }
    }
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        guard var owned = pending, owned.connectionID == id else {
          continuation.resume(throwing: deliveryFailure); return
        }
        owned.acknowledgmentContinuation = continuation
        pending = owned
        Task { [weak self] in
          await self?.publishApproval(id: id, response: response, service: service)
        }
      }
    } onCancel: {
      Task { await self.cancelApproval(id: id) }
    }

    guard pending?.connectionID == id else { throw deliveryFailure }
    let clock = ContinuousClock()
    let exitDeadline = clock.now.advanced(by: .seconds(2))
    while Self.processIsAlive(current.request.helperPID), clock.now < exitDeadline {
      try await Task.sleep(for: .milliseconds(25))
      guard pending?.connectionID == id else { throw deliveryFailure }
    }
    guard !Self.processIsAlive(current.request.helperPID) else {
      throw BexError.promptDeliveryFailed("The Prompt Gate helper did not exit safely.")
    }
    try await Task.sleep(for: .milliseconds(150))
    guard pending?.connectionID == id else { throw deliveryFailure }
  }

  private func publishApproval(id: UUID, response: Data, service: PromptGateHTTPTransport) async {
    guard pending?.connectionID == id, pending?.acknowledgmentContinuation != nil else { return }
    guard await service.respond(id, status: 200, body: response) else {
      cancelApproval(id: id)
      return
    }
    guard var current = pending, current.connectionID == id,
      current.acknowledgmentContinuation != nil else { return }
    current.deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      await self?.cancelApproval(id: id)
    }
    pending = current
  }

  private func cancelApproval(id: UUID) {
    guard let current = pending, current.connectionID == id else { return }
    pending = nil
    current.deadline?.cancel()
    transport?.close(id)
    current.acknowledgmentContinuation?.resume(throwing: deliveryFailure)
  }

  private func received(_ request: PromptHTTPRequestParser.Request, id: UUID, generation: UUID) async {
    guard self.generation == generation, ready, let service = transport else { return }
    switch request.path {
    case HookProtocolConstants.reviewPath:
      await receiveReview(request.body, id: id, service: service, generation: generation)
    case HookProtocolConstants.acknowledgmentPath:
      await receiveAcknowledgment(request.body, id: id, service: service, generation: generation)
    default:
      _ = await service.respond(id, status: 404, body: Data())
    }
  }

  private func receiveReview(_ data: Data, id: UUID, service: PromptGateHTTPTransport,
    generation: UUID) async {
    guard let envelope = try? JSONDecoder().decode(HookReviewEnvelope.self, from: data),
      envelope.version == HookProtocolConstants.version, envelope.request.helperPID > 0
    else { _ = await service.respond(id, status: 400, body: Data()); return }
    guard PromptGateAuthentication.matches(envelope.authenticationToken, expected: authenticationToken)
    else { _ = await service.respond(id, status: 401, body: Data()); return }
    guard pending == nil, requestHandlerID == nil, invalidationHandlerID == nil, let onRequest else {
      await sendReviewResponse(.failed, token: nil, id: id, service: service); return
    }

    // Reserve the sole review before hopping to the transport or application handler.
    requestHandlerID = id
    pending = Pending(request: envelope.request, connectionID: id)
    let held = await service.hold(id)
    guard held, self.generation == generation, pending?.connectionID == id else {
      if pending?.connectionID == id { pending = nil }
      service.close(id)
      await finishRequestHandler(id: id)
      return
    }
    let seconds = deadlineSeconds
    pending?.deadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
      await self?.reviewTimedOut(id: id)
    }
    let accepted = await onRequest(envelope.request)
    await finishRequestHandler(id: id)
    guard self.generation == generation, pending?.connectionID == id else { return }
    if !accepted, let current = pending {
      pending = nil
      current.deadline?.cancel()
      current.acknowledgmentContinuation?.resume(throwing: deliveryFailure)
      await sendReviewResponse(.failed, token: nil, id: id, service: service)
    }
  }

  private func receiveAcknowledgment(_ data: Data, id: UUID, service: PromptGateHTTPTransport,
    generation: UUID) async {
    guard let envelope = try? JSONDecoder().decode(HookAcknowledgmentEnvelope.self, from: data),
      envelope.version == HookProtocolConstants.version,
      PromptGateAuthentication.matches(envelope.authenticationToken, expected: authenticationToken)
    else { _ = await service.respond(id, status: 401, body: Data()); return }
    guard var current = pending, current.request.requestID == envelope.requestID else {
      _ = await service.respond(id, status: 409, body: Data()); return
    }
    guard current.waitingForAcknowledgment, let token = current.acknowledgmentToken,
      PromptGateAuthentication.matches(envelope.acknowledgmentToken, expected: token),
      let continuation = current.acknowledgmentContinuation else {
      _ = await service.respond(id, status: 403, body: Data()); return
    }
    if current.request.client == .ohMyPi {
      guard let deliveryToken = current.deliveryToken, let suppliedToken = envelope.deliveryToken,
        PromptGateAuthentication.matches(suppliedToken, expected: deliveryToken),
        envelope.integrationID == current.request.integrationID, envelope.deliveryStatus == "delivered"
      else { _ = await service.respond(id, status: 403, body: Data()); return }
    }
    current.deadline?.cancel()
    current.deadline = nil
    current.acknowledgmentToken = nil
    current.acknowledgmentContinuation = nil
    pending = current
    // Claim the single-use ack before suspension. A concurrent stop must not turn
    // a cancelled delivery into a successful approval on this continuation's return.
    let sent = await service.respond(id, status: 200, body: Data())
    if sent, self.generation == generation, pending?.connectionID == current.connectionID {
      continuation.resume()
    } else {
      continuation.resume(throwing: deliveryFailure)
    }
  }

  private func connectionClosed(id: UUID, generation: UUID) async {
    guard self.generation == generation, let current = pending,
      current.connectionID == id, !current.waitingForAcknowledgment else { return }
    pending = nil
    current.deadline?.cancel()
    await invalidate(current)
  }

  private func reviewTimedOut(id: UUID) async {
    guard let current = pending, current.connectionID == id, !current.waitingForAcknowledgment else { return }
    pending = nil
    // Reserve invalidation before sending: no newer review may overlap this callback.
    invalidationHandlerID = id
    let deferred = requestHandlerID == id
    if deferred { deferredInvalidation = current }
    if let service = transport { await sendReviewResponse(.failed, token: nil, id: id, service: service) }
    if !deferred {
      await onInvalidation?(current.request.requestID)
      if invalidationHandlerID == id { invalidationHandlerID = nil }
    }
  }

  private func invalidate(_ current: Pending) async {
    guard invalidationHandlerID == nil else { return }
    invalidationHandlerID = current.connectionID
    if requestHandlerID == current.connectionID {
      // The handler may create UI after an await. Its final effect must precede
      // invalidation, and no new review may enter until both have returned.
      deferredInvalidation = current
      return
    }
    await onInvalidation?(current.request.requestID)
    if invalidationHandlerID == current.connectionID { invalidationHandlerID = nil }
  }

  private func finishRequestHandler(id: UUID) async {
    if requestHandlerID == id { requestHandlerID = nil }
    guard let retired = deferredInvalidation, retired.connectionID == id else { return }
    deferredInvalidation = nil
    await onInvalidation?(retired.request.requestID)
    if invalidationHandlerID == id { invalidationHandlerID = nil }
  }

  private var deliveryFailure: BexError {
    .promptDeliveryFailed("The Prompt Gate helper disconnected or did not acknowledge the block.")
  }

  private func reviewResponse(_ outcome: HookReviewOutcome, token: String?,
    request: HookReviewRequest? = nil, approvedPrompt: String? = nil, deliveryToken: String? = nil) -> Data? {
    try? JSONEncoder().encode(HookReviewResponseEnvelope(version: HookProtocolConstants.version,
      outcome: outcome, acknowledgmentToken: token, integrationID: request?.integrationID,
      approvedPrompt: approvedPrompt, deliveryToken: deliveryToken))
  }

  private func sendReviewResponse(_ outcome: HookReviewOutcome, token: String?, id: UUID,
    service: PromptGateHTTPTransport) async {
    _ = await service.respond(id, status: 200, body: reviewResponse(outcome, token: token) ?? Data())
  }

  private func writeRendezvous(port: UInt16) throws {
    let value = HookRendezvous(version: HookProtocolConstants.version, port: port,
      authenticationToken: authenticationToken, serverPID: ProcessInfo.processInfo.processIdentifier,
      createdAt: Date())
    if let rendezvousStorage { try rendezvousStorage.publish(value); return }
    let directory = rendezvousURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard chmod(directory.path, 0o700) == 0 else { throw deliveryFailure }
    let data = try JSONEncoder().encode(value)
    let temporary = directory.appendingPathComponent(".rendezvous-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .withoutOverwriting)
    guard chmod(temporary.path, 0o600) == 0, rename(temporary.path, rendezvousURL.path) == 0 else {
      throw deliveryFailure
    }
  }

  private func removeOwnRendezvous(token: String) {
    if let rendezvousStorage { rendezvousStorage.remove(ifTokenMatches: token); return }
    guard !token.isEmpty, let handle = try? FileHandle(forReadingFrom: rendezvousURL) else { return }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4_097), data.count <= 4_096,
      let value = try? JSONDecoder().decode(HookRendezvous.self, from: data),
      value.serverPID == ProcessInfo.processInfo.processIdentifier,
      PromptGateAuthentication.matches(value.authenticationToken, expected: token) else { return }
    try? FileManager.default.removeItem(at: rendezvousURL)
  }

  /// Internal diagnostics for socket-free synthetic ownership tests.
  struct Snapshot: Sendable {
    let ready: Bool
    let stopping: Bool
    let hasTransport: Bool
    let pendingConnectionID: UUID?
    let requestHandlerActive: Bool
    let invalidationActive: Bool
  }
  func snapshot() -> Snapshot {
    Snapshot(ready: ready, stopping: stopping, hasTransport: transport != nil,
      pendingConnectionID: pending?.connectionID, requestHandlerActive: requestHandlerID != nil,
      invalidationActive: invalidationHandlerID != nil)
  }

  private static func randomToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private static func processIsAlive(_ processID: Int32) -> Bool {
    guard processID > 0 else { return false }
    return kill(processID, 0) == 0 || errno == EPERM
  }
}

/// Test storage can keep synthetic rendezvous values in memory. The default path
/// still publishes the same v1 file with private directory/file permissions.
protocol PromptGateRendezvousStorage: Sendable {
  func publish(_ value: HookRendezvous) throws
  func remove(ifTokenMatches token: String)
}
