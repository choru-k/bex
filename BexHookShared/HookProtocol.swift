import Foundation

enum PromptClient: String, Codable, CaseIterable, Identifiable, Sendable {
  case claudeCode = "claude"
  case codex
  case ohMyPi = "omp"

  var id: String { rawValue }
}

enum HookProtocolConstants {
  static let version = 1
  static let maximumMessageBytes = 1_048_576
  static let reviewPath = "/v1/review"
  static let acknowledgmentPath = "/v1/ack"
  static let rendezvousFileName = "rendezvous.json"
  static let helperName = "bex-hook"
  static let promptGateCapability = "prompt-gate-v1"
}

struct HookInput: Decodable, Sendable {
  let hookEventName: String
  let prompt: String
  let sessionID: String
  let cwd: String
  let promptID: String?
  let integrationID: String?
  let turnID: String?

  private enum CodingKeys: String, CodingKey {
    case hookEventName = "hook_event_name"
    case prompt
    case sessionID = "session_id"
    case cwd
    case promptID = "prompt_id"
    case turnID = "turn_id"
    case integrationID = "integration_id"
  }
}
struct OMPPromptGateInput: Decodable, Sendable {
  let version: Int
  let event: String
  let integrationID: String
  let text: String
  let images: [OMPImageMetadata]
  let sessionID: String
  let cwd: String
  let profile: String
  let source: String

  struct OMPImageMetadata: Decodable, Sendable {}

  private enum CodingKeys: String, CodingKey {
    case version
    case event
    case integrationID = "integration_id"
    case text
    case images
    case sessionID = "session_id"
    case cwd
    case profile
    case source
  }
}

enum OMPPromptGateFrame {
  static func allow(integrationID: String) throws -> Data {
    try encoded([
      "decision": "allow",
      "event": HookProtocolConstants.promptGateCapability,
      "integration_id": integrationID,
      "version": HookProtocolConstants.version,
    ])
  }

  static func block(integrationID: String, reason: String) throws -> Data {
    try encoded([
      "decision": "block",
      "event": HookProtocolConstants.promptGateCapability,
      "integration_id": integrationID,
      "reason": reason,
      "version": HookProtocolConstants.version,
    ])
  }

  static func stageApproved(
    integrationID: String,
    text: String,
    deliveryToken: String
  ) throws -> Data {
    try encoded([
      "delivery_token": deliveryToken,
      "event": "stage_approved",
      "integration_id": integrationID,
      "text": text,
      "version": HookProtocolConstants.version,
    ])
  }

  private static func encoded(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
  }
}


struct HookReviewRequest: Codable, Equatable, Sendable {
  let requestID: UUID
  let client: PromptClient
  let integrationID: String?
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
    integrationID: String? = nil,
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
    self.integrationID = integrationID
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
  let integrationID: String?
  let approvedPrompt: String?
  let deliveryToken: String?

  init(
    version: Int,
    outcome: HookReviewOutcome,
    acknowledgmentToken: String?,
    integrationID: String? = nil,
    approvedPrompt: String? = nil,
    deliveryToken: String? = nil
  ) {
    self.version = version
    self.outcome = outcome
    self.acknowledgmentToken = acknowledgmentToken
    self.integrationID = integrationID
    self.approvedPrompt = approvedPrompt
    self.deliveryToken = deliveryToken
  }
}

struct HookAcknowledgmentEnvelope: Codable, Sendable {
  let version: Int
  let authenticationToken: String
  let requestID: UUID
  let acknowledgmentToken: String
  let integrationID: String?
  let deliveryToken: String?
  let deliveryStatus: String?

  init(
    version: Int,
    authenticationToken: String,
    requestID: UUID,
    acknowledgmentToken: String,
    integrationID: String? = nil,
    deliveryToken: String? = nil,
    deliveryStatus: String? = nil
  ) {
    self.version = version
    self.authenticationToken = authenticationToken
    self.requestID = requestID
    self.acknowledgmentToken = acknowledgmentToken
    self.integrationID = integrationID
    self.deliveryToken = deliveryToken
    self.deliveryStatus = deliveryStatus
  }
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
    case .ohMyPi:
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
  let integrationID: String?

  init(version: Int, client: PromptClient, seenAt: Date, integrationID: String? = nil) {
    self.version = version
    self.client = client
    self.seenAt = seenAt
    self.integrationID = integrationID
  }
}
