@preconcurrency import Network
import Darwin
import Foundation

private final class PromptHTTPReader: @unchecked Sendable {
  private let connection: NWConnection
  private let maximumBytes: Int
  private let completion: @Sendable (Result<(String, Data), Error>) -> Void
  private var buffer = Data()
  private var completed = false

  init(
    connection: NWConnection,
    maximumBytes: Int,
    completion: @escaping @Sendable (Result<(String, Data), Error>) -> Void
  ) {
    self.connection = connection
    self.maximumBytes = maximumBytes
    self.completion = completion
  }

  func start() {
    receive()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      guard let self, !completed else { return }
      if let data {
        buffer.append(data)
      }
      if buffer.count > maximumBytes + 64 * 1024 {
        finish(.failure(HookIPCError.messageTooLarge))
        return
      }
      if let request = parseRequest() {
        finish(.success(request))
        return
      }
      if let error {
        finish(.failure(error))
      } else if isComplete {
        finish(.failure(HookIPCError.invalidResponse))
      } else {
        receive()
      }
    }
  }

  private func parseRequest() -> (String, Data)? {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = buffer.range(of: separator) else { return nil }
    let headerData = buffer[..<headerRange.lowerBound]
    guard let header = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = header.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "POST" else { return nil }
    let contentLength = lines.dropFirst().compactMap { line -> Int? in
      let pair = line.split(separator: ":", maxSplits: 1)
      guard pair.count == 2,
        pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
      else {
        return nil
      }
      return Int(pair[1].trimmingCharacters(in: .whitespaces))
    }.first ?? 0
    guard contentLength <= maximumBytes else { return nil }
    let bodyStart = headerRange.upperBound
    guard buffer.count >= bodyStart + contentLength else { return nil }
    return (String(parts[1]), buffer.subdata(in: bodyStart..<(bodyStart + contentLength)))
  }

  private func finish(_ result: Result<(String, Data), Error>) {
    guard !completed else { return }
    completed = true
    completion(result)
  }
}

actor PromptGateIPCServer: PromptGateIPCServicing, HookReviewResponding {
  private struct Pending {
    let request: HookReviewRequest
    let connection: NWConnection
    let connectionID: UUID
    var waitingForAcknowledgment: Bool
    var acknowledgmentToken: String?
    var approvedPrompt: String?
    var deliveryToken: String?
    var acknowledgmentContinuation: CheckedContinuation<Void, Error>?
    var deadline: Task<Void, Never>?
  }

  private let rendezvousURL: URL
  private let queue = DispatchQueue(label: "com.bex.desktop.prompt-gate-ipc")
  private let deadlineSeconds: TimeInterval
  private var listener: NWListener?
  private var authenticationToken = ""
  private var pending: Pending?
  private var readers: [UUID: PromptHTTPReader] = [:]
  private var onRequest: (@Sendable (HookReviewRequest) async -> Bool)?
  private var onInvalidation: (@Sendable (UUID) async -> Void)?

  init(
    rendezvousURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/PromptGate", isDirectory: true)
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName),
    deadlineSeconds: TimeInterval = 3_500
  ) {
    self.rendezvousURL = rendezvousURL
    self.deadlineSeconds = deadlineSeconds
  }

  func setHandlers(
    onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
    onInvalidation: @escaping @Sendable (UUID) async -> Void
  ) {
    self.onRequest = onRequest
    self.onInvalidation = onInvalidation
  }

  func start() async throws {
    guard listener == nil else { return }
    authenticationToken = Self.randomToken()
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection) }
    }
    self.listener = listener

    let port: UInt16
    do {
      port = try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready:
            guard let port = listener.port?.rawValue, port != 0 else {
              listener.stateUpdateHandler = nil
              continuation.resume(
                throwing: BexError.promptDeliveryFailed("Bex could not start Prompt Gate IPC.")
              )
              return
            }
            listener.stateUpdateHandler = nil
            continuation.resume(returning: port)
          case .failed(let error):
            listener.stateUpdateHandler = nil
            continuation.resume(throwing: error)
          case .cancelled:
            listener.stateUpdateHandler = nil
            continuation.resume(
              throwing: BexError.promptDeliveryFailed("Bex could not start Prompt Gate IPC.")
            )
          default:
            break
          }
        }
        listener.start(queue: queue)
      }
    } catch {
      listener.cancel()
      self.listener = nil
      throw BexError.promptDeliveryFailed("Bex could not start Prompt Gate IPC.")
    }
    try writeRendezvous(port: port)
  }

  func stop() async {
    if let pending {
      pending.deadline?.cancel()
      pending.acknowledgmentContinuation?.resume(
        throwing: BexError.promptDeliveryFailed("Bex Prompt Gate stopped.")
      )
      await sendReviewResponse(.failed, token: nil, connection: pending.connection)
      pending.connection.cancel()
      await onInvalidation?(pending.request.requestID)
    }
    pending = nil
    for reader in readers.values {
      _ = reader
    }
    readers.removeAll()
    listener?.cancel()
    listener = nil
    try? FileManager.default.removeItem(at: rendezvousURL)
  }

  func complete(
    requestID: UUID,
    outcome: HookReviewOutcome,
    awaitAcknowledgement: Bool,
    approvedPrompt: String?,
    integrationID: String?
  ) async throws {
    guard var current = pending, current.request.requestID == requestID else {
      throw BexError.promptDeliveryFailed("The Prompt Gate helper disconnected.")
    }
    current.deadline?.cancel()

    guard outcome == .approved, awaitAcknowledgement else {
      pending = nil
      await sendReviewResponse(outcome, token: nil, connection: current.connection)
      current.connection.cancel()
      return
    }

    if current.request.client == .ohMyPi {
      guard
        let approvedPrompt,
        !approvedPrompt.isEmpty,
        let integrationID,
        integrationID == current.request.integrationID
      else {
        throw BexError.promptDeliveryFailed("The OMP approval identity is invalid.")
      }
      current.approvedPrompt = approvedPrompt
      current.deliveryToken = Self.randomToken()
    }
    let acknowledgmentToken = Self.randomToken()
    current.waitingForAcknowledgment = true
    current.acknowledgmentToken = acknowledgmentToken
    pending = current

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      guard var pending = self.pending, pending.request.requestID == requestID else {
        continuation.resume(throwing: BexError.promptDeliveryFailed("The Prompt Gate helper disconnected."))
        return
      }
      pending.acknowledgmentContinuation = continuation
      self.pending = pending
      Task { [weak self] in
        await self?.publishApproval(
          requestID: requestID,
          token: acknowledgmentToken
        )
      }
    }

    let exitDeadline = Date().addingTimeInterval(2)
    while Self.processIsAlive(current.request.helperPID), Date() < exitDeadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    guard !Self.processIsAlive(current.request.helperPID) else {
      pending = nil
      throw BexError.promptDeliveryFailed("The Prompt Gate helper did not exit safely.")
    }
    try await Task.sleep(for: .milliseconds(150))
    pending = nil
  }

  private func publishApproval(requestID: UUID, token: String) async {
    guard let current = pending, current.request.requestID == requestID else { return }
    await sendReviewResponse(
      .approved,
      token: token,
      connection: current.connection,
      request: current.request,
      approvedPrompt: current.approvedPrompt,
      deliveryToken: current.deliveryToken
    )
    current.connection.cancel()
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      await self?.acknowledgmentTimedOut(requestID: requestID)
    }
  }

  private func accept(_ connection: NWConnection) {
    let connectionID = UUID()
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        Task { await self?.connectionClosed(id: connectionID) }
      default:
        break
      }
    }
    connection.start(queue: queue)
    let reader = PromptHTTPReader(
      connection: connection,
      maximumBytes: HookProtocolConstants.maximumMessageBytes
    ) { [weak self] result in
      Task { await self?.received(result, connection: connection, id: connectionID) }
    }
    readers[connectionID] = reader
    reader.start()
  }

  private func received(
    _ result: Result<(String, Data), Error>,
    connection: NWConnection,
    id: UUID
  ) async {
    readers.removeValue(forKey: id)
    guard case .success(let request) = result else {
      await sendHTTP(status: 400, body: Data(), connection: connection)
      connection.cancel()
      return
    }
    switch request.0 {
    case HookProtocolConstants.reviewPath:
      await receiveReview(request.1, connection: connection, id: id)
    case HookProtocolConstants.acknowledgmentPath:
      await receiveAcknowledgment(request.1, connection: connection)
    default:
      await sendHTTP(status: 404, body: Data(), connection: connection)
      connection.cancel()
    }
  }

  private func receiveReview(_ data: Data, connection: NWConnection, id: UUID) async {
    guard
      let envelope = try? JSONDecoder().decode(HookReviewEnvelope.self, from: data),
      envelope.version == HookProtocolConstants.version
    else {
      await sendHTTP(status: 400, body: Data(), connection: connection)
      connection.cancel()
      return
    }
    guard envelope.authenticationToken == authenticationToken else {
      await sendHTTP(status: 401, body: Data(), connection: connection)
      connection.cancel()
      return
    }
    guard pending == nil, let onRequest else {
      await sendReviewResponse(.failed, token: nil, connection: connection)
      connection.cancel()
      return
    }

    pending = Pending(
      request: envelope.request,
      connection: connection,
      connectionID: id,
      waitingForAcknowledgment: false,
      acknowledgmentToken: nil,
      approvedPrompt: nil,
      deliveryToken: nil,
      acknowledgmentContinuation: nil,
      deadline: nil
    )
    guard await onRequest(envelope.request), var current = pending,
      current.request.requestID == envelope.request.requestID
    else {
      pending = nil
      await sendReviewResponse(.failed, token: nil, connection: connection)
      connection.cancel()
      return
    }
    let requestDeadlineSeconds = deadlineSeconds
    current.deadline = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(requestDeadlineSeconds))
      } catch {
        return
      }
      await self?.reviewTimedOut(requestID: envelope.request.requestID)
    }
    pending = current
  }

  private func receiveAcknowledgment(_ data: Data, connection: NWConnection) async {
    guard
      let envelope = try? JSONDecoder().decode(HookAcknowledgmentEnvelope.self, from: data),
      envelope.version == HookProtocolConstants.version,
      envelope.authenticationToken == authenticationToken
    else {
      await sendHTTP(status: 401, body: Data(), connection: connection)
      connection.cancel()
      return
    }
    guard var current = pending, current.request.requestID == envelope.requestID else {
      await sendHTTP(status: 409, body: Data(), connection: connection)
      connection.cancel()
      return
    }
    if current.request.client == .ohMyPi {
      guard
        envelope.integrationID == current.request.integrationID,
        envelope.deliveryToken == current.deliveryToken,
        envelope.deliveryStatus == "delivered"
      else {
        await sendHTTP(status: 403, body: Data(), connection: connection)
        connection.cancel()
        return
      }
    }
    guard
      current.acknowledgmentToken == envelope.acknowledgmentToken,
      let continuation = current.acknowledgmentContinuation
    else {
      await sendHTTP(status: 403, body: Data(), connection: connection)
      connection.cancel()
      return
    }
    current.acknowledgmentContinuation = nil
    pending = current
    await sendHTTP(status: 200, body: Data(), connection: connection)
    connection.cancel()
    continuation.resume()
  }

  private func connectionClosed(id: UUID) async {
    readers.removeValue(forKey: id)
    guard let current = pending,
      current.connectionID == id,
      !current.waitingForAcknowledgment
    else {
      return
    }
    current.deadline?.cancel()
    pending = nil
    await onInvalidation?(current.request.requestID)
  }

  private func reviewTimedOut(requestID: UUID) async {
    guard let current = pending, current.request.requestID == requestID else { return }
    pending = nil
    await sendReviewResponse(.failed, token: nil, connection: current.connection)
    current.connection.cancel()
    await onInvalidation?(requestID)
  }

  private func acknowledgmentTimedOut(requestID: UUID) {
    guard var current = pending,
      current.request.requestID == requestID,
      let continuation = current.acknowledgmentContinuation
    else {
      return
    }
    current.acknowledgmentContinuation = nil
    pending = current
    continuation.resume(
      throwing: BexError.promptDeliveryFailed("The Prompt Gate helper did not acknowledge the block.")
    )
  }

  private func sendReviewResponse(
    _ outcome: HookReviewOutcome,
    token: String?,
    connection: NWConnection,
    request: HookReviewRequest? = nil,
    approvedPrompt: String? = nil,
    deliveryToken: String? = nil
  ) async {
    let envelope = HookReviewResponseEnvelope(
      version: HookProtocolConstants.version,
      outcome: outcome,
      acknowledgmentToken: token,
      integrationID: request?.integrationID,
      approvedPrompt: approvedPrompt,
      deliveryToken: deliveryToken
    )
    let body = (try? JSONEncoder().encode(envelope)) ?? Data()
    await sendHTTP(status: 200, body: body, connection: connection)
  }

  private func sendHTTP(status: Int, body: Data, connection: NWConnection) async {
    let reason = status == 200 ? "OK" : status == 403 ? "Forbidden" : "Bad Request"
    var data = Data(
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
    )
    data.append(body)
    await withCheckedContinuation { continuation in
      connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
    }
  }

  private func writeRendezvous(port: UInt16) throws {
    let directory = rendezvousURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    let value = HookRendezvous(
      version: HookProtocolConstants.version,
      port: port,
      authenticationToken: authenticationToken,
      serverPID: ProcessInfo.processInfo.processIdentifier,
      createdAt: Date()
    )
    let data = try JSONEncoder().encode(value)
    let temporary = directory.appendingPathComponent(".rendezvous-\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .withoutOverwriting)
    chmod(temporary.path, 0o600)
    if rename(temporary.path, rendezvousURL.path) != 0 {
      try? FileManager.default.removeItem(at: temporary)
      throw BexError.promptDeliveryFailed("Bex could not publish Prompt Gate IPC.")
    }
  }

  private static func randomToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private static func processIsAlive(_ processID: Int32) -> Bool {
    kill(processID, 0) == 0 || errno == EPERM
  }
}
