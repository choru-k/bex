import Foundation

extension PromptClient {
  var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    }
  }
}

enum PromptDeliveryMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case pasteOnly = "paste-only"
  case sendAfterApproval = "send-after-approval"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .pasteOnly: "Paste only"
    case .sendAfterApproval: "Send after approval"
    }
  }
}

enum PromptDeliveryOutcome: Equatable, Sendable {
  case copied
  case pasted
  case submitted
}

enum PromptTargetKind: String, Codable, Sendable {
  case capturedField
  case composerPaste
  case copyOnly
}

struct PromptHookContext: Codable, Equatable, Sendable {
  let requestID: UUID
  let sessionID: String
  let cwd: String
  let helperPID: Int32
}

struct PromptTarget: Identifiable, Codable, Equatable, Sendable {
  let id: UUID
  let kind: PromptTargetKind
  let processID: Int32?
  let bundleID: String?
  let applicationName: String
  let guidance: String
  let hookContext: PromptHookContext?

  init(
    id: UUID = UUID(),
    kind: PromptTargetKind,
    processID: Int32? = nil,
    bundleID: String? = nil,
    applicationName: String,
    guidance: String,
    hookContext: PromptHookContext? = nil
  ) {
    self.id = id
    self.kind = kind
    self.processID = processID
    self.bundleID = bundleID
    self.applicationName = applicationName
    self.guidance = guidance
    self.hookContext = hookContext
  }

  var supportsAutomaticSubmit: Bool { kind == .capturedField }
}

struct PromptCapture: Equatable, Sendable {
  let draft: String
  let target: PromptTarget
  let source: PromptGateSession.Source
}

struct PromptGateSession: Identifiable, Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case capturedField
    case composer
    case hook(requestID: UUID)
  }

  let id: UUID
  let initialDraft: String
  let target: PromptTarget
  let knownClient: PromptClient?
  let source: Source

  init(
    id: UUID = UUID(),
    initialDraft: String,
    target: PromptTarget,
    knownClient: PromptClient? = nil,
    source: Source
  ) {
    self.id = id
    self.initialDraft = initialDraft
    self.target = target
    self.knownClient = knownClient
    self.source = source
  }

  var hookRequestID: UUID? {
    guard case .hook(let requestID) = source else { return nil }
    return requestID
  }
}

struct PromptGateReview: Equatable, Sendable {
  let original: String
  var corrected: String
  let explanation: String
  private(set) var diff: [DiffSegment]

  init(original: String, corrected: String, explanation: String) {
    self.original = original
    self.corrected = corrected
    self.explanation = explanation
    diff = WordDiff.compute(original: original, corrected: corrected)
  }

  mutating func updateCorrected(_ value: String) {
    corrected = value
    diff = WordDiff.compute(original: original, corrected: value)
  }
}

enum PromptGatePhase: Equatable, Sendable {
  case closed
  case onboarding
  case composing
  case checking
  case reviewing
  case delivering
  case invalidated
}

enum HookInstallationStatus: Equatable, Sendable {
  case notInstalled
  case awaitingCodexTrust
  case installedUnconfirmed
  case active(lastSeen: Date)
  case needsRepair(String)
  case unavailable(String)

  var permitsReceipt: Bool {
    switch self {
    case .awaitingCodexTrust, .installedUnconfirmed, .active:
      true
    case .notInstalled, .needsRepair, .unavailable:
      false
    }
  }
}

protocol HookInstallationManaging: Sendable {
  func status(for client: PromptClient) async -> HookInstallationStatus
  func install(_ client: PromptClient) async throws
  func uninstall(_ client: PromptClient) async throws
}

protocol HookReviewResponding: Sendable {
  func complete(
    requestID: UUID,
    outcome: HookReviewOutcome,
    awaitAcknowledgement: Bool
  ) async throws
}

protocol PromptGateIPCServicing: Sendable {
  func setHandlers(
    onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
    onInvalidation: @escaping @Sendable (UUID) async -> Void
  ) async
  func start() async throws
  func stop() async
}
