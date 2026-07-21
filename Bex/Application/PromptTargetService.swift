import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
protocol PromptTargetServicing: AnyObject {
  var isAccessibilityTrusted: Bool { get }
  @discardableResult func requestAccessibilityTrust() -> Bool
  func captureFrontmostTarget() throws -> PromptCapture
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
      let clipboardTarget = PromptTarget(
        kind: .copyOnly,
        applicationName: target.applicationName,
        guidance: target.guidance,
        hookContext: target.hookContext
      )
      return try await deliver(correctedText, to: clipboardTarget, pressReturn: false)
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
}

@MainActor
protocol PromptApplicationServicing: AnyObject {
  func frontmostApplication(excluding processID: Int32) -> PromptApplicationSnapshot?
  func application(processID: Int32) -> PromptApplicationSnapshot?
  @discardableResult func activate(processID: Int32) -> Bool
  func isFrontmost(processID: Int32) -> Bool
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
    guard let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated
    else {
      return nil
    }
    return snapshot(application)
  }

  func activate(processID: Int32) -> Bool {
    NSRunningApplication(processIdentifier: processID)?
      .activate(options: [.activateIgnoringOtherApps]) == true
  }

  func isFrontmost(processID: Int32) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
  }

  private func snapshot(_ application: NSRunningApplication) -> PromptApplicationSnapshot {
    PromptApplicationSnapshot(
      processID: application.processIdentifier,
      bundleID: application.bundleIdentifier,
      name: application.localizedName ?? application.bundleIdentifier ?? "Application"
    )
  }
}

@MainActor
protocol PromptAccessibilityServicing: AnyObject {
  var isTrusted: Bool { get }
  @discardableResult func requestTrust() -> Bool
  func focusedElement(processID: Int32) throws -> AXUIElement
  func role(of element: AXUIElement) throws -> String
  func subrole(of element: AXUIElement) -> String?
  func isEnabled(_ element: AXUIElement) throws -> Bool
  func isValueSettable(_ element: AXUIElement) throws -> Bool
  func stringValue(of element: AXUIElement) throws -> String
  func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool
  func focus(_ element: AXUIElement) throws
  func selectAll(_ element: AXUIElement, utf16Length: Int) throws
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
    guard AXUIElementCopyAttributeValue(
      application,
      kAXFocusedUIElementAttribute as CFString,
      &value
    ) == .success,
      let element = value as! AXUIElement?
    else {
      throw BexError.unsupportedPromptTarget
    }
    return element
  }

  func role(of element: AXUIElement) throws -> String {
    try stringAttribute(kAXRoleAttribute, of: element)
  }

  func subrole(of element: AXUIElement) -> String? {
    try? stringAttribute(kAXSubroleAttribute, of: element)
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
    guard AXUIElementIsAttributeSettable(
      element,
      kAXValueAttribute as CFString,
      &settable
    ) == .success else {
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

  func focus(_ element: AXUIElement) throws {
    guard AXUIElementSetAttributeValue(
      element,
      kAXFocusedAttribute as CFString,
      kCFBooleanTrue
    ) == .success else {
      throw BexError.promptDeliveryFailed("Bex could not focus the original prompt field.")
    }
  }

  func selectAll(_ element: AXUIElement, utf16Length: Int) throws {
    var range = CFRange(location: 0, length: utf16Length)
    guard let value = AXValueCreate(.cfRange, &range),
      AXUIElementSetAttributeValue(
        element,
        kAXSelectedTextRangeAttribute as CFString,
        value
      ) == .success
    else {
      throw BexError.promptDeliveryFailed("Bex could not select the original prompt.")
    }
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

@MainActor
protocol PromptKeyEventPosting: AnyObject {
  @discardableResult func postPaste() -> Bool
  @discardableResult func postReturn() -> Bool
}

@MainActor
final class SystemPromptKeyEventPoster: PromptKeyEventPosting {
  func postPaste() -> Bool {
    postKey(code: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
  }

  func postReturn() -> Bool {
    postKey(code: CGKeyCode(kVK_Return), flags: [])
  }

  private func postKey(code: CGKeyCode, flags: CGEventFlags) -> Bool {
    guard let source = CGEventSource(stateID: .combinedSessionState),
      let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    else {
      return false
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }
}

@MainActor
protocol PromptTargetTiming: AnyObject {
  var now: Date { get }
  func sleep(milliseconds: UInt64) async throws
}

@MainActor
final class SystemPromptTargetTiming: PromptTargetTiming {
  var now: Date { Date() }

  func sleep(milliseconds: UInt64) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }
}

@MainActor
final class PromptTargetService: PromptTargetServicing {
  private struct CapturedField {
    let element: AXUIElement
    let processID: Int32
    let bundleID: String?
    let role: String
    let original: String
  }

  private let applications: any PromptApplicationServicing
  private let accessibility: any PromptAccessibilityServicing
  private let events: any PromptKeyEventPosting
  private let timing: any PromptTargetTiming
  private let pasteboardWriter: any PasteboardWriting
  private let pasteboardTransaction: any PasteboardTransacting
  private let orderOutPanel: @MainActor () -> Void
  private let ownProcessID: Int32
  private var capturedFields: [UUID: CapturedField] = [:]

  init(
    applications: any PromptApplicationServicing = SystemPromptApplicationService(),
    accessibility: any PromptAccessibilityServicing = SystemPromptAccessibilityService(),
    events: any PromptKeyEventPosting = SystemPromptKeyEventPoster(),
    timing: any PromptTargetTiming = SystemPromptTargetTiming(),
    pasteboardWriter: any PasteboardWriting = SystemPasteboard(),
    pasteboardTransaction: any PasteboardTransacting = SystemPasteboard(),
    ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
    orderOutPanel: @escaping @MainActor () -> Void = {
      NSApp.keyWindow?.orderOut(nil)
    }
  ) {
    self.applications = applications
    self.accessibility = accessibility
    self.events = events
    self.timing = timing
    self.pasteboardWriter = pasteboardWriter
    self.pasteboardTransaction = pasteboardTransaction
    self.ownProcessID = ownProcessID
    self.orderOutPanel = orderOutPanel
  }

  var isAccessibilityTrusted: Bool { accessibility.isTrusted }

  func requestAccessibilityTrust() -> Bool {
    accessibility.requestTrust()
  }

  func captureFrontmostTarget() throws -> PromptCapture {
    guard let application = applications.frontmostApplication(excluding: ownProcessID) else {
      throw BexError.unsupportedPromptTarget
    }

    guard accessibility.isTrusted else {
      let target = PromptTarget(
        kind: .copyOnly,
        processID: nil,
        bundleID: application.bundleID,
        applicationName: application.name,
        guidance: "Accessibility is required for manual capture and replacement. Grant access, then invoke Fix & Send again. Client hooks can still supply prompts without Accessibility."
      )
      return PromptCapture(draft: "", target: target, source: .composer)
    }

    let element = try accessibility.focusedElement(processID: application.processID)
    let role = try accessibility.role(of: element)
    let secureSubrole = accessibility.subrole(of: element)
    if secureSubrole == kAXSecureTextFieldSubrole as String {
      throw BexError.unsupportedPromptTarget
    }

    let isSupportedRole = role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
    guard isSupportedRole else {
      return composerCapture(for: application)
    }
    let enabled = try accessibility.isEnabled(element)
    let settable = try accessibility.isValueSettable(element)
    guard enabled, settable else {
      return composerCapture(for: application)
    }
    let value = try accessibility.stringValue(of: element)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return composerCapture(for: application)
    }

    let target = PromptTarget(
      kind: .capturedField,
      processID: application.processID,
      bundleID: application.bundleID,
      applicationName: application.name,
      guidance: "Bex captured this exact field and can paste the correction back into \(application.name)."
    )
    capturedFields[target.id] = CapturedField(
      element: element,
      processID: application.processID,
      bundleID: application.bundleID,
      role: role,
      original: value
    )
    return PromptCapture(draft: value, target: target, source: .capturedField)
  }

  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget {
    let context = PromptHookContext(
      requestID: hookRequest.requestID,
      sessionID: hookRequest.sessionID,
      cwd: hookRequest.cwd,
      helperPID: hookRequest.helperPID
    )
    guard let sourcePID = hookRequest.sourcePID,
      sourcePID != ownProcessID,
      let application = applications.application(processID: sourcePID),
      let expectedBundleID = hookRequest.sourceBundleID,
      application.bundleID == expectedBundleID
    else {
      return PromptTarget(
        kind: .copyOnly,
        applicationName: "Prompt client",
        guidance: "This hook supplied the prompt without Accessibility. Bex will copy the approved correction; replace the client draft manually.",
        hookContext: context
      )
    }
    return PromptTarget(
      kind: accessibility.isTrusted ? .composerPaste : .copyOnly,
      processID: accessibility.isTrusted ? application.processID : nil,
      bundleID: application.bundleID,
      applicationName: application.name,
      guidance: accessibility.isTrusted
        ? "This hook supplied the prompt. Bex will paste the approved correction into \(application.name) without pressing Return."
        : "This hook supplied the prompt without Accessibility. Bex will copy the approved correction for manual replacement.",
      hookContext: context
    )
  }

  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome {
    do {
      try Task.checkCancellation()
      switch target.kind {
      case .copyOnly:
        do {
          try pasteboardWriter.write(correctedText)
        } catch {
          throw PromptDeliveryFailure(effect: .none, underlyingError: error)
        }
        return .copied
      case .composerPaste:
        return try await deliverToComposer(correctedText, target: target)
      case .capturedField:
        return try await deliverToCapturedField(
          correctedText,
          target: target,
          pressReturn: pressReturn
        )
      }
    } catch let failure as PromptDeliveryFailure {
      throw failure
    } catch let cancellation as CancellationError {
      throw cancellation
    } catch {
      throw PromptDeliveryFailure(effect: .none, underlyingError: error)
    }
  }

  func discard(_ target: PromptTarget) {
    capturedFields.removeValue(forKey: target.id)
  }

  private func composerCapture(for application: PromptApplicationSnapshot) -> PromptCapture {
    let target = PromptTarget(
      kind: .composerPaste,
      processID: application.processID,
      bundleID: application.bundleID,
      applicationName: application.name,
      guidance: "Bex can paste the correction into \(application.name) without pressing Return."
    )
    return PromptCapture(draft: "", target: target, source: .composer)
  }

  private func deliverToComposer(
    _ correctedText: String,
    target: PromptTarget
  ) async throws -> PromptDeliveryOutcome {
    var effect = PromptDeliveryEffect.none
    do {
      guard accessibility.isTrusted, let processID = target.processID else {
        throw BexError.accessibilityPermissionRequired
      }
      orderOutPanel()
      guard applications.activate(processID: processID) else {
        throw BexError.promptDeliveryFailed("Bex could not activate the prompt target.")
      }
      try await waitUntilFrontmost(processID: processID)
      try Task.checkCancellation()
      effect = .unknown
      try pasteboardWriter.write(correctedText)
      effect = .copied
      guard events.postPaste() else {
        throw BexError.promptDeliveryFailed("Bex could not paste the correction.")
      }
      return .pasted
    } catch let cancellation as CancellationError where effect == .none {
      throw cancellation
    } catch {
      throw PromptDeliveryFailure(effect: effect, underlyingError: error)
    }
  }

  private func deliverToCapturedField(
    _ correctedText: String,
    target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome {
    var effect = PromptDeliveryEffect.none
    do {
      guard accessibility.isTrusted, let captured = capturedFields[target.id] else {
        throw BexError.stalePromptTarget
      }
      try revalidate(captured)
      orderOutPanel()
      guard applications.activate(processID: captured.processID) else {
        throw BexError.promptDeliveryFailed("Bex could not activate the original prompt target.")
      }
      try await waitUntilFrontmost(processID: captured.processID)
      try Task.checkCancellation()
      try revalidate(captured)
      try accessibility.focus(captured.element)
      try accessibility.selectAll(captured.element, utf16Length: captured.original.utf16.count)
      try revalidate(captured)

      let restoration: PasteboardRestoration
      do {
        restoration = try pasteboardTransaction.stage(correctedText)
      } catch {
        throw PromptDeliveryFailure(effect: .unknown, underlyingError: error)
      }
      defer { restoration.restore() }
      guard events.postPaste() else {
        throw BexError.promptDeliveryFailed("Bex could not paste the correction.")
      }
      effect = .unknown
      try await waitForValue(correctedText, in: captured.element)
      effect = .pastedNotSubmitted
      if pressReturn {
        try Task.checkCancellation()
        guard events.postReturn() else {
          throw BexError.promptDeliveryFailed("Bex could not submit the correction.")
        }
        return .submitted
      }
      return .pasted
    } catch let failure as PromptDeliveryFailure {
      throw failure
    } catch let cancellation as CancellationError where effect == .none {
      throw cancellation
    } catch {
      throw PromptDeliveryFailure(effect: effect, underlyingError: error)
    }
  }

  private func revalidate(_ captured: CapturedField) throws {
    guard let application = applications.application(processID: captured.processID),
      application.bundleID == captured.bundleID
    else {
      throw BexError.stalePromptTarget
    }
    let focused = try accessibility.focusedElement(processID: captured.processID)
    guard accessibility.isSameElement(focused, captured.element),
      try accessibility.role(of: focused) == captured.role,
      try accessibility.isEnabled(focused),
      try accessibility.isValueSettable(focused),
      try accessibility.stringValue(of: focused) == captured.original
    else {
      throw BexError.stalePromptTarget
    }
  }

  private func waitUntilFrontmost(processID: Int32) async throws {
    let deadline = timing.now.addingTimeInterval(1)
    while !applications.isFrontmost(processID: processID), timing.now < deadline {
      try Task.checkCancellation()
      try await timing.sleep(milliseconds: 25)
    }
    guard applications.isFrontmost(processID: processID) else {
      throw BexError.promptDeliveryFailed("The original prompt target did not become active.")
    }
  }

  private func waitForValue(_ expected: String, in element: AXUIElement) async throws {
    let deadline = timing.now.addingTimeInterval(0.5)
    while timing.now < deadline {
      try Task.checkCancellation()
      if try accessibility.stringValue(of: element) == expected {
        return
      }
      try await timing.sleep(milliseconds: 10)
    }
    throw BexError.promptDeliveryFailed("Bex could not verify the pasted correction.")
  }
}
