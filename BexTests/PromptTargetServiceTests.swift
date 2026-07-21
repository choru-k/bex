import AppKit
import ApplicationServices
import XCTest

@testable import Bex

@MainActor
final class PromptTargetServiceTests: XCTestCase {
  func testCapturedFieldDeliveryRevalidatesThenPastesObservesExactValueAndReturns() async throws {
    let fixture = TargetFixture()
    fixture.pasteboard.clearContents()
    fixture.pasteboard.setString("existing clipboard", forType: .string)
    let capture = try fixture.service.captureFrontmostTarget()
    XCTAssertEqual(capture.draft, "This are original.")
    XCTAssertEqual(capture.target.kind, .capturedField)

    fixture.log.removeAll()
    let outcome = try await fixture.service.deliver(
      "This is original.",
      to: capture.target,
      pressReturn: true
    )

    XCTAssertEqual(outcome, .submitted)
    XCTAssertEqual(outcome.effect, .submitted)
    XCTAssertEqual(fixture.accessibility.value, "This is original.")
    XCTAssertEqual(fixture.pasteboard.string(forType: .string), "existing clipboard")
    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 1)
    XCTAssertLessThan(try index("orderOut", in: fixture.log), try index("activate", in: fixture.log))
    XCTAssertLessThan(try index("activate", in: fixture.log), try index("focus", in: fixture.log))
    XCTAssertLessThan(try index("selectAll", in: fixture.log), try index("paste", in: fixture.log))
    XCTAssertLessThan(try index("paste", in: fixture.log), try index("return", in: fixture.log))
    XCTAssertGreaterThanOrEqual(fixture.log.filter { $0 == "revalidateValue" }.count, 3)
  }

  func testChangedCapturedFieldFailsBeforePanelHidesOrKeyEventsPost() async throws {
    let fixture = TargetFixture()
    let capture = try fixture.service.captureFrontmostTarget()
    fixture.log.removeAll()
    fixture.accessibility.value = "User changed this meanwhile."

    do {
      _ = try await fixture.service.deliver(
        "Correction",
        to: capture.target,
        pressReturn: true
      )
      XCTFail("Expected stale target")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .none)
      XCTAssertTrue(failure.isFullRetrySafe)
      XCTAssertEqual(failure.underlyingError as? BexError, .stalePromptTarget)
    }

    XCTAssertFalse(fixture.log.contains("orderOut"))
    XCTAssertEqual(fixture.events.pasteCount, 0)
    XCTAssertEqual(fixture.events.returnCount, 0)
  }

  func testReturnIsNotPostedWhenPastedValueCannotBeObservedExactly() async throws {
    let fixture = TargetFixture()
    let capture = try fixture.service.captureFrontmostTarget()
    fixture.log.removeAll()
    fixture.events.applyPaste = false

    do {
      _ = try await fixture.service.deliver(
        "Correction",
        to: capture.target,
        pressReturn: true
      )
      XCTFail("Expected verification failure")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .unknown)
      XCTAssertFalse(failure.isFullRetrySafe)
      XCTAssertTrue(failure.localizedDescription.contains("verify the pasted correction"))
      XCTAssertFalse(failure.localizedDescription.contains("Nothing was sent"))
    }

    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 0)
  }

  func testRejectedPasteReportsNoEffectAndAllowsFullRetry() async throws {
    let fixture = TargetFixture()
    let capture = try fixture.service.captureFrontmostTarget()
    fixture.events.pasteSucceeds = false

    do {
      _ = try await fixture.service.deliver(
        "Correction",
        to: capture.target,
        pressReturn: true
      )
      XCTFail("Expected paste failure")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .none)
      XCTAssertTrue(failure.isFullRetrySafe)
    }

    XCTAssertEqual(fixture.accessibility.value, "This are original.")
    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 0)
  }

  func testReturnFailureAfterVerifiedPasteReportsPartialSuccessWithoutRetrying() async throws {
    let fixture = TargetFixture()
    let capture = try fixture.service.captureFrontmostTarget()
    fixture.events.returnSucceeds = false

    do {
      _ = try await fixture.service.deliver(
        "Correction",
        to: capture.target,
        pressReturn: true
      )
      XCTFail("Expected submit failure")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .pastedNotSubmitted)
      XCTAssertFalse(failure.isFullRetrySafe)
      XCTAssertTrue(failure.localizedDescription.contains("could not submit"))
      XCTAssertFalse(failure.localizedDescription.contains("Nothing was sent"))
    }

    XCTAssertEqual(fixture.accessibility.value, "Correction")
    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 1)
  }

  func testCancellationAfterVerifiedPasteReportsPartialSuccess() async throws {
    let fixture = TargetFixture()
    let capture = try fixture.service.captureFrontmostTarget()
    let deliveryTask = Task {
      try await fixture.service.deliver(
        "Correction",
        to: capture.target,
        pressReturn: true
      )
    }
    fixture.accessibility.onReadValue = { value in
      if value == "Correction" {
        deliveryTask.cancel()
      }
    }

    do {
      _ = try await deliveryTask.value
      XCTFail("Expected cancellation")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .pastedNotSubmitted)
      XCTAssertTrue(failure.underlyingError is CancellationError)
      XCTAssertFalse(failure.isFullRetrySafe)
    }

    XCTAssertEqual(fixture.accessibility.value, "Correction")
    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 0)
  }

  func testUntrustedAndUnsupportedTargetsUseCopyOrComposerFallback() async throws {
    let fixture = TargetFixture()
    fixture.accessibility.isTrusted = false
    let untrusted = try fixture.service.captureFrontmostTarget()
    XCTAssertEqual(untrusted.target.kind, .copyOnly)
    XCTAssertEqual(untrusted.draft, "")

    let copied = try await fixture.service.deliver(
      "Manual correction",
      to: untrusted.target,
      pressReturn: true
    )
    XCTAssertEqual(copied, .copied)
    XCTAssertEqual(copied.effect, .copied)
    XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Manual correction")
    XCTAssertEqual(fixture.events.returnCount, 0)

    fixture.accessibility.isTrusted = true
    fixture.accessibility.role = "AXButton"
    let composer = try fixture.service.captureFrontmostTarget()
    XCTAssertEqual(composer.target.kind, .composerPaste)
    XCTAssertEqual(composer.draft, "")
  }

  func testComposerDeliveryReportsPastedWithoutSubmitting() async throws {
    let fixture = TargetFixture()
    fixture.accessibility.role = "AXButton"
    let capture = try fixture.service.captureFrontmostTarget()

    let outcome = try await fixture.service.deliver(
      "Composer correction",
      to: capture.target,
      pressReturn: true
    )

    XCTAssertEqual(outcome, .pasted)
    XCTAssertEqual(outcome.effect, .pastedNotSubmitted)
    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 0)
  }

  func testComposerPasteFailureReportsCompletedCopyEffect() async throws {
    let fixture = TargetFixture()
    fixture.accessibility.role = "AXButton"
    fixture.events.pasteSucceeds = false
    let capture = try fixture.service.captureFrontmostTarget()

    do {
      _ = try await fixture.service.deliver(
        "Composer correction",
        to: capture.target,
        pressReturn: false
      )
      XCTFail("Expected paste failure")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .copied)
      XCTAssertFalse(failure.isFullRetrySafe)
    }

    XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Composer correction")
    XCTAssertEqual(fixture.events.pasteCount, 1)
    XCTAssertEqual(fixture.events.returnCount, 0)
  }

  func testOnlyNoEffectAllowsAFullDeliveryRetry() {
    XCTAssertTrue(PromptDeliveryEffect.none.isFullRetrySafe)
    XCTAssertFalse(PromptDeliveryEffect.copied.isFullRetrySafe)
    XCTAssertFalse(PromptDeliveryEffect.pastedNotSubmitted.isFullRetrySafe)
    XCTAssertFalse(PromptDeliveryEffect.submitted.isFullRetrySafe)
    XCTAssertFalse(PromptDeliveryEffect.unknown.isFullRetrySafe)
  }

  func testHookTargetRequiresMatchingSourcePIDAndBundleForComposerPaste() throws {
    let fixture = TargetFixture()
    let base = HookReviewRequest(
      requestID: UUID(),
      client: .claudeCode,
      prompt: "Prompt",
      sessionID: "session",
      cwd: "/tmp",
      helperPID: 123,
      sourcePID: 321,
      sourceBundleID: "com.example.editor"
    )
    XCTAssertEqual(try fixture.service.target(for: base).kind, .composerPaste)

    let mismatched = HookReviewRequest(
      requestID: UUID(),
      client: .claudeCode,
      prompt: "Prompt",
      sessionID: "session",
      cwd: "/tmp",
      helperPID: 123,
      sourcePID: 321,
      sourceBundleID: "com.other.app"
    )
    let target = try fixture.service.target(for: mismatched)
    XCTAssertEqual(target.kind, .copyOnly)
    XCTAssertNil(target.processID)
  }

  func testMissingEnabledAttributeDefersToSettableCheckButOtherAXErrorsFail() throws {
    XCTAssertTrue(
      try SystemPromptAccessibilityService.resolveEnabled(
        result: .attributeUnsupported,
        value: nil
      )
    )
    XCTAssertTrue(
      try SystemPromptAccessibilityService.resolveEnabled(result: .noValue, value: nil)
    )
    XCTAssertFalse(
      try SystemPromptAccessibilityService.resolveEnabled(
        result: .success,
        value: kCFBooleanFalse
      )
    )
    XCTAssertThrowsError(
      try SystemPromptAccessibilityService.resolveEnabled(
        result: .cannotComplete,
        value: nil
      )
    ) { error in
      XCTAssertEqual(error as? BexError, .unsupportedPromptTarget)
    }
  }

  func testCapabilityActionsExposeOnlySafeTargetSpecificChoices() async throws {
    let capturedFixture = TargetFixture()
    let captured = try capturedFixture.service.captureFrontmostTarget()
    XCTAssertEqual(
      captured.target.availableDeliveryActions,
      [.pasteInDestination, .pasteAndSubmit]
    )
    let pasted = try await capturedFixture.service.deliver(
      "Correction",
      to: captured.target,
      action: .pasteInDestination
    )
    XCTAssertEqual(pasted, .pasted)
    XCTAssertEqual(capturedFixture.events.returnCount, 0)

    do {
      _ = try await capturedFixture.service.deliver(
        "Correction",
        to: captured.target,
        action: .copyCorrection
      )
      XCTFail("Expected unavailable action failure")
    } catch {
      let failure = try XCTUnwrap(error as? PromptDeliveryFailure)
      XCTAssertEqual(failure.effect, .none)
      XCTAssertTrue(failure.isFullRetrySafe)
    }

    let composerFixture = TargetFixture()
    composerFixture.accessibility.role = "AXButton"
    let composer = try composerFixture.service.captureFrontmostTarget()
    XCTAssertEqual(
      composer.target.availableDeliveryActions,
      [.copyCorrection, .pasteInDestination]
    )
    let copied = try await composerFixture.service.deliver(
      "Copy instead",
      to: composer.target,
      action: .copyCorrection
    )
    XCTAssertEqual(copied, .copied)
    XCTAssertEqual(composerFixture.events.pasteCount, 0)
    XCTAssertEqual(composerFixture.events.returnCount, 0)
  }

  func testPermissionGuidanceDistinguishesManualFallbackFromHookSuppliedPrompt() throws {
    let fixture = TargetFixture()
    fixture.accessibility.isTrusted = false
    let manual = try fixture.service.captureFrontmostTarget()
    XCTAssertTrue(manual.target.guidance.contains("manual capture"))
    XCTAssertTrue(manual.target.guidance.contains("invoke Fix & Send again"))
    XCTAssertTrue(manual.target.guidance.contains("Client hooks can still supply"))

    let request = HookReviewRequest(
      requestID: UUID(),
      client: .claudeCode,
      prompt: "Prompt",
      sessionID: "session",
      cwd: "/tmp",
      helperPID: 123,
      sourcePID: 321,
      sourceBundleID: "com.example.editor"
    )
    let hook = try fixture.service.target(for: request)
    XCTAssertEqual(hook.kind, .copyOnly)
    XCTAssertTrue(hook.guidance.contains("hook supplied"))
    XCTAssertFalse(hook.availableDeliveryActions.contains(.pasteAndSubmit))
  }

  private func index(_ value: String, in values: [String]) throws -> Int {
    try XCTUnwrap(values.firstIndex(of: value), "Missing event \(value): \(values)")
  }
}

@MainActor
private final class TargetFixture {
  var log: [String] = []
  let pasteboard: NSPasteboard
  let applications: TargetApplications
  let accessibility: TargetAccessibility
  let events: TargetEvents
  let timing = TargetTiming()
  private(set) var service: PromptTargetService!

  init() {
    pasteboard = NSPasteboard(name: .init("com.bex.tests.prompt-target.\(UUID().uuidString)"))
    applications = TargetApplications()
    accessibility = TargetAccessibility()
    events = TargetEvents()
    let systemPasteboard = SystemPasteboard(pasteboard: pasteboard)
    applications.log = { [weak self] in self?.log.append($0) }
    accessibility.log = { [weak self] in self?.log.append($0) }
    events.log = { [weak self] in self?.log.append($0) }
    events.accessibility = accessibility
    events.pasteboard = pasteboard
    service = PromptTargetService(
      applications: applications,
      accessibility: accessibility,
      events: events,
      timing: timing,
      pasteboardWriter: systemPasteboard,
      pasteboardTransaction: systemPasteboard,
      ownProcessID: 999,
      orderOutPanel: { [weak self] in self?.log.append("orderOut") }
    )
  }
}

@MainActor
private final class TargetApplications: PromptApplicationServicing {
  var log: ((String) -> Void)?
  var frontmost = true
  let snapshot = PromptApplicationSnapshot(
    processID: 321,
    bundleID: "com.example.editor",
    name: "Editor"
  )

  func frontmostApplication(excluding processID: Int32) -> PromptApplicationSnapshot? { snapshot }
  func application(processID: Int32) -> PromptApplicationSnapshot? {
    log?("application")
    return processID == snapshot.processID ? snapshot : nil
  }
  func activate(processID: Int32) -> Bool {
    log?("activate")
    frontmost = true
    return processID == snapshot.processID
  }
  func isFrontmost(processID: Int32) -> Bool { frontmost && processID == snapshot.processID }
}

@MainActor
private final class TargetAccessibility: PromptAccessibilityServicing {
  var log: ((String) -> Void)?
  var isTrusted = true
  var role = kAXTextAreaRole as String
  var value = "This are original."
  var enabled = true
  var settable = true
  var onReadValue: ((String) -> Void)?
  let element = AXUIElementCreateApplication(321)

  func requestTrust() -> Bool { isTrusted }
  func focusedElement(processID: Int32) throws -> AXUIElement {
    log?("focused")
    return element
  }
  func role(of element: AXUIElement) throws -> String {
    log?("role")
    return role
  }
  func subrole(of element: AXUIElement) -> String? { nil }
  func isEnabled(_ element: AXUIElement) throws -> Bool {
    log?("enabled")
    return enabled
  }
  func isValueSettable(_ element: AXUIElement) throws -> Bool {
    log?("settable")
    return settable
  }
  func stringValue(of element: AXUIElement) throws -> String {
    log?("revalidateValue")
    onReadValue?(value)
    return value
  }
  func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { true }
  func focus(_ element: AXUIElement) throws { log?("focus") }
  func selectAll(_ element: AXUIElement, utf16Length: Int) throws { log?("selectAll") }
}

@MainActor
private final class TargetEvents: PromptKeyEventPosting {
  var log: ((String) -> Void)?
  weak var accessibility: TargetAccessibility?
  var pasteboard: NSPasteboard?
  var applyPaste = true
  var pasteSucceeds = true
  var returnSucceeds = true
  var pasteCount = 0
  var returnCount = 0

  func postPaste() -> Bool {
    log?("paste")
    pasteCount += 1
    if pasteSucceeds, applyPaste, let value = pasteboard?.string(forType: .string) {
      accessibility?.value = value
    }
    return pasteSucceeds
  }

  func postReturn() -> Bool {
    log?("return")
    returnCount += 1
    return returnSucceeds
  }
}

@MainActor
private final class TargetTiming: PromptTargetTiming {
  var now = Date(timeIntervalSince1970: 0)
  func sleep(milliseconds: UInt64) async throws {
    now = now.addingTimeInterval(Double(milliseconds) / 1_000)
  }
}
