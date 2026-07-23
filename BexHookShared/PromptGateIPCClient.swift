import AppKit
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

enum HookIPCError: LocalizedError, Equatable, Sendable {
  case unavailable
  case invalidRendezvous
  case invalidResponse
  case messageTooLarge

  var errorDescription: String? {
    switch self {
    case .unavailable: "Bex Prompt Gate is unavailable."
    case .invalidRendezvous: "Bex Prompt Gate rendezvous is invalid."
    case .invalidResponse: "Bex Prompt Gate returned an invalid response."
    case .messageTooLarge: "The prompt is too large for Bex Prompt Gate."
    }
  }
}

struct PromptGateIPCClient: Sendable {
  private let rendezvousURL: URL
  private let session: URLSession
  private let now: @Sendable () -> Date

  init(
    rendezvousURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/PromptGate")
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName),
    session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.rendezvousURL = rendezvousURL
    self.session = session
    self.now = now
  }

  func submit(_ request: HookReviewRequest) async throws -> HookReviewResponseEnvelope {
    let payloadSize = request.prompt.utf8.count
    guard payloadSize <= HookProtocolConstants.maximumMessageBytes else {
      throw HookIPCError.messageTooLarge
    }

    if let rendezvous = try? loadRendezvous(),
      let response = try? await sendReview(request, rendezvous: rendezvous)
    {
      return response
    }

    try wakeBex()
    let deadline = now().addingTimeInterval(5)
    var lastRendezvousDate: Date?
    while now() < deadline {
      if let rendezvous = try? loadRendezvous(),
        rendezvous.createdAt != lastRendezvousDate
      {
        lastRendezvousDate = rendezvous.createdAt
        if let response = try? await sendReview(request, rendezvous: rendezvous) {
          return response
        }
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw HookIPCError.unavailable
  }

  func acknowledge(
    requestID: UUID,
    token: String,
    integrationID: String? = nil,
    deliveryToken: String? = nil,
    deliveryStatus: String? = nil,
    rendezvous: HookRendezvous? = nil
  ) async throws {
    let rendezvous = try rendezvous ?? loadRendezvous()
    let envelope = HookAcknowledgmentEnvelope(
      version: HookProtocolConstants.version,
      authenticationToken: rendezvous.authenticationToken,
      requestID: requestID,
      acknowledgmentToken: token,
      integrationID: integrationID,
      deliveryToken: deliveryToken,
      deliveryStatus: deliveryStatus
    )
    var request = try urlRequest(
      path: HookProtocolConstants.acknowledgmentPath,
      rendezvous: rendezvous,
      body: JSONEncoder().encode(envelope),
      timeout: 5
    )
    request.httpMethod = "POST"
    let (_, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
      throw HookIPCError.invalidResponse
    }
  }

  func loadRendezvous() throws -> HookRendezvous {
    let data = try Data(contentsOf: rendezvousURL)
    guard data.count <= 64 * 1024,
      let value = try? JSONDecoder().decode(HookRendezvous.self, from: data),
      value.version == HookProtocolConstants.version,
      !value.authenticationToken.isEmpty,
      value.port > 0
    else {
      throw HookIPCError.invalidRendezvous
    }
    return value
  }

  private func sendReview(
    _ review: HookReviewRequest,
    rendezvous: HookRendezvous
  ) async throws -> HookReviewResponseEnvelope {
    let envelope = HookReviewEnvelope(
      version: HookProtocolConstants.version,
      authenticationToken: rendezvous.authenticationToken,
      request: review
    )
    let body = try JSONEncoder().encode(envelope)
    guard body.count <= HookProtocolConstants.maximumMessageBytes else {
      throw HookIPCError.messageTooLarge
    }
    var request = try urlRequest(
      path: HookProtocolConstants.reviewPath,
      rendezvous: rendezvous,
      body: body,
      timeout: 3_540
    )
    request.httpMethod = "POST"
    let (data, response) = try await session.data(for: request)
    guard data.count <= HookProtocolConstants.maximumMessageBytes,
      let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      let envelope = try? JSONDecoder().decode(HookReviewResponseEnvelope.self, from: data),
      envelope.version == HookProtocolConstants.version
    else {
      throw HookIPCError.invalidResponse
    }
    return envelope
  }

  private func urlRequest(
    path: String,
    rendezvous: HookRendezvous,
    body: Data,
    timeout: TimeInterval
  ) throws -> URLRequest {
    guard let url = URL(string: "http://127.0.0.1:\(rendezvous.port)\(path)") else {
      throw HookIPCError.invalidRendezvous
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    return request
  }

  private func wakeBex() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-gj", "-b", "com.bex.desktop"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HookIPCError.unavailable
    }
  }
}
