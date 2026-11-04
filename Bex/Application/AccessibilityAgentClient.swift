import Foundation

struct AccessibilityAgentCapturedResult: Sendable {
  let capture: AccessibilityAgentCapture
  let session: UUID
}

@MainActor
protocol AccessibilityAgentClientServing: AnyObject {
  var currentSession: UUID? { get }
  func status() async throws -> Bool
  func capture() async throws -> AccessibilityAgentCapturedResult
  func validate(_ token: UUID, session: UUID) async throws
  func consume(_ token: UUID, session: UUID) async throws
  func discard(_ token: UUID, session: UUID) async
  func stop() async
}

/// Inert at construction. Nothing in current production composition instantiates or calls
/// this adapter. Only a separately enrolled signed host can answer an explicit connection.
@MainActor
final class AccessibilityAgentClient: AccessibilityAgentClientServing {
  private struct Pending {
    let epoch: UUID
    let request: AccessibilityAgentRequest
    let continuation: CheckedContinuation<AccessibilityAgentResponse, any Error>
    let deadline: Task<Void, Never>
  }
  private let lifetime = AccessibilityConnectionLifetime()
  private var stopped = false
  private var connection: NSXPCConnection?
  private var epoch: UUID?
  private(set) var currentSession: UUID?
  private var handshake: Task<Void, any Error>?
  private var pending: [UUID: Pending] = [:]
  private var draining: [UUID: NSXPCConnection] = [:]
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  func status() async throws -> Bool {
    try await connect()
    let response = try await exchange(AccessibilityAgentRequest(operation: .status, session: currentSession))
    guard !stopped, response.session == currentSession, let trusted = response.trusted
    else { throw AccessibilityAgentFailure.stale }
    return trusted
  }

  func capture() async throws -> AccessibilityAgentCapturedResult {
    try await connect()
    let response = try await exchange(AccessibilityAgentRequest(operation: .capture, session: currentSession))
    guard let capture = response.captured, capture.processID > 0,
      !capture.bundleIdentifier.isEmpty, capture.bundleIdentifier.utf8.count <= 512,
      capture.applicationName.utf8.count <= 512,
      !capture.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      capture.original.utf8.count <= AccessibilityAgentContract.maximumDraftBytes
    else { invalidateCurrent(); throw AccessibilityAgentFailure.malformed }
    guard !stopped, let session = response.session, currentSession == session else { throw AccessibilityAgentFailure.stale }
    return AccessibilityAgentCapturedResult(capture: capture, session: session)
  }

  func validate(_ token: UUID, session: UUID) async throws {
    try await captureOperation(.validate, token: token, session: session)
  }

  func consume(_ token: UUID, session: UUID) async throws {
    try await captureOperation(.consume, token: token, session: session)
  }

  func discard(_ token: UUID, session: UUID) async {
    // Discard never starts or reconnects a service.
    try? await captureOperation(.discard, token: token, session: session)
  }

  func stop() async {
    stopped = true
    invalidateCurrent()
    await withCheckedContinuation { continuation in
      if draining.isEmpty { continuation.resume() }
      else { drainWaiters.append(continuation) }
    }
  }

  private func captureOperation(_ operation: AccessibilityAgentOperation, token: UUID, session: UUID) async throws {
    guard currentSession == session, connection != nil else { throw AccessibilityAgentFailure.stale }
    _ = try await exchange(AccessibilityAgentRequest(operation: operation, session: session, capture: token))
    guard currentSession == session else { throw AccessibilityAgentFailure.stale }
  }

  private func connect() async throws {
    try Task.checkCancellation()
    guard !stopped else { throw AccessibilityAgentFailure.cancelled }
    if currentSession != nil { return }
    if let handshake {
      try await handshake.value
      try Task.checkCancellation()
      guard currentSession != nil else { throw AccessibilityAgentFailure.unavailable }
      return
    }
    guard draining.isEmpty else { throw AccessibilityAgentFailure.unavailable }
    try AccessibilityAgentIdentity.verifyOwnIdentity(as: .app)
    let peerRequirement = try AccessibilityAgentIdentity.requirement(for: .helper)
    let newEpoch = UUID()
    let candidate = NSXPCConnection(machServiceName: AccessibilityAgentContract.serviceName, options: [])
    candidate.remoteObjectInterface = NSXPCInterface(with: AccessibilityAgentProtocol.self)
    candidate.setCodeSigningRequirement(peerRequirement)
    candidate.interruptionHandler = { [weak self] in
      Task { @MainActor in self?.interrupted(newEpoch) }
    }
    candidate.invalidationHandler = { [weak self] in
      Task { @MainActor in self?.invalidated(newEpoch) }
    }
    lifetime.retain(candidate, id: newEpoch)
    connection = candidate
    epoch = newEpoch
    candidate.resume()
    let task = Task { @MainActor [self] in
      let challenge = UUID()
      let hello = AccessibilityAgentRequest(operation: .hello, challenge: challenge)
      // setCodeSigningRequirement protects received messages, not the first outgoing
      // message. This first exchange deliberately contains no text or capabilities.
      let response = try await exchange(hello)
      guard epoch == newEpoch, connection != nil, response.challenge == challenge,
        let session = response.session else { throw AccessibilityAgentFailure.unauthorized }
      currentSession = session
    }
    handshake = task
    do {
      try await task.value
      try Task.checkCancellation()
      guard epoch == newEpoch, currentSession != nil else { throw AccessibilityAgentFailure.unavailable }
      handshake = nil
    } catch {
      if epoch == newEpoch { invalidateCurrent() }
      throw error
    }
  }

  private func exchange(_ request: AccessibilityAgentRequest) async throws -> AccessibilityAgentResponse {
    try Task.checkCancellation()
    guard !stopped, let connection, let epoch, pending.count < AccessibilityAgentContract.maximumPendingRequests else {
      throw AccessibilityAgentFailure.unavailable
    }
    let bytes = try AccessibilityAgentCodec.encode(request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard !Task.isCancelled, self.epoch == epoch else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let deadline = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .seconds(5)) } catch { return }
          guard let self, self.pending[request.id]?.epoch == epoch else { return }
          self.complete(request.id, result: .failure(AccessibilityAgentFailure.timeout))
          self.invalidateCurrent()
        }
        pending[request.id] = Pending(epoch: epoch, request: request, continuation: continuation, deadline: deadline)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
          Task { @MainActor in
            guard let self, self.pending[request.id]?.epoch == epoch else { return }
            self.complete(request.id, result: .failure(AccessibilityAgentFailure.unavailable))
            self.invalidateCurrent()
          }
        }) as? AccessibilityAgentProtocol else {
          complete(request.id, result: .failure(AccessibilityAgentFailure.unavailable))
          invalidateCurrent()
          return
        }
        proxy.exchange(bytes) { [weak self] data in
          Task { @MainActor in self?.receive(data, requestID: request.id, epoch: epoch) }
        }
      }
    } onCancel: { [weak self] in
      Task { @MainActor in
        guard let self, self.pending[request.id]?.epoch == epoch else { return }
        self.complete(request.id, result: .failure(CancellationError()))
        self.invalidateCurrent()
      }
    }
  }

  private func receive(_ data: Data, requestID: UUID, epoch: UUID) {
    guard let item = pending[requestID], item.epoch == epoch, self.epoch == epoch else { return }
    do {
      let response = try AccessibilityAgentCodec.decode(AccessibilityAgentResponse.self, from: data)
      guard response.version == AccessibilityAgentContract.version,
        response.runtimeRevision == AccessibilityAgentContract.runtimeRevision,
        response.requestID == requestID else { throw AccessibilityAgentFailure.incompatible }
      if let failure = response.failure { throw failure }
      let request = item.request
      if request.operation == .hello {
        guard response.session != nil, response.challenge == request.challenge,
          response.trusted == nil, response.captured == nil else { throw AccessibilityAgentFailure.malformed }
      } else {
        guard response.session == request.session, response.session == currentSession,
          response.challenge == nil,
          (request.operation == .status) == (response.trusted != nil),
          (request.operation == .capture) == (response.captured != nil)
        else { throw AccessibilityAgentFailure.malformed }
      }
      complete(requestID, result: .success(response))
    } catch {
      complete(requestID, result: .failure(error))
      // No retry after a failed peer, protocol or capture operation. Invalidation revokes
      // all connection-bound captures; a later explicit action creates a fresh session.
      invalidateCurrent()
    }
  }

  private func complete(_ id: UUID, result: Result<AccessibilityAgentResponse, any Error>) {
    guard let item = pending.removeValue(forKey: id) else { return }
    item.deadline.cancel()
    item.continuation.resume(with: result)
  }

  private func interrupted(_ endedEpoch: UUID) {
    if epoch == endedEpoch { invalidateCurrent() }
  }

  private func invalidateCurrent() {
    guard let oldEpoch = epoch, let oldConnection = connection else { return }
    epoch = nil
    connection = nil
    currentSession = nil
    handshake?.cancel()
    handshake = nil
    draining[oldEpoch] = oldConnection
    for id in Array(pending.keys) where pending[id]?.epoch == oldEpoch {
      complete(id, result: .failure(AccessibilityAgentFailure.cancelled))
    }
    oldConnection.invalidate()
  }

  private func invalidated(_ endedEpoch: UUID) {
    if epoch == endedEpoch { invalidateCurrent() }
    draining.removeValue(forKey: endedEpoch)
    lifetime.release(endedEpoch)
    if draining.isEmpty {
      let waiters = drainWaiters
      drainWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }
}

/// Invalidates before the last retained connection is released, even if the owner forgets
/// explicit stop. The normal stop path additionally waits for invalidation completion.
private final class AccessibilityConnectionLifetime {
  private var connections: [UUID: NSXPCConnection] = [:]
  func retain(_ connection: NSXPCConnection, id: UUID) { connections[id] = connection }
  func release(_ id: UUID) { connections.removeValue(forKey: id) }
  deinit { connections.values.forEach { $0.invalidate() } }
}
