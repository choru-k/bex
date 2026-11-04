import Foundation

/// No caller-supplied paths, process IDs, selectors, keystrokes or replacement text.
@objc(BexAccessibilityAgentProtocolV1)
protocol AccessibilityAgentProtocol {
  func exchange(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

enum AccessibilityAgentContract {
  static let version = 1
  static let runtimeRevision = 1
  static let serviceName = "com.bex.accessibility.agent"
  static let helperIdentifier = "com.bex.accessibility"
  static let appIdentifier = "com.bex.desktop"
  static let teamIdentifier = "ESURPGU29C"
  static let maximumMessageBytes = 524_288
  static let maximumDraftBytes = 262_144
  static let maximumConnections = 4
  static let maximumPendingRequests = 8
  static let maximumCaptures = 64
  static let captureLifetime: TimeInterval = 3_600
}

/// One monotonic budget is shared by queue admission, capture and its final revalidation.
/// AX messages have a separate 0.5-second timeout; local framework work is not real-time.
struct AccessibilityObservationDeadline: Sendable {
  let end: UInt64
  init(end: UInt64 = DispatchTime.now().uptimeNanoseconds + 3_000_000_000) { self.end = end }
  func check() throws {
    guard DispatchTime.now().uptimeNanoseconds < end else { throw AccessibilityAgentFailure.timeout }
  }
}

enum AccessibilityAgentOperation: String, Codable, Sendable {
  case hello, status, capture, validate, consume, discard
}

struct AccessibilityAgentRequest: Codable, Sendable {
  let version: Int
  let id: UUID
  let operation: AccessibilityAgentOperation
  let session: UUID?
  let challenge: UUID?
  let capture: UUID?

  init(operation: AccessibilityAgentOperation, session: UUID? = nil, challenge: UUID? = nil, capture: UUID? = nil) {
    version = AccessibilityAgentContract.version
    id = UUID()
    self.operation = operation
    self.session = session
    self.challenge = challenge
    self.capture = capture
  }

  var hasValidShape: Bool {
    guard version == AccessibilityAgentContract.version else { return false }
    switch operation {
    case .hello: return session == nil && challenge != nil && capture == nil
    case .status, .capture: return session != nil && challenge == nil && capture == nil
    case .validate, .consume, .discard: return session != nil && challenge == nil && capture != nil
    }
  }
}

struct AccessibilityAgentCapture: Codable, Equatable, Sendable {
  let token: UUID
  let processID: Int32
  let bundleIdentifier: String
  let applicationName: String
  let launchDate: Date
  let original: String
}

struct AccessibilityAgentResponse: Codable, Sendable {
  let version: Int
  let runtimeRevision: Int
  let requestID: UUID
  let session: UUID?
  let challenge: UUID?
  let trusted: Bool?
  let captured: AccessibilityAgentCapture?
  let failure: AccessibilityAgentFailure?

  init(requestID: UUID, session: UUID? = nil, challenge: UUID? = nil, trusted: Bool? = nil,
       captured: AccessibilityAgentCapture? = nil, failure: AccessibilityAgentFailure? = nil) {
    version = AccessibilityAgentContract.version
    runtimeRevision = AccessibilityAgentContract.runtimeRevision
    self.requestID = requestID
    self.session = session
    self.challenge = challenge
    self.trusted = trusted
    self.captured = captured
    self.failure = failure
  }
}

enum AccessibilityAgentFailure: String, Error, Codable, Sendable {
  case unavailable, incompatible, unauthorized, malformed, capacity, untrusted, unsupported, stale, cancelled, timeout
}

enum AccessibilityAgentCodec {
  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let data = try JSONEncoder().encode(value)
    guard data.count <= AccessibilityAgentContract.maximumMessageBytes else { throw AccessibilityAgentFailure.capacity }
    return data
  }

  static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    guard !data.isEmpty, data.count <= AccessibilityAgentContract.maximumMessageBytes else {
      throw AccessibilityAgentFailure.malformed
    }
    return try JSONDecoder().decode(type, from: data)
  }
}
