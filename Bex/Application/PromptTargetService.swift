import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol PromptTargetServicing: AnyObject {
  var isAccessibilityTrusted: Bool { get }
  @discardableResult func requestAccessibilityTrust() -> Bool
  func makeStandaloneTarget() throws -> PromptTarget
  func captureFrontmostTarget() throws -> PromptCapture
  func validateDelivery(to target: PromptTarget, action: PromptDeliveryAction) throws
  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget
  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome
  func discard(_ target: PromptTarget)
}

extension PromptTargetServicing {
  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    action: PromptDeliveryAction
  ) async throws -> PromptDeliveryOutcome {
    guard target.availableDeliveryActions.contains(action) else {
      throw PromptDeliveryFailure(
        effect: .none,
        underlyingError: BexError.promptDeliveryFailed(
          "That delivery action is not available for \(target.applicationName)."
        )
      )
    }

    switch action {
    case .copyCorrection:
      return try await deliver(correctedText, to: target, pressReturn: false)
    case .pasteInDestination:
      return try await deliver(correctedText, to: target, pressReturn: false)
    case .pasteAndSubmit:
      return try await deliver(correctedText, to: target, pressReturn: true)
    }
  }
}

struct PromptApplicationSnapshot: Equatable, Sendable {
  let processID: Int32
  let bundleID: String?
  let name: String
  let launchDate: Date?

  init(processID: Int32, bundleID: String?, name: String, launchDate: Date? = nil) {
    self.processID = processID
    self.bundleID = bundleID
    self.name = name
    self.launchDate = launchDate
  }
}

@MainActor
protocol PromptApplicationServicing: AnyObject {
  func frontmostApplication(excluding processID: Int32) -> PromptApplicationSnapshot?
  func application(processID: Int32) -> PromptApplicationSnapshot?
}

@MainActor
final class SystemPromptApplicationService: PromptApplicationServicing {
  func frontmostApplication(excluding processID: Int32) -> PromptApplicationSnapshot? {
    guard let application = NSWorkspace.shared.frontmostApplication,
      application.processIdentifier != processID
    else {
      return nil
    }
    return snapshot(application)
  }

  func application(processID: Int32) -> PromptApplicationSnapshot? {
    guard let application = NSRunningApplication(processIdentifier: processID),
      !application.isTerminated
    else {
      return nil
    }
    return snapshot(application)
  }

  private func snapshot(_ application: NSRunningApplication) -> PromptApplicationSnapshot {
    PromptApplicationSnapshot(
      processID: application.processIdentifier,
      bundleID: application.bundleIdentifier,
      name: application.localizedName ?? application.bundleIdentifier ?? "Application",
      launchDate: application.launchDate
    )
  }
}

@MainActor
protocol PromptAccessibilityServicing: AnyObject {
  var isTrusted: Bool { get }
  @discardableResult func requestTrust() -> Bool
  func focusedElement(processID: Int32) throws -> AXUIElement
  func role(of element: AXUIElement) throws -> String
  func subrole(of element: AXUIElement) throws -> String?
  func isEnabled(_ element: AXUIElement) throws -> Bool
  func isValueSettable(_ element: AXUIElement) throws -> Bool
  func stringValue(of element: AXUIElement) throws -> String
  func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool
}

@MainActor
final class SystemPromptAccessibilityService: PromptAccessibilityServicing {
  var isTrusted: Bool { AXIsProcessTrusted() }

  func requestTrust() -> Bool {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  func focusedElement(processID: Int32) throws -> AXUIElement {
    let application = AXUIElementCreateApplication(processID)
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedUIElementAttribute as CFString,
        &value
      ) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      throw BexError.unsupportedPromptTarget
    }
    return value as! AXUIElement
  }

  func role(of element: AXUIElement) throws -> String {
    try stringAttribute(kAXRoleAttribute, of: element)
  }

  func subrole(of element: AXUIElement) throws -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
    if result == .attributeUnsupported || result == .noValue { return nil }
    guard result == .success, let subrole = value as? String else {
      throw BexError.unsupportedPromptTarget
    }
    return subrole
  }

  func isEnabled(_ element: AXUIElement) throws -> Bool {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
      element,
      kAXEnabledAttribute as CFString,
      &value
    )
    return try Self.resolveEnabled(result: result, value: value)
  }

  static func resolveEnabled(result: AXError, value: CFTypeRef?) throws -> Bool {
    if result == .attributeUnsupported || result == .noValue {
      return true
    }
    guard result == .success, let enabled = value as? Bool else {
      throw BexError.unsupportedPromptTarget
    }
    return enabled
  }

  func isValueSettable(_ element: AXUIElement) throws -> Bool {
    var settable = DarwinBoolean(false)
    guard
      AXUIElementIsAttributeSettable(
        element,
        kAXValueAttribute as CFString,
        &settable
      ) == .success
    else {
      throw BexError.unsupportedPromptTarget
    }
    return settable.boolValue
  }

  func stringValue(of element: AXUIElement) throws -> String {
    try stringAttribute(kAXValueAttribute, of: element)
  }

  func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
    CFEqual(lhs, rhs)
  }

  private func stringAttribute(_ attribute: String, of element: AXUIElement) throws -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
      let string = value as? String
    else {
      throw BexError.unsupportedPromptTarget
    }
    return string
  }
}

/// Generic Accessibility exposes observations, not a transactional compare-and-replace
/// or submit primitive. Keep this adapter read-only. Delivery is an explicit clipboard
/// copy; the user chooses the destination, replaces the draft and submits manually.
@MainActor
final class PromptTargetService: PromptTargetServicing {
  private struct CapturedField {
    let element: AXUIElement
    let application: PromptApplicationSnapshot
    let role: String
    let original: String
  }

  private struct IssuedTarget {
    let target: PromptTarget
    let captured: CapturedField?
    let expiresAt: Date
  }

  private let applications: any PromptApplicationServicing
  private let accessibility: any PromptAccessibilityServicing
  private let pasteboardWriter: any PasteboardWriting
  private let ownProcessID: Int32
  private let now: @MainActor () -> Date
  private let maximumPendingTargets: Int
  private var issuedTargets: [UUID: IssuedTarget] = [:]

  init(
    applications: any PromptApplicationServicing = SystemPromptApplicationService(),
    accessibility: any PromptAccessibilityServicing = SystemPromptAccessibilityService(),
    pasteboardWriter: any PasteboardWriting = SystemPasteboard(),
    ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
    maximumPendingTargets: Int = 64,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.applications = applications
    self.accessibility = accessibility
    self.pasteboardWriter = pasteboardWriter
    self.ownProcessID = ownProcessID
    self.maximumPendingTargets = max(1, maximumPendingTargets)
    self.now = now
  }

  var isAccessibilityTrusted: Bool { accessibility.isTrusted }

  func requestAccessibilityTrust() -> Bool {
    accessibility.requestTrust()
  }

  func makeStandaloneTarget() throws -> PromptTarget {
    try issue(PromptTarget(
      kind: .copyOnly,
      applicationName: "Bex",
      guidance: "Fix & Send will copy the approved correction for use wherever you need it."
    ))
  }

  func captureFrontmostTarget() throws -> PromptCapture {
    guard let application = applications.frontmostApplication(excluding: ownProcessID),
      application.processID > 0, application.processID != ownProcessID
    else { throw BexError.unsupportedPromptTarget }

    guard accessibility.isTrusted else {
      return try standaloneCapture(for: application, guidance:
        "Without Accessibility, Fix & Send cannot capture another app. Enter text here; Bex will copy the approved correction."
      )
    }
    // PID/bundle alone can be recycled. An unidentifiable process is manual-entry only.
    guard application.launchDate != nil, let bundleID = application.bundleID, !bundleID.isEmpty else {
      return try standaloneCapture(for: application)
    }
    let element = try accessibility.focusedElement(processID: application.processID)
    let role = try accessibility.role(of: element)
    guard try accessibility.subrole(of: element) != kAXSecureTextFieldSubrole as String else {
      throw BexError.unsupportedPromptTarget
    }
    guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String,
      try accessibility.isEnabled(element), try accessibility.isValueSettable(element)
    else { return try standaloneCapture(for: application) }
    let value = try accessibility.stringValue(of: element)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return try standaloneCapture(for: application)
    }
    let captured = CapturedField(element: element, application: application, role: role, original: value)
    // Re-read identity, focus, security role and exact bytes before exposing the capture.
    // This detects observed drift, not ABA edits or an atomic external revision.
    try revalidate(captured)
    guard applications.frontmostApplication(excluding: ownProcessID) == application else {
      throw BexError.stalePromptTarget
    }
    let target = try issue(PromptTarget(
      kind: .capturedField,
      processID: application.processID,
      bundleID: application.bundleID,
      applicationName: application.name,
      guidance: "Bex captured this draft from \(application.name). Copy the correction, then replace the intended draft and submit manually."
    ), captured: captured)
    return PromptCapture(draft: value, target: target, source: .capturedField)
  }

  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget {
    let context = PromptHookContext(
      requestID: hookRequest.requestID,
      sessionID: hookRequest.sessionID,
      cwd: hookRequest.cwd,
      helperPID: hookRequest.helperPID,
      client: hookRequest.client,
      integrationID: hookRequest.integrationID
    )
    if hookRequest.client == .ohMyPi {
      return try issue(PromptTarget(
        kind: .managedDraft,
        applicationName: "Oh My Pi",
        guidance: "Oh My Pi is holding the original prompt. Approval stages this exact correction in its editor for explicit replay.",
        hookContext: context
      ))
    }
    // Hook source PID/bundle do not authenticate a focused field. Never translate
    // hook acknowledgement into a global paste or Return keystroke.
    return try issue(PromptTarget(
      kind: .copyOnly,
      applicationName: hookRequest.client.displayName,
      guidance: "This hook supplied the prompt. Bex will copy the approved correction; replace the client draft and submit manually.",
      hookContext: context
    ))
  }

  func validateDelivery(to target: PromptTarget, action: PromptDeliveryAction) throws {
    guard target.availableDeliveryActions.contains(action) else {
      throw PromptDeliveryFailure(effect: .none, underlyingError:
        BexError.promptDeliveryFailed("Only the displayed Copy or host-managed Stage action is available.")
      )
    }
    guard let issued = issuedTargets[target.id], issued.expiresAt > now() else {
      issuedTargets.removeValue(forKey: target.id)
      // Unknown may mean already consumed; never advertise a full retry as safe.
      throw PromptDeliveryFailure(effect: .unknown, underlyingError:
        BexError.promptDeliveryFailed("This review is no longer available. Check the Clipboard and destination, then start a new review if needed.")
      )
    }
    guard issued.target.matchesDeliveryIdentity(target) else { throw BexError.stalePromptTarget }
    if let captured = issued.captured { try revalidate(captured) }
  }

  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome {
    do {
      try Task.checkCancellation()
      guard !pressReturn else {
        throw BexError.promptDeliveryFailed("Automatic submission is unavailable. Copy the correction and submit it manually.")
      }
      guard !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BexError.emptyInput
      }
      let action: PromptDeliveryAction = target.kind == .managedDraft ? .pasteInDestination : .copyCorrection
      try validateDelivery(to: target, action: action)
      try Task.checkCancellation()
      // No suspension between validation, consumption and the one allowed side effect.
      // Unknown IDs always fail, so no permanent tombstones or retained prompts are needed.
      issuedTargets.removeValue(forKey: target.id)
      if target.kind == .managedDraft { return .staged }
      do {
        try pasteboardWriter.write(correctedText)
      } catch {
        // A write may have cleared or changed the clipboard before reporting failure.
        throw PromptDeliveryFailure(effect: .unknown, underlyingError: error)
      }
      return .copied
    } catch let failure as PromptDeliveryFailure {
      throw failure
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch {
      throw PromptDeliveryFailure(effect: .none, underlyingError: error)
    }
  }

  func discard(_ target: PromptTarget) {
    issuedTargets.removeValue(forKey: target.id)
  }

  private func issue(_ target: PromptTarget, captured: CapturedField? = nil) throws -> PromptTarget {
    let date = now()
    issuedTargets = issuedTargets.filter { $0.value.expiresAt > date }
    guard issuedTargets.count < maximumPendingTargets else {
      throw BexError.promptDeliveryFailed("Close an existing review before starting another.")
    }
    issuedTargets[target.id] = IssuedTarget(
      target: target, captured: captured, expiresAt: date.addingTimeInterval(3600)
    )
    return target
  }

  private func standaloneCapture(
    for application: PromptApplicationSnapshot,
    guidance: String? = nil
  ) throws -> PromptCapture {
    let target = try issue(PromptTarget(
      kind: .copyOnly,
      bundleID: application.bundleID,
      applicationName: application.name,
      guidance: guidance ?? "Bex did not capture a supported field in \(application.name). Enter text here; Bex will copy the approved correction."
    ))
    return PromptCapture(draft: "", target: target, source: .standalone)
  }

  private func revalidate(_ captured: CapturedField) throws {
    guard accessibility.isTrusted,
      let application = applications.application(processID: captured.application.processID),
      application.processID == captured.application.processID,
      application.bundleID == captured.application.bundleID,
      application.launchDate == captured.application.launchDate
    else { throw BexError.stalePromptTarget }
    let focused = try accessibility.focusedElement(processID: application.processID)
    guard accessibility.isSameElement(focused, captured.element),
      try accessibility.role(of: focused) == captured.role,
      try accessibility.subrole(of: focused) != kAXSecureTextFieldSubrole as String,
      try accessibility.isEnabled(focused), try accessibility.isValueSettable(focused),
      try accessibility.stringValue(of: focused).utf8.elementsEqual(captured.original.utf8)
    else { throw BexError.stalePromptTarget }
  }
}
