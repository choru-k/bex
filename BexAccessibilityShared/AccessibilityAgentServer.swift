import Darwin
import Foundation

/// Constructed only by the independent host's explicit --agent entry point.
final class AccessibilityAgentServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
  private struct Connection {
    let connection: NSXPCConnection
    let deadline: DispatchSourceTimer
  }
  private let listener: NSXPCListener
  private let control = DispatchQueue(label: "com.bex.accessibility.listener")
  private var connections: [UUID: Connection] = [:]
  private var stopped = false
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []
  private let appRequirement: String

  init(validatingIdentity: Void) throws {
    try AccessibilityAgentIdentity.verifyOwnIdentity(as: .helper)
    appRequirement = try AccessibilityAgentIdentity.requirement(for: .app)
    listener = NSXPCListener(machServiceName: AccessibilityAgentContract.serviceName)
    super.init()
    listener.delegate = self
  }

  func start() { control.sync { if !stopped { listener.resume() } } }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier == getuid(), getuid() != 0 else { return false }
    return control.sync {
      guard !stopped, connections.count < AccessibilityAgentContract.maximumConnections else { return false }
      let id = UUID()
      let session = AccessibilityAgentServerSession(callerProcessID: connection.processIdentifier,
        onAuthenticatedMessage: { [weak self] in self?.refreshDeadline(id) })
      connection.exportedInterface = NSXPCInterface(with: AccessibilityAgentProtocol.self)
      connection.exportedObject = session
      connection.setCodeSigningRequirement(appRequirement)
      connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
      connection.invalidationHandler = { [weak self, session] in
        session.close { [weak self] in self?.release(id) }
      }
      let deadline = DispatchSource.makeTimerSource(queue: control)
      // Silent, unauthenticated clients cannot reserve one of the four slots forever.
      deadline.schedule(deadline: .now() + 5)
      deadline.setEventHandler { [weak connection] in connection?.invalidate() }
      connections[id] = Connection(connection: connection, deadline: deadline)
      deadline.resume()
      // Setup/resume and stop share this queue; stop cannot invalidate half-configured peers.
      connection.resume()
      return true
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      control.async { [self] in
        stopped = true
        listener.invalidate()
        guard !connections.isEmpty else { continuation.resume(); return }
        drainWaiters.append(continuation)
        for entry in connections.values { entry.deadline.cancel(); entry.connection.invalidate() }
      }
    }
  }

  private func refreshDeadline(_ id: UUID) {
    control.async { [weak self] in
      guard let self, !self.stopped, let entry = self.connections[id] else { return }
      // Authenticated review sessions have an hour-long capture limit, then close while idle.
      entry.deadline.schedule(deadline: .now() + AccessibilityAgentContract.captureLifetime + 5)
    }
  }

  private func release(_ id: UUID) {
    control.async { [weak self] in
      guard let self else { return }
      self.connections.removeValue(forKey: id)?.deadline.cancel()
      if self.stopped && self.connections.isEmpty {
        let waiters = self.drainWaiters
        self.drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
      }
    }
  }
}

private final class AccessibilityAgentServerSession: NSObject, AccessibilityAgentProtocol, @unchecked Sendable {
  private let callerProcessID: Int32
  private let onAuthenticatedMessage: @Sendable () -> Void
  private let lock = NSLock()
  private var closed = false
  private var pending = 0
  private var storeClosed = false
  private var onDrained: (@Sendable () -> Void)?
  @MainActor private var store: AccessibilityCaptureStore?

  init(callerProcessID: Int32, onAuthenticatedMessage: @escaping @Sendable () -> Void) {
    self.callerProcessID = callerProcessID
    self.onAuthenticatedMessage = onAuthenticatedMessage
    super.init()
  }

  func exchange(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
    guard data.count <= AccessibilityAgentContract.maximumMessageBytes, admit() else {
      reply(Self.failure(.capacity))
      return
    }
    let acceptedAt = DispatchTime.now().uptimeNanoseconds
    Task { @MainActor [self] in
      defer { finish() }
      guard isOpen else { return }
      do {
        guard DispatchTime.now().uptimeNanoseconds - acceptedAt < 5_000_000_000 else {
          throw AccessibilityAgentFailure.timeout
        }
        let request = try AccessibilityAgentCodec.decode(AccessibilityAgentRequest.self, from: data)
        if store == nil {
          store = AccessibilityCaptureStore(observer: AccessibilitySystemObserver(), callerProcessID: callerProcessID)
        }
        guard let store else { throw AccessibilityAgentFailure.unavailable }
        let response = store.handle(request, deadline: AccessibilityObservationDeadline(end: acceptedAt + 3_000_000_000))
        let encoded = try AccessibilityAgentCodec.encode(response)
        guard isOpen else { return }
        if response.failure == nil { onAuthenticatedMessage() }
        reply(encoded)
      } catch {
        if isOpen { reply(Self.failure((error as? AccessibilityAgentFailure) ?? .malformed)) }
      }
    }
  }

  func close(onDrained: @escaping @Sendable () -> Void) {
    lock.lock(); closed = true; self.onDrained = onDrained; lock.unlock()
    Task { @MainActor [self] in
      store?.close()
      store = nil
      didCloseStore()
    }
  }

  private var isOpen: Bool {
    lock.lock(); defer { lock.unlock() }
    return !closed
  }

  private func admit() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard !closed, pending < AccessibilityAgentContract.maximumPendingRequests else { return false }
    pending += 1
    return true
  }

  private func finish() {
    lock.lock()
    pending -= 1
    let completion = takeDrainCompletion()
    lock.unlock()
    completion?()
  }

  private func didCloseStore() {
    lock.lock()
    storeClosed = true
    let completion = takeDrainCompletion()
    lock.unlock()
    completion?()
  }

  // Called under lock. A stopped listener drains queued AX work and captured fields,
  // not just the XPC connections whose callbacks scheduled that cleanup.
  private func takeDrainCompletion() -> (@Sendable () -> Void)? {
    guard closed, storeClosed, pending == 0 else { return nil }
    let completion = onDrained
    onDrained = nil
    return completion
  }

  private static func failure(_ reason: AccessibilityAgentFailure) -> Data {
    // No prompt or caller-controlled detail is reflected in transport failures.
    (try? AccessibilityAgentCodec.encode(AccessibilityAgentResponse(requestID: UUID(), failure: reason))) ?? Data()
  }
}
