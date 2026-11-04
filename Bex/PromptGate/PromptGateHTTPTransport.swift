import Foundation
@preconcurrency import Network

/// Queue-confined transport ownership. Admission happens before any actor-hop Task.
/// Stop drains the listener, accepted connections, and outstanding I/O callbacks.
final class PromptGateHTTPTransport: @unchecked Sendable {
  static let maximumConnections = 8
  private final class Connection {
    let transport: any PromptGateConnectionTransport
    var parser: PromptHTTPRequestParser
    var reading = false
    var writing = false
    var delivered = false
    var dispatching = false
    var notifyingClose = false
    var cancelling = false
    var cancelled = false
    var deadline: (any PromptGateDeadline)?
    var deadlineID: UUID?
    var response: CheckedContinuation<Bool, Never>?
    init(_ transport: any PromptGateConnectionTransport, port: UInt16) {
      self.transport = transport
      parser = PromptHTTPRequestParser(port: port)
    }
  }

  private let queue = DispatchQueue(label: "com.bex.desktop.prompt-gate-ipc")
  private let makeListener: @Sendable () throws -> any PromptGateListenerTransport
  private let scheduler: any PromptGateScheduling
  private let onRequest: @Sendable (UUID, PromptHTTPRequestParser.Request) async -> Void
  private let onClose: @Sendable (UUID) async -> Void
  private let onTermination: @Sendable () -> Void
  private var listener: (any PromptGateListenerTransport)?
  private var connections: [UUID: Connection] = [:]
  private var credits = 0
  private var started = false
  private var stopping = false
  private var port: UInt16 = 0
  private var startContinuation: CheckedContinuation<UInt16, any Error>?
  private var startDeadline: (any PromptGateDeadline)?
  private var stopContinuations: [CheckedContinuation<Void, Never>] = []

  init(
    makeListener: @escaping @Sendable () throws -> any PromptGateListenerTransport = {
      try PromptGateNetworkListener()
    },
    scheduler: any PromptGateScheduling = PromptGateDispatchScheduler(),
    onRequest: @escaping @Sendable (UUID, PromptHTTPRequestParser.Request) async -> Void,
    onClose: @escaping @Sendable (UUID) async -> Void,
    onTermination: @escaping @Sendable () -> Void = {}
  ) {
    self.makeListener = makeListener
    self.scheduler = scheduler
    self.onRequest = onRequest
    self.onClose = onClose
    self.onTermination = onTermination
  }

  deinit {
    startDeadline?.cancel()
    listener?.cancel()
    for connection in connections.values {
      connection.deadline?.cancel()
      connection.transport.cancel()
    }
  }

  func start() async throws -> UInt16 {
    try await withTaskCancellationHandler {
      guard !Task.isCancelled else { throw PromptGateTransportError.unavailable }
      return try await withCheckedThrowingContinuation { continuation in
        queue.async { self.startOnQueue(continuation) }
      }
    } onCancel: {
      self.queue.async { self.terminate() }
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.stopContinuations.append(continuation)
        self.terminate()
      }
    }
  }

  /// Only the authenticated actor may hold a fully received request for user review.
  func hold(_ id: UUID) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async {
        guard !self.stopping, let connection = self.connections[id], connection.delivered,
          !connection.cancelling, !connection.writing
        else { continuation.resume(returning: false); return }
        connection.deadlineID = nil
        connection.deadline?.cancel()
        connection.deadline = nil
        continuation.resume(returning: true)
      }
    }
  }

  func close(_ id: UUID) {
    queue.async { self.cancelConnection(id) }
  }

  func respond(_ id: UUID, status: Int, body: Data) async -> Bool {
    await withCheckedContinuation { continuation in
      queue.async { self.respondOnQueue(id, status: status, body: body, continuation: continuation) }
    }
  }

  private func startOnQueue(_ continuation: CheckedContinuation<UInt16, any Error>) {
    guard !started, !stopping else {
      continuation.resume(throwing: PromptGateTransportError.unavailable); return
    }
    started = true
    do {
      let listener = try makeListener()
      self.listener = listener
      startContinuation = continuation
      credits = Self.maximumConnections
      listener.newConnectionLimit = credits
      listener.start(queue: queue, state: { [weak self] state in self?.handle(state) },
        connection: { [weak self] connection in
          guard let self else { connection.cancel(); return }
          self.accept(connection)
        })
      startDeadline = scheduler.schedule(after: 5, queue: queue) { [weak self] in
        guard let self, self.startContinuation != nil else { return }
        self.terminate()
      }
    } catch {
      continuation.resume(throwing: PromptGateTransportError.unavailable)
      terminate()
    }
  }

  private func handle(_ state: PromptGateListenerState) {
    dispatchPrecondition(condition: .onQueue(queue))
    switch state {
    case .ready:
      guard !stopping, let readyPort = listener?.port, readyPort != 0 else { terminate(); return }
      port = readyPort
      startDeadline?.cancel()
      startDeadline = nil
      let continuation = startContinuation
      startContinuation = nil
      continuation?.resume(returning: readyPort)
    case .waiting, .failed: terminate()
    case .cancelled:
      listener = nil
      terminate()
      finishDrain()
    }
  }

  private func accept(_ transport: any PromptGateConnectionTransport) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard credits > 0, connections.count < Self.maximumConnections else {
      transport.cancel()
      terminate()
      return
    }
    credits -= 1
    let id = UUID()
    let connection = Connection(transport, port: port)
    connections[id] = connection
    transport.start(queue: queue) { [weak self] state in
      guard let self, let connection = self.connections[id] else { return }
      if case .cancelled = state { connection.cancelled = true }
      self.cancelConnection(id)
      self.releaseIfDrained(id)
    }
    guard !stopping, port != 0 else { cancelConnection(id); return }
    setDeadline(id, seconds: 10)
    receive(id)
    refillCredits()
  }

  private func receive(_ id: UUID) {
    guard let connection = connections[id], !connection.cancelling else { return }
    connection.reading = true
    let transport = connection.transport
    let maximum = connection.delivered ? 1 : PromptHTTPRequestParser.maximumReceiveBytes
    transport.receive(maximumLength: maximum) { [weak self, transport] data, complete, failed in
      guard let self else { transport.cancel(); return }
      self.received(id, data: data, complete: complete, failed: failed)
    }
  }

  private func received(_ id: UUID, data: Data?, complete: Bool, failed: Bool) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection = connections[id], connection.reading else { return }
    connection.reading = false
    guard !connection.cancelling, !stopping else { releaseIfDrained(id); return }
    if connection.delivered {
      // Detect disconnects while review is held; never accept another request here.
      cancelConnection(id)
      return
    }
    switch connection.parser.append(data ?? Data(), isComplete: complete, failed: failed) {
    case .incomplete: receive(id)
    case .rejected:
      // Empty, fixed failure response: never echo the body, token, prompt, or parser error.
      respondOnQueue(id, status: 400, body: Data(), continuation: nil)
    case .complete(let request):
      connection.delivered = true
      // Bound actor dispatch/authentication time too, without using a sliding deadline.
      setDeadline(id, seconds: 5)
      receive(id)
      connection.dispatching = true
      let callback = onRequest
      Task { [weak self] in
        await callback(id, request)
        self?.queue.async { [weak self] in
          guard let self, let connection = self.connections[id] else { return }
          connection.dispatching = false
          self.releaseIfDrained(id)
        }
      }
    }
  }

  private func respondOnQueue(_ id: UUID, status: Int, body: Data,
    continuation: CheckedContinuation<Bool, Never>?) {
    guard !stopping, let connection = connections[id], !connection.cancelling,
      !connection.writing else { continuation?.resume(returning: false); return }
    connection.parser.discard()
    connection.writing = true
    connection.response = continuation
    setDeadline(id, seconds: 5)
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 401: reason = "Unauthorized"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    case 409: reason = "Conflict"
    default: reason = "Bad Request"
    }
    var response = Data(("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
      + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8)
    response.append(body)
    let transport = connection.transport
    transport.send(response) { [weak self, transport] succeeded in
      guard let self else { transport.cancel(); return }
      dispatchPrecondition(condition: .onQueue(self.queue))
      guard let connection = self.connections[id], connection.writing else { return }
      connection.writing = false
      let continuation = connection.response
      connection.response = nil
      continuation?.resume(returning: succeeded)
      self.cancelConnection(id)
      self.releaseIfDrained(id)
    }
  }

  private func setDeadline(_ id: UUID, seconds: TimeInterval) {
    guard let connection = connections[id] else { return }
    let token = UUID()
    connection.deadlineID = token
    connection.deadline?.cancel()
    connection.deadline = scheduler.schedule(after: seconds, queue: queue) { [weak self] in
      guard let self, self.connections[id]?.deadlineID == token else { return }
      self.cancelConnection(id)
    }
  }

  private func cancelConnection(_ id: UUID) {
    guard let connection = connections[id], !connection.cancelling else { return }
    connection.cancelling = true
    connection.parser.discard()
    connection.deadlineID = nil
    connection.deadline?.cancel()
    connection.deadline = nil
    let continuation = connection.response
    connection.response = nil
    continuation?.resume(returning: false)
    connection.transport.cancel()
    connection.notifyingClose = true
    let callback = onClose
    Task { [weak self] in
      await callback(id)
      self?.queue.async { [weak self] in
        guard let self, let connection = self.connections[id] else { return }
        connection.notifyingClose = false
        self.releaseIfDrained(id)
      }
    }
  }

  private func releaseIfDrained(_ id: UUID) {
    guard let connection = connections[id], connection.cancelled,
      !connection.reading, !connection.writing,
      !connection.dispatching, !connection.notifyingClose else { return }
    connections.removeValue(forKey: id)
    refillCredits()
    finishDrain()
  }

  private func refillCredits() {
    // Network decrements its counter asynchronously. Refill only when every issued
    // callback has arrived, and return slots only after cancellation AND I/O drain.
    guard !stopping, credits == 0, let listener else { return }
    credits = Self.maximumConnections - connections.count
    listener.newConnectionLimit = credits
  }

  private func terminate() {
    if !stopping {
      stopping = true
      startDeadline?.cancel()
      startDeadline = nil
      let continuation = startContinuation
      startContinuation = nil
      continuation?.resume(throwing: PromptGateTransportError.unavailable)
      listener?.newConnectionLimit = 0
      listener?.cancel()
      for id in Array(connections.keys) { cancelConnection(id) }
      onTermination()
    }
    finishDrain()
  }

  private func finishDrain() {
    guard stopping, listener == nil, connections.isEmpty else { return }
    let continuations = stopContinuations
    stopContinuations.removeAll()
    for continuation in continuations { continuation.resume() }
  }

  struct Snapshot: Sendable {
    let connections: Int
    let retainedBytes: Int
    let stopping: Bool
    let stopWaiters: Int
  }
  func snapshot() async -> Snapshot {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: Snapshot(connections: self.connections.count,
          retainedBytes: self.connections.values.reduce(0) { $0 + $1.parser.retainedBytes },
          stopping: self.stopping, stopWaiters: self.stopContinuations.count))
      }
    }
  }
}

enum PromptGateTransportError: Error { case unavailable }
enum PromptGateListenerState: Sendable { case ready, waiting, failed, cancelled }
enum PromptGateConnectionState: Sendable { case failed, cancelled }

// Events are asynchronous, exactly once, on the supplied serial queue. Cancelled is
// the final listener event; cancelled connections still complete every owned I/O.
protocol PromptGateListenerTransport: AnyObject, Sendable {
  var newConnectionLimit: Int { get set }
  var port: UInt16? { get }
  func start(queue: DispatchQueue,
    state: @escaping @Sendable (PromptGateListenerState) -> Void,
    connection: @escaping @Sendable (any PromptGateConnectionTransport) -> Void)
  func cancel()
}
protocol PromptGateConnectionTransport: AnyObject, Sendable {
  func start(queue: DispatchQueue, state: @escaping @Sendable (PromptGateConnectionState) -> Void)
  func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void)
  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void)
  func cancel()
}
protocol PromptGateDeadline: Sendable { func cancel() }
protocol PromptGateScheduling: Sendable {
  func schedule(after seconds: TimeInterval, queue: DispatchQueue,
    action: @escaping @Sendable () -> Void) -> any PromptGateDeadline
}

private final class PromptGateNetworkListener: PromptGateListenerTransport, @unchecked Sendable {
  private let listener: NWListener
  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    listener = try NWListener(using: parameters, on: .any)
  }
  var newConnectionLimit: Int {
    get { listener.newConnectionLimit }
    set { listener.newConnectionLimit = newValue }
  }
  var port: UInt16? { listener.port?.rawValue }
  func start(queue: DispatchQueue,
    state: @escaping @Sendable (PromptGateListenerState) -> Void,
    connection: @escaping @Sendable (any PromptGateConnectionTransport) -> Void) {
    listener.stateUpdateHandler = { value in
      switch value {
      case .ready: state(.ready)
      case .waiting: state(.waiting)
      case .failed: state(.failed)
      case .cancelled: state(.cancelled)
      default: break
      }
    }
    listener.newConnectionHandler = { connection(PromptGateNetworkConnection($0)) }
    listener.start(queue: queue)
  }
  func cancel() { listener.cancel() }
}
private final class PromptGateNetworkConnection: PromptGateConnectionTransport, @unchecked Sendable {
  private let connection: NWConnection
  init(_ connection: NWConnection) { self.connection = connection }
  func start(queue: DispatchQueue, state: @escaping @Sendable (PromptGateConnectionState) -> Void) {
    connection.stateUpdateHandler = { value in
      switch value {
      case .failed: state(.failed)
      case .cancelled: state(.cancelled)
      default: break
      }
    }
    connection.start(queue: queue)
  }
  func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
      completion(data, complete, error != nil)
    }
  }
  func send(_ data: Data, completion: @escaping @Sendable (Bool) -> Void) {
    connection.send(content: data, completion: .contentProcessed { error in completion(error == nil) })
  }
  func cancel() { connection.cancel() }
}
private struct PromptGateDispatchScheduler: PromptGateScheduling {
  func schedule(after seconds: TimeInterval, queue: DispatchQueue,
    action: @escaping @Sendable () -> Void) -> any PromptGateDeadline {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + seconds)
    timer.setEventHandler(handler: action)
    timer.resume()
    return PromptGateDispatchDeadline(timer: timer)
  }
}
private struct PromptGateDispatchDeadline: PromptGateDeadline, @unchecked Sendable {
  let timer: any DispatchSourceTimer
  func cancel() { timer.cancel() }
}
