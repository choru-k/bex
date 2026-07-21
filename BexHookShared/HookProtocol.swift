import Foundation

enum PromptClient: String, Codable, CaseIterable, Identifiable, Sendable {
  case claudeCode = "claude"
  case codex

  var id: String { rawValue }
}

enum HookProtocolConstants {
  static let version = 1
  static let maximumMessageBytes = 1_048_576
  static let reviewPath = "/v1/review"
  static let acknowledgmentPath = "/v1/ack"
  static let rendezvousFileName = "rendezvous.json"
  static let helperName = "bex-hook"
}

struct HookInput: Decodable, Sendable {
  let hookEventName: String
  let prompt: String
  let sessionID: String
  let cwd: String
  let promptID: String?
  let turnID: String?

  private enum CodingKeys: String, CodingKey {
    case hookEventName = "hook_event_name"
    case prompt
    case sessionID = "session_id"
    case cwd
    case promptID = "prompt_id"
    case turnID = "turn_id"
  }
}

struct HookReviewRequest: Codable, Equatable, Sendable {
  let requestID: UUID
  let client: PromptClient
  let prompt: String
  let sessionID: String
  let cwd: String
  let helperPID: Int32
  let promptID: String?
  let turnID: String?
  let sourcePID: Int32?
  let sourceBundleID: String?

  init(
    requestID: UUID = UUID(),
    client: PromptClient,
    prompt: String,
    sessionID: String,
    cwd: String,
    helperPID: Int32,
    promptID: String? = nil,
    turnID: String? = nil,
    sourcePID: Int32? = nil,
    sourceBundleID: String? = nil
  ) {
    self.requestID = requestID
    self.client = client
    self.prompt = prompt
    self.sessionID = sessionID
    self.cwd = cwd
    self.helperPID = helperPID
    self.promptID = promptID
    self.turnID = turnID
    self.sourcePID = sourcePID
    self.sourceBundleID = sourceBundleID
  }
}

enum HookReviewOutcome: String, Codable, Sendable {
  case approved
  case cancelled
  case failed
}

struct HookRendezvous: Codable, Sendable {
  let version: Int
  let port: UInt16
  let authenticationToken: String
  let serverPID: Int32
  let createdAt: Date
}

struct HookReviewEnvelope: Codable, Sendable {
  let version: Int
  let authenticationToken: String
  let request: HookReviewRequest
}

struct HookReviewResponseEnvelope: Codable, Sendable {
  let version: Int
  let outcome: HookReviewOutcome
  let acknowledgmentToken: String?
}

struct HookAcknowledgmentEnvelope: Codable, Sendable {
  let version: Int
  let authenticationToken: String
  let requestID: UUID
  let acknowledgmentToken: String
}

struct HookBlockOutput: Equatable, Sendable {
  let client: PromptClient
  let reason: String

  init(client: PromptClient, reason: String) {
    self.client = client
    self.reason = reason
  }

  func encoded() throws -> Data {
    let object: [String: Any]
    switch client {
    case .claudeCode:
      object = [
        "continue": false,
        "stopReason": reason,
      ]
    case .codex:
      object = [
        "decision": "block",
        "reason": reason,
      ]
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }
}

struct HookHeartbeat: Codable, Sendable {
  let version: Int
  let client: PromptClient
  let seenAt: Date
}
