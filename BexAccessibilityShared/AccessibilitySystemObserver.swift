import AppKit
import ApplicationServices
import Foundation

/// Observation only. No setters, focus changes, activation, event taps or key events.
@MainActor
final class AccessibilitySystemObserver: AccessibilityAgentObserving {
  var isTrusted: Bool { AXIsProcessTrusted() }

  func capture(excluding callerProcessID: Int32, before deadline: AccessibilityObservationDeadline) throws -> any AccessibilityCapturedField {
    try deadline.check()
    guard isTrusted, let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier > 0, app.processIdentifier != callerProcessID,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
      let bundleID = app.bundleIdentifier, let launchDate = app.launchDate
    else { throw AccessibilityAgentFailure.unsupported }
    // Timeout applies to this helper's AX messaging, not to another application's settings.
    let system = AXUIElementCreateSystemWide()
    guard AXUIElementSetMessagingTimeout(system, 0.5) == .success else {
      throw AccessibilityAgentFailure.unavailable
    }
    let element = try Self.focusedElement(processID: app.processIdentifier, deadline: deadline)
    let role = try Self.stringAttribute(kAXRoleAttribute, of: element, deadline: deadline)
    try Self.validateEditable(element, role: role, deadline: deadline)
    let original = try Self.stringAttribute(kAXValueAttribute, of: element, deadline: deadline)
    guard original.utf8.count <= AccessibilityAgentContract.maximumDraftBytes else {
      throw AccessibilityAgentFailure.capacity
    }
    let captured = Field(element: element, processID: app.processIdentifier,
      bundleIdentifier: bundleID, applicationName: app.localizedName ?? bundleID,
      launchDate: launchDate, role: role, original: original)
    try captured.revalidate(before: deadline)
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
      frontmost.processIdentifier == app.processIdentifier, frontmost.launchDate == launchDate,
      frontmost.bundleIdentifier == bundleID else { throw AccessibilityAgentFailure.stale }
    return captured
  }

  @MainActor
  private final class Field: AccessibilityCapturedField {
    let element: AXUIElement
    let processID: Int32
    let bundleIdentifier: String
    let applicationName: String
    let launchDate: Date
    let role: String
    let original: String

    init(element: AXUIElement, processID: Int32, bundleIdentifier: String, applicationName: String,
         launchDate: Date, role: String, original: String) {
      self.element = element
      self.processID = processID
      self.bundleIdentifier = bundleIdentifier
      self.applicationName = applicationName
      self.launchDate = launchDate
      self.role = role
      self.original = original
    }

    func revalidate(before deadline: AccessibilityObservationDeadline) throws {
      try deadline.check()
      guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: processID),
        !app.isTerminated, app.bundleIdentifier == bundleIdentifier, app.launchDate == launchDate
      else { throw AccessibilityAgentFailure.stale }
      let focused = try AccessibilitySystemObserver.focusedElement(processID: processID, deadline: deadline)
      guard CFEqual(focused, element),
        try AccessibilitySystemObserver.stringAttribute(kAXRoleAttribute, of: focused, deadline: deadline) == role
      else { throw AccessibilityAgentFailure.stale }
      try AccessibilitySystemObserver.validateEditable(focused, role: role, deadline: deadline)
      let current = try AccessibilitySystemObserver.stringAttribute(kAXValueAttribute, of: focused, deadline: deadline)
      guard current.utf8.elementsEqual(original.utf8) else { throw AccessibilityAgentFailure.stale }
    }
  }

  private static func focusedElement(processID: Int32, deadline: AccessibilityObservationDeadline) throws -> AXUIElement {
    try deadline.check()
    let application = AXUIElementCreateApplication(processID)
    guard AXUIElementSetMessagingTimeout(application, 0.5) == .success else {
      throw AccessibilityAgentFailure.unavailable
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { throw AccessibilityAgentFailure.unsupported }
    let element = value as! AXUIElement
    // Messaging timeouts do not propagate from parent to returned/equal AX elements.
    guard AXUIElementSetMessagingTimeout(element, 0.5) == .success else {
      throw AccessibilityAgentFailure.unavailable
    }
    try deadline.check()
    return element
  }

  private static func validateEditable(_ element: AXUIElement, role: String, deadline: AccessibilityObservationDeadline) throws {
    try deadline.check()
    guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String else {
      throw AccessibilityAgentFailure.unsupported
    }
    var subrole: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
    if result != .attributeUnsupported && result != .noValue {
      guard result == .success, let value = subrole as? String,
        value != kAXSecureTextFieldSubrole as String else { throw AccessibilityAgentFailure.unsupported }
    }
    try deadline.check()
    var enabled: CFTypeRef?
    let enabledResult = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
    if enabledResult != .attributeUnsupported && enabledResult != .noValue {
      guard enabledResult == .success, enabled as? Bool == true else { throw AccessibilityAgentFailure.unsupported }
    }
    try deadline.check()
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
      settable.boolValue else { throw AccessibilityAgentFailure.unsupported }
    try deadline.check()
  }

  private static func stringAttribute(_ name: String, of element: AXUIElement, deadline: AccessibilityObservationDeadline) throws -> String {
    try deadline.check()
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
      let value = value as? String else { throw AccessibilityAgentFailure.unsupported }
    try deadline.check()
    return value
  }
}
