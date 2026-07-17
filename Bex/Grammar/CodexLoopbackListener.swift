import Foundation
import Network

actor CodexLoopbackListener {
  private let port: NWEndpoint.Port
  private let timeoutNanoseconds: UInt64
  private let queue = DispatchQueue(label: "com.bex.desktop.codex-loopback")

  private var listener: NWListener?
  private var startContinuation: CheckedContinuation<Void, any Error>?
  private var callbackContinuation: CheckedContinuation<URL, any Error>?
  private var callbackURL: URL?
  private var timeoutTask: Task<Void, Never>?

  init(port: UInt16 = 1455, timeoutNanoseconds: UInt64 = 300_000_000_000) {
    self.port = NWEndpoint.Port(rawValue: port)!
    self.timeoutNanoseconds = timeoutNanoseconds
  }

  func start() async throws {
    guard listener == nil else { return }
    let listener: NWListener
    do {
      listener = try NWListener(using: .tcp, on: port)
    } catch {
      throw BexError.connectionFailure("OpenAI Codex callback port 1455 is unavailable.")
    }
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection) }
    }
    listener.stateUpdateHandler = { [weak self] state in
      Task { await self?.handle(state: state) }
    }

    try await withCheckedThrowingContinuation { continuation in
      startContinuation = continuation
      listener.start(queue: queue)
    }
  }

  func waitForCallback() async throws -> URL {
    if let callbackURL { return callbackURL }
    return try await withCheckedThrowingContinuation { continuation in
      callbackContinuation = continuation
      timeoutTask = Task { [weak self, timeoutNanoseconds] in
        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
        guard !Task.isCancelled else { return }
        await self?.timeOut()
      }
    }
  }

  func stop() {
    timeoutTask?.cancel()
    timeoutTask = nil
    listener?.cancel()
    listener = nil
    startContinuation?.resume(throwing: BexError.cancellation)
    startContinuation = nil
    callbackContinuation?.resume(throwing: BexError.cancellation)
    callbackContinuation = nil
  }

  private func handle(state: NWListener.State) {
    switch state {
    case .ready:
      startContinuation?.resume()
      startContinuation = nil
    case .waiting:
      if startContinuation != nil {
        failStart()
      }
    case .failed:
      failStart()
    case .cancelled:
      startContinuation?.resume(throwing: BexError.cancellation)
      startContinuation = nil
    default:
      break
    }
  }

  private func failStart() {
    startContinuation?.resume(
      throwing: BexError.connectionFailure(
        "OpenAI Codex callback port 1455 is unavailable."
      )
    )
    startContinuation = nil
    listener?.cancel()
    listener = nil
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    receive(on: connection, accumulated: Data())
  }

  private func receive(on connection: NWConnection, accumulated: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, error in
      var request = accumulated
      if let data { request.append(data) }
      let hasHeaders = request.range(of: Data("\r\n\r\n".utf8)) != nil
      if hasHeaders || isComplete || error != nil {
        Task { await self?.handleRequest(request, connection: connection) }
      } else {
        Task { await self?.receive(on: connection, accumulated: request) }
      }
    }
  }

  private func handleRequest(_ data: Data, connection: NWConnection) {
    guard let request = String(data: data, encoding: .utf8),
      let firstLine = request.components(separatedBy: "\r\n").first
    else {
      respond(status: "400 Bad Request", body: "Invalid callback", on: connection)
      return
    }
    let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2,
      parts[0] == "GET",
      let url = URL(string: "http://localhost:1455\(parts[1])"),
      url.path == "/auth/callback"
    else {
      respond(status: "404 Not Found", body: "Not found", on: connection)
      return
    }

    respond(
      status: "200 OK",
      body: "OpenAI Codex is connected. You can return to Bex.",
      on: connection
    )
    finish(with: url)
  }

  private func respond(status: String, body: String, on connection: NWConnection) {
    let bodyData = Data(body.utf8)
    let header = """
      HTTP/1.1 \(status)\r
      Content-Type: text/plain; charset=utf-8\r
      Content-Length: \(bodyData.count)\r
      Connection: close\r
      \r
      """
    var response = Data(header.utf8)
    response.append(bodyData)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private func finish(with url: URL) {
    guard callbackURL == nil else { return }
    callbackURL = url
    timeoutTask?.cancel()
    timeoutTask = nil
    listener?.cancel()
    listener = nil
    callbackContinuation?.resume(returning: url)
    callbackContinuation = nil
  }

  private func timeOut() {
    listener?.cancel()
    listener = nil
    callbackContinuation?.resume(throwing: BexError.timeout)
    callbackContinuation = nil
    timeoutTask = nil
  }
}
