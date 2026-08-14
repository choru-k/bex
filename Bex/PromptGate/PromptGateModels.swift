import Foundation

extension PromptClient {
  static let focusedPickerClients: [PromptClient] = [.claudeCode, .codex]
  var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .ohMyPi: "Oh My Pi"
    }
  }
}

enum PromptDeliveryAction: String, CaseIterable, Equatable, Hashable, Sendable {
  case copyCorrection
  case pasteInDestination
  case pasteAndSubmit
}

enum PromptDeliveryEffect: Equatable, Sendable {
  case none
  case copied
  case pastedNotSubmitted
  case submitted
  case unknown

  var isFullRetrySafe: Bool {
    self == .none
  }
}

struct PromptDeliveryFailure: LocalizedError, Sendable {
  let effect: PromptDeliveryEffect
  let underlyingError: any Error

  var isFullRetrySafe: Bool {
    effect.isFullRetrySafe
  }

  var errorDescription: String? {
    if effect != .none,
      let error = underlyingError as? BexError,
      case .promptDeliveryFailed(let detail) = error
    {
      return detail
    }
    return underlyingError.localizedDescription
  }
}

enum PromptDeliveryOutcome: Equatable, Sendable {
  case copied
  case pasted
  case submitted
  case staged
}

extension PromptDeliveryOutcome {
  var effect: PromptDeliveryEffect {
    switch self {
    case .copied: .copied
    case .pasted: .pastedNotSubmitted
    case .submitted: .submitted
    case .staged: .pastedNotSubmitted
    }
  }
}

enum PromptTargetKind: String, Codable, Sendable {
  case capturedField
  case composerPaste
  case copyOnly
  case managedDraft
}

struct PromptHookContext: Codable, Equatable, Sendable {
  let requestID: UUID
  let sessionID: String
  let cwd: String
  let helperPID: Int32
  let client: PromptClient?
  let integrationID: String?

  init(
    requestID: UUID,
    sessionID: String,
    cwd: String,
    helperPID: Int32,
    client: PromptClient? = nil,
    integrationID: String? = nil
  ) {
    self.requestID = requestID
    self.sessionID = sessionID
    self.cwd = cwd
    self.helperPID = helperPID
    self.client = client
    self.integrationID = integrationID
  }
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

extension PromptTarget {
  var availableDeliveryActions: [PromptDeliveryAction] {
    switch kind {
    case .copyOnly:
      [.copyCorrection]
    case .composerPaste:
      hookContext == nil ? [.copyCorrection, .pasteInDestination] : [.pasteInDestination]
    case .capturedField:
      [.pasteInDestination, .pasteAndSubmit]
    case .managedDraft:
      [.pasteInDestination]
    }
  }

  func label(for action: PromptDeliveryAction) -> String {
    if kind == .managedDraft {
      return "Stage in \(applicationName)"
    }
    if kind == .capturedField {
      return switch action {
      case .copyCorrection:
        "Copy Correction"
      case .pasteInDestination:
        "Replace Draft in \(applicationName)"
      case .pasteAndSubmit:
        "Replace & Press Return in \(applicationName)"
      }
    }
    return switch action {
    case .copyCorrection:
      "Copy Correction"
    case .pasteInDestination:
      "Paste in \(applicationName)"
    case .pasteAndSubmit:
      "Paste & Send in \(applicationName)"
    }
  }

  var destinationLabel: String {
    kind == .copyOnly ? "Clipboard" : applicationName
  }
}

struct PromptCapture: Equatable, Sendable {
  let draft: String
  let target: PromptTarget
  let source: PromptGateSession.Source
}

struct PromptGateSession: Identifiable, Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case capturedField
    case standalone
    case hook(requestID: UUID)
  }

  let id: UUID
  let initialDraft: String
  let target: PromptTarget
  let knownClient: PromptClient?
  let source: Source
  let usesDraftPersistence: Bool

  init(
    id: UUID = UUID(),
    initialDraft: String,
    target: PromptTarget,
    knownClient: PromptClient? = nil,
    source: Source,
    usesDraftPersistence: Bool? = nil
  ) {
    self.id = id
    self.initialDraft = initialDraft
    self.target = target
    self.knownClient = knownClient
    self.source = source
    self.usesDraftPersistence = usesDraftPersistence ?? source.supportsDraftPersistence
  }

  var hookRequestID: UUID? {
    guard case .hook(let requestID) = source else { return nil }
    return requestID
  }
}

extension PromptGateSession.Source {
  var outboundConfirmationContext: OutboundConfirmationContext {
    switch self {
    case .capturedField:
      .manualCapturedField
    case .standalone:
      .standaloneFixAndSend
    case .hook:
      .hook
    }
  }

  var supportsDraftPersistence: Bool {
    switch self {
    case .standalone:
      true
    case .capturedField, .hook:
      false
    }
  }
}

struct PromptGateReview: Equatable, Sendable {
  let original: String
  let aiCorrected: String
  var corrected: String
  let explanation: String
  private(set) var diff: [DiffSegment]

  init(original: String, corrected: String, explanation: String) {
    self.original = original
    aiCorrected = corrected
    self.corrected = corrected
    self.explanation = explanation
    diff = WordDiff.compute(original: original, corrected: corrected)
  }

  var hasHumanEdits: Bool {
    corrected != aiCorrected
  }

  var hasChanges: Bool {
    diff.contains { $0.kind != .unchanged }
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

/// One run of the masked payload as the consent sheet draws it: either prose that will
/// leave the Mac, or a span that will not.
struct OutboundSegment: Identifiable, Equatable, Sendable {
  enum Content: Equatable, Sendable {
    case text(String)
    /// A withheld span, named by what it was recognized as ("path", "url", "flag", …).
    case masked(kind: String)
  }

  let id: Int
  let content: Content
}

/// One unranked expression alternative offered alongside a correction.
///
/// Deliberately carries no score, rank or "recommended" flag — non-negotiable 5 forbids
/// ranking these, and the surest way to keep that true is for the type to have nowhere to
/// put a rank.
struct PromptGateAlternative: Identifiable, Equatable, Sendable {
  let phrase: String
  let alternative: String
  let reason: String

  /// Matches `ConsiderTap.id`, so a pick made here and a pick made in Learn are the same
  /// decision and cannot mint two cards for one choice.
  var id: String { "\(phrase)|\(alternative)" }
}

enum PromptGateKeyboardFocus: Equatable, Hashable, Sendable {
  case primaryAction
  case draftEditor
  case correctedEditor
  case recoveryAction
}

enum PromptGateAccessibilityFocus: Equatable, Hashable, Sendable {
  case disclosureHeading
  case composerHeading
  case finalMessageHeading
  case errorHeading
  case statusHeading
  case discardAlert
}

struct PromptGateFocusRequest: Equatable, Sendable {
  let id: UUID
  let keyboard: PromptGateKeyboardFocus?
  let accessibility: PromptGateAccessibilityFocus?

  init(
    keyboard: PromptGateKeyboardFocus?,
    accessibility: PromptGateAccessibilityFocus?
  ) {
    id = UUID()
    self.keyboard = keyboard
    self.accessibility = accessibility
  }
}

enum HookIntegrationTarget: Equatable, Sendable {
  case claudeCode
  case codex
  case ohMyPi(executable: URL, profile: String?, workingDirectory: URL)
}

enum HookIntegrationValidation: Equatable, Sendable {
  case supported
  case unavailable(String)
}

struct HookIntegrationDescriptor: Identifiable, Equatable, Sendable {
  let id: String
  let client: PromptClient
  let profile: String
  let executableURL: URL?
  let workingDirectory: URL?
  let configurationURL: URL
  let gateURL: URL?
  let helperURL: URL
  let capabilityVersion: Int?
  let validation: HookIntegrationValidation
}

enum HookInstallationOperation: String, Codable, Equatable, Sendable {
  case install
  case update
  case repair
  case uninstall
}

enum HookArtifactKind: String, Codable, Equatable, Sendable {
  case directory
  case file
}

enum HookArtifactChange: String, Codable, Equatable, Sendable {
  case create
  case replace
  case delete
  case keep
}

struct HookArtifactSnapshot: Equatable, Sendable {
  let exists: Bool
  let mode: UInt16?
  let sha256: String?
}

struct HookInstallationAction: Identifiable, Equatable, Sendable {
  let id: String
  let path: String
  let kind: HookArtifactKind
  let change: HookArtifactChange
  let before: HookArtifactSnapshot
  let after: HookArtifactSnapshot
}

struct HookInstallationReview: Identifiable, Equatable, Sendable {
  let id: UUID
  let operation: HookInstallationOperation
  let descriptor: HookIntegrationDescriptor
  let trustGuidance: String
  let limitations: String
  let signer: String
  let currentText: String?
  let proposedText: String?
  let actions: [HookInstallationAction]
}

struct HookInstallationResult: Equatable, Sendable {
  let completed: [String]
  let restored: [String]
  let failed: [String]
}

enum HookInstallationStatus: Equatable, Sendable {
  case notInstalled
  case updateAvailable
  case awaitingCodexTrust
  case installedUnconfirmed
  case active(lastSeen: Date)
  case needsRepair(String)
  case unavailable(String)

  var permitsReceipt: Bool {
    switch self {
    case .awaitingCodexTrust, .installedUnconfirmed, .active, .updateAvailable:
      true
    case .notInstalled, .needsRepair, .unavailable:
      false
    }
  }
}

protocol HookInstallationManaging: Sendable {
  func status(for client: PromptClient) async -> HookInstallationStatus
  func install(_ client: PromptClient) async throws
  func resolve(_ target: HookIntegrationTarget) async throws -> HookIntegrationDescriptor
  func installedDescriptors() async -> [HookIntegrationDescriptor]
  func prepare(
    _ operation: HookInstallationOperation,
    for descriptor: HookIntegrationDescriptor
  ) async throws -> HookInstallationReview
  func apply(reviewID: UUID) async throws -> HookInstallationResult
  func cancel(reviewID: UUID) async
  func status(for integrationID: String) async -> HookInstallationStatus
  func uninstall(_ client: PromptClient) async throws
}

extension HookInstallationManaging {
  func resolve(_ target: HookIntegrationTarget) async throws -> HookIntegrationDescriptor {
    throw BexError.storageFailure("This integration manager cannot resolve targets.")
  }

  func installedDescriptors() async -> [HookIntegrationDescriptor] { [] }

  func prepare(
    _ operation: HookInstallationOperation,
    for descriptor: HookIntegrationDescriptor
  ) async throws -> HookInstallationReview {
    throw BexError.storageFailure("This integration manager cannot prepare changes.")
  }

  func apply(reviewID: UUID) async throws -> HookInstallationResult {
    throw BexError.storageFailure("This integration manager cannot apply changes.")
  }

  func cancel(reviewID: UUID) async {}

  func status(for integrationID: String) async -> HookInstallationStatus {
    .notInstalled
  }
}

protocol HookReviewResponding: Sendable {
  func complete(
    requestID: UUID,
    outcome: HookReviewOutcome,
    awaitAcknowledgement: Bool,
    approvedPrompt: String?,
    integrationID: String?
  ) async throws
}

extension HookReviewResponding {
  func complete(
    requestID: UUID,
    outcome: HookReviewOutcome,
    awaitAcknowledgement: Bool
  ) async throws {
    try await complete(
      requestID: requestID,
      outcome: outcome,
      awaitAcknowledgement: awaitAcknowledgement,
      approvedPrompt: nil,
      integrationID: nil
    )
  }

}

protocol PromptGateIPCServicing: Sendable {
  func setHandlers(
    onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
    onInvalidation: @escaping @Sendable (UUID) async -> Void
  ) async
  func start() async throws
  func stop() async
}
