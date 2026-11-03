import Foundation
import Network

/// All mutable state and transport callbacks are confined to `queue`. Admission runs
/// in the listener callback itself, not in an unbounded queue of actor-hop Tasks.
/// Keep the async service API: `stop()` is an actual callback/connection drain barrier.
final class CodexLoopbackListener: @unchecked Sendable {
  static let maximumConnections = 4
  static let maximumHeaderBytes = 16_384
  static let maximumReceiveBytes = 4_096

  private final class Connection {
    let transport: any CodexLoopbackConnectionTransport
    var headers = CodexLoopbackHeaders()
    var receiving = false
    var sending = false
    var cancelling = false
    var cancelled = false
    var deadline: (any CodexLoopbackDeadline)?
    var deadlineID: UUID?

    init(_ transport: any CodexLoopbackConnectionTransport) { self.transport = transport }
  }

  private let port: UInt16
  private let timeoutNanoseconds: UInt64
  private let queue = DispatchQueue(label: "com.bex.desktop.codex-loopback")
  private let makeTransport: @Sendable (UInt16) throws -> any CodexLoopbackListenerTransport
  private let scheduler: any CodexLoopbackScheduling
  private var listener: (any CodexLoopbackListenerTransport)?
  private var connections: [UUID: Connection] = [:]
  private var hasStarted = false
  private var admissionClosed = false
  private var stopped = false
  private var listenerCancelling = false
  private var outstandingConnectionCredits = 0
  private var startContinuation: CheckedContinuation<Void, any Error>?
  private var callbackContinuation: CheckedContinuation<URL, any Error>?
  private var stopContinuations: [CheckedContinuation<Void, Never>] = []
  private var callbackURL: URL?
  private var timeout: (any CodexLoopbackDeadline)?
  private var timeoutID: UUID?

  init(port: UInt16 = 1455, timeoutNanoseconds: UInt64 = 300_000_000_000) {
    self.port = port
    self.timeoutNanoseconds = min(max(timeoutNanoseconds, 1), 300_000_000_000)
    self.makeTransport = { try CodexNetworkLoopbackListener(port: $0) }
    self.scheduler = CodexDispatchLoopbackScheduler()
  }

  /// Internal synthetic transport seam; never opens a socket when fakes are supplied.
  init(
    port: UInt16 = 1455,
    timeoutNanoseconds: UInt64 = 300_000_000_000,
    makeTransport: @escaping @Sendable (UInt16) throws -> any CodexLoopbackListenerTransport,
    scheduler: any CodexLoopbackScheduling
  ) {
    self.port = port
    self.timeoutNanoseconds = min(max(timeoutNanoseconds, 1), 300_000_000_000)
    self.makeTransport = makeTransport
    self.scheduler = scheduler
  }

  deinit {
    // No callback holds this owner strongly. With its final reference gone, no
    // queue operation can still access its state. This is cancellation, not drain;
    // service owners must await stop() before replacing this lifetime.
    timeout?.cancel()
    listener?.cancel()
    for connection in connections.values {
      connection.deadline?.cancel()
      connection.transport.cancel()
    }
  }

  func start() async throws {
    try await withTaskCancellationHandler {
      guard !Task.isCancelled else { throw BexError.cancellation }
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        queue.async { self.startOnQueue(continuation) }
      }
    } onCancel: {
      self.queue.async { self.terminate(with: .cancellation) }
    }
  }

  func waitForCallback() async throws -> URL {
    try await withTaskCancellationHandler {
      guard !Task.isCancelled else { throw BexError.cancellation }
      return try await withCheckedThrowingContinuation { continuation in
        queue.async {
          guard !self.stopped else {
            continuation.resume(throwing: BexError.cancellation)
            return
          }
          if let url = self.callbackURL { continuation.resume(returning: url); return }
          guard self.callbackContinuation == nil else {
            continuation.resume(throwing:
              BexError.oauthFailure("OpenAI Codex callback already has a waiter."))
            return
          }
          self.callbackContinuation = continuation
          self.ensureTimeout()
        }
      }
    } onCancel: {
      self.queue.async { self.terminate(with: .cancellation) }
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      queue.async {
        self.stopContinuations.append(continuation)
        self.terminate(with: .cancellation)
      }
    }
  }

  private func startOnQueue(_ continuation: CheckedContinuation<Void, any Error>) {
    guard !stopped else { continuation.resume(throwing: BexError.cancellation); return }
    guard !hasStarted else {
      continuation.resume(throwing:
        BexError.oauthFailure("OpenAI Codex callback listener was already started."))
      return
    }
    hasStarted = true
    do {
      let transport = try makeTransport(port)
      listener = transport
      startContinuation = continuation
      outstandingConnectionCredits = Self.maximumConnections
      transport.newConnectionLimit = outstandingConnectionCredits
      // The adapter invokes both handlers directly on this same serial queue.
      transport.start(
        queue: queue,
        state: { [weak self] state in self?.handle(state) },
        connection: { [weak self] connection in
          guard let self else { connection.cancel(); return }
          self.accept(connection)
        })
      ensureTimeout()
    } catch {
      continuation.resume(throwing: connectionError)
      terminate(with: connectionError)
    }
  }

  private var connectionError: BexError {
    .connectionFailure("OpenAI Codex callback port \(port) is unavailable.")
  }

  private func handle(_ state: CodexLoopbackListenerState) {
    dispatchPrecondition(condition: .onQueue(queue))
    switch state {
    case .ready:
      guard !admissionClosed else { return }
      let continuation = startContinuation
      startContinuation = nil
      continuation?.resume()
    case .waiting:
      if startContinuation != nil { terminate(with: connectionError) }
    case .failed:
      if !admissionClosed { terminate(with: connectionError) }
    case .cancelled:
      listener = nil
      if !admissionClosed { terminate(with: .cancellation) }
      finishDrainIfPossible()
    }
  }

  private func accept(_ transport: any CodexLoopbackConnectionTransport) {
    dispatchPrecondition(condition: .onQueue(queue))
    // Finite delivery credits include callbacks already queued by Network.framework.
    // They are returned only after terminal state AND owned I/O callbacks complete.
    guard outstandingConnectionCredits > 0, connections.count < Self.maximumConnections else {
      transport.cancel() // Defensive rejection if an adapter violates its credits.
      terminate(with: connectionError)
      return
    }
    outstandingConnectionCredits -= 1
    let id = UUID()
    let connection = Connection(transport)
    connections[id] = connection
    transport.start(queue: queue) { [weak self] state in self?.handle(state, id: id) }
    if admissionClosed {
      cancelConnection(id)
      return
    }
    setConnectionDeadline(id, after: 10_000_000_000)
    receive(id)
    refillConnectionCredits()
  }

  private func handle(_ state: CodexLoopbackConnectionState, id: UUID) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection = connections[id] else { return }
    switch state {
    case .failed:
      cancelConnection(id)
    case .cancelled:
      connection.cancelled = true
      cancelConnection(id)
      releaseIfDrained(id)
    }
  }

  private func receive(_ id: UUID) {
    guard let connection = connections[id], !admissionClosed, !connection.cancelling else { return }
    connection.receiving = true
    let transport = connection.transport
    transport.receive(maximumLength: Self.maximumReceiveBytes) { [weak self, transport] data, complete, failed in
      guard let self else { transport.cancel(); return }
      self.received(data, complete: complete, failed: failed, id: id)
    }
  }

  private func received(_ data: Data?, complete: Bool, failed: Bool, id: UUID) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard let connection = connections[id], connection.receiving else { return }
    connection.receiving = false
    guard !admissionClosed, !connection.cancelling else { releaseIfDrained(id); return }
    // An error can accompany partial data. Never treat that partial request as valid.
    guard !failed else { cancelConnection(id); return }
    switch connection.headers.append(data ?? Data()) {
    case .tooLarge:
      respond(status: "431 Request Header Fields Too Large", body: "Invalid callback", id: id)
    case .incomplete:
      if complete || data?.isEmpty != false {
        respond(status: "400 Bad Request", body: "Invalid callback", id: id)
      } else {
        receive(id)
      }
    case .complete:
      switch connection.headers.request(port: port) {
      case .callback(let url):
        // Claim the first callback and close admission before sending or resuming.
        callbackURL = url
        closeAdmission()
        for otherID in Array(connections.keys) where otherID != id { cancelConnection(otherID) }
        respond(status: "200 OK", body: "Callback received. Return to Bex to finish sign-in.", id: id)
        let start = startContinuation
        startContinuation = nil
        let callback = callbackContinuation
        callbackContinuation = nil
        start?.resume()
        callback?.resume(returning: url)
      case .notFound:
        respond(status: "404 Not Found", body: "Not found", id: id)
      case .invalid:
        respond(status: "400 Bad Request", body: "Invalid callback", id: id)
      }
    }
  }

  private func respond(status: String, body: String, id: UUID) {
    guard let connection = connections[id], !connection.cancelling else { return }
    connection.headers = CodexLoopbackHeaders()
    setConnectionDeadline(id, after: 5_000_000_000)
    let response = Data(("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\n"
      + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)").utf8)
    connection.sending = true
    let transport = connection.transport
    transport.send(response) { [weak self, transport] in
      guard let self else { transport.cancel(); return }
      dispatchPrecondition(condition: .onQueue(self.queue))
      guard let connection = self.connections[id], connection.sending else { return }
      connection.sending = false
      self.cancelConnection(id)
      self.releaseIfDrained(id)
    }
  }

  private func setConnectionDeadline(_ id: UUID, after nanoseconds: UInt64) {
    guard let connection = connections[id] else { return }
    let token = UUID()
    connection.deadlineID = token
    connection.deadline?.cancel()
    connection.deadline = scheduler.schedule(after: nanoseconds, queue: queue) { [weak self] in
      guard let self, self.connections[id]?.deadlineID == token else { return }
      self.cancelConnection(id)
    }
  }

  private func cancelConnection(_ id: UUID) {
    guard let connection = connections[id], !connection.cancelling else { return }
    connection.cancelling = true
    connection.headers = CodexLoopbackHeaders()
    connection.deadlineID = nil
    connection.deadline?.cancel()
    connection.deadline = nil
    connection.transport.cancel()
  }

  private func releaseIfDrained(_ id: UUID) {
    guard let connection = connections[id], connection.cancelled,
      !connection.receiving, !connection.sending else { return }
    connections.removeValue(forKey: id)
    refillConnectionCredits()
    finishDrainIfPossible()
  }

  private func refillConnectionCredits() {
    // Never read/modify/write Network's asynchronously decremented credit counter.
    // Issue a fresh batch only after every previously issued credit was delivered.
    guard !admissionClosed, outstandingConnectionCredits == 0, let listener else { return }
    outstandingConnectionCredits = Self.maximumConnections - connections.count
    listener.newConnectionLimit = outstandingConnectionCredits
  }

  private func ensureTimeout() {
    guard timeout == nil, !admissionClosed else { return }
    // Starts at startup (or an earlier wait), not only after a caller installs a waiter.
    let token = UUID()
    timeoutID = token
    timeout = scheduler.schedule(after: timeoutNanoseconds, queue: queue) { [weak self] in
      guard let self, self.timeoutID == token else { return }
      self.terminate(with: .timeout)
    }
  }

  private func closeAdmission() {
    admissionClosed = true
    timeoutID = nil
    timeout?.cancel()
    timeout = nil
    if !listenerCancelling {
      listenerCancelling = true
      listener?.newConnectionLimit = 0
      listener?.cancel()
    }
  }

  private func terminate(with error: BexError) {
    stopped = true
    closeAdmission()
    let start = startContinuation
    startContinuation = nil
    let callback = callbackContinuation
    callbackContinuation = nil
    for id in Array(connections.keys) { cancelConnection(id) }
    start?.resume(throwing: error)
    callback?.resume(throwing: error)
    finishDrainIfPossible()
  }

  private func finishDrainIfPossible() {
    guard admissionClosed, listener == nil, connections.isEmpty else { return }
    let continuations = stopContinuations
    stopContinuations.removeAll()
    for continuation in continuations { continuation.resume() }
  }

  /// Queue barrier and bounded ownership diagnostics for socket-free synthetic tests.
  struct Snapshot: Sendable {
    let connections: Int
    let stoppingConnections: Int
    let retainedHeaderBytes: Int
    let stopWaiters: Int
    let admissionClosed: Bool
    let listenerPending: Bool
    let callbackWaiting: Bool
  }

  func snapshot() async -> Snapshot {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: Snapshot(
          connections: self.connections.count,
          stoppingConnections: self.connections.values.filter(\.cancelling).count,
          retainedHeaderBytes: self.connections.values.reduce(0) { $0 + $1.headers.count },
          stopWaiters: self.stopContinuations.count,
          admissionClosed: self.admissionClosed,
          listenerPending: self.listener != nil,
          callbackWaiting: self.callbackContinuation != nil))
      }
    }
  }
}

/// Retains only the header prefix, never a whole accumulated body or pipelined request.
/// Delivered chunks are independently capped before iteration/copy; each byte is
/// budget-checked BEFORE append. The delimiter counts toward the retained 16 KiB cap.
struct CodexLoopbackHeaders {
  enum Progress: Equatable { case incomplete, complete, tooLarge }
  enum Request { case callback(URL), notFound, invalid }
  private var bytes = Data()
  private var matched = 0
  private var progress = Progress.incomplete
  var count: Int { bytes.count }

  mutating func append(_ chunk: Data) -> Progress {
    guard progress == .incomplete else { return progress }
    guard chunk.count <= CodexLoopbackListener.maximumReceiveBytes else { return reject() }
    for byte in chunk {
      guard bytes.count < CodexLoopbackListener.maximumHeaderBytes else { return reject() }
      bytes.append(byte)
      switch (matched, byte) {
      case (0, 13), (1, 13), (3, 13): matched = 1
      case (1, 10): matched = 2
      case (2, 13): matched = 3
      case (3, 10): progress = .complete; return progress
      default: matched = 0
      }
    }
    // At the exact cap with no terminator, another byte can never make it valid.
    if bytes.count == CodexLoopbackListener.maximumHeaderBytes { return reject() }
    return .incomplete
  }

  private mutating func reject() -> Progress {
    bytes = Data()
    progress = .tooLarge
    return progress
  }

  func request(port: UInt16) -> Request {
    guard progress == .complete, let header = String(data: bytes, encoding: .utf8) else { return .invalid }
    let lines = header.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .invalid }
    var host: String?
    for line in lines.dropFirst().dropLast(2) {
      guard let colon = line.firstIndex(of: ":") else { return .invalid }
      let name = line[..<colon]
      let token = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
      guard !name.isEmpty, name.utf8.allSatisfy({ token.utf8.contains($0) }) else { return .invalid }
      let rawValue = line[line.index(after: colon)...]
      guard rawValue.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return .invalid }
      let value = rawValue.trimmingCharacters(in: .whitespaces)
      switch name.lowercased() {
      case "host":
        guard host == nil else { return .invalid }
        host = value.lowercased()
      case "content-length":
        guard value == "0" else { return .invalid }
      case "transfer-encoding": return .invalid
      default: break
      }
    }
    if parts[2] == "HTTP/1.1" || host != nil {
      guard let host, ["localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"].contains(host)
      else { return .invalid }
    }
    let target = String(parts[1])
    guard target.hasPrefix("/"), !target.hasPrefix("//"),
      target.utf8.allSatisfy({ (33...126).contains($0) && $0 != 35 && $0 != 92 }),
      let components = URLComponents(string: "http://localhost:\(port)\(target)"),
      components.host == "localhost", components.port == Int(port),
      components.user == nil, components.password == nil, components.fragment == nil,
      let url = components.url
    else { return .invalid }
    guard parts[0] == "GET", components.percentEncodedPath == "/auth/callback" else { return .notFound }
    return .callback(url)
  }
}

// Internal transport contract: every event/completion is invoked exactly once for
// its operation, asynchronously on the supplied serial queue. Listener cancellation
// is the final listener event. Connection cancellation still delivers all owned I/O
// completions; their order relative to the cancelled state is deliberately unspecified.
enum CodexLoopbackListenerState: Sendable { case ready, waiting, failed, cancelled }
enum CodexLoopbackConnectionState: Sendable { case failed, cancelled }
protocol CodexLoopbackListenerTransport: AnyObject, Sendable {
  var newConnectionLimit: Int { get set }
  func start(queue: DispatchQueue,
    state: @escaping @Sendable (CodexLoopbackListenerState) -> Void,
    connection: @escaping @Sendable (any CodexLoopbackConnectionTransport) -> Void)
  func cancel()
}
protocol CodexLoopbackConnectionTransport: AnyObject, Sendable {
  func start(queue: DispatchQueue, state: @escaping @Sendable (CodexLoopbackConnectionState) -> Void)
  func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Bool) -> Void)
  func send(_ data: Data, completion: @escaping @Sendable () -> Void)
  func cancel()
}
protocol CodexLoopbackDeadline: Sendable { func cancel() }
protocol CodexLoopbackScheduling: Sendable {
  func schedule(after nanoseconds: UInt64, queue: DispatchQueue,
    action: @escaping @Sendable () -> Void) -> any CodexLoopbackDeadline
}

private final class CodexNetworkLoopbackListener: CodexLoopbackListenerTransport, @unchecked Sendable {
  private let listener: NWListener
  init(port: UInt16) throws {
    let parameters = NWParameters.tcp
    // Restrict the interface, not an IPv4-only address; keep the registered localhost URI.
    parameters.requiredInterfaceType = .loopback
    listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
  }
  var newConnectionLimit: Int {
    get { listener.newConnectionLimit }
    set { listener.newConnectionLimit = newValue }
  }
  func start(queue: DispatchQueue,
    state: @escaping @Sendable (CodexLoopbackListenerState) -> Void,
    connection: @escaping @Sendable (any CodexLoopbackConnectionTransport) -> Void) {
    listener.stateUpdateHandler = { value in
      switch value {
      case .ready: state(.ready)
      case .waiting: state(.waiting)
      case .failed: state(.failed)
      case .cancelled: state(.cancelled)
      default: break
      }
    }
    listener.newConnectionHandler = { connection(CodexNetworkLoopbackConnection($0)) }
    listener.start(queue: queue)
  }
  func cancel() { listener.cancel() }
}

private final class CodexNetworkLoopbackConnection: CodexLoopbackConnectionTransport, @unchecked Sendable {
  private let connection: NWConnection
  init(_ connection: NWConnection) { self.connection = connection }
  func start(queue: DispatchQueue, state: @escaping @Sendable (CodexLoopbackConnectionState) -> Void) {
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
  func send(_ data: Data, completion: @escaping @Sendable () -> Void) {
    connection.send(content: data, completion: .contentProcessed { _ in completion() })
  }
  func cancel() { connection.cancel() }
}

private struct CodexDispatchLoopbackScheduler: CodexLoopbackScheduling {
  func schedule(after nanoseconds: UInt64, queue: DispatchQueue,
    action: @escaping @Sendable () -> Void) -> any CodexLoopbackDeadline {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max)))))
    timer.setEventHandler(handler: action)
    timer.resume()
    return CodexDispatchLoopbackDeadline(timer: timer)
  }
}
private struct CodexDispatchLoopbackDeadline: CodexLoopbackDeadline, @unchecked Sendable {
  let timer: any DispatchSourceTimer
  func cancel() { timer.cancel() }
}
