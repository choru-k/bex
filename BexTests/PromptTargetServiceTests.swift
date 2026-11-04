import AppKit
import ApplicationServices
import XCTest

@testable import Bex

@MainActor
final class PromptTargetServiceTests: XCTestCase {
  func testCapturedDraftCopiesOnceWithoutChangingExternalField() async throws {
    let fixture = TargetFixture()
    let capture = try fixture.service.captureFrontmostTarget()
    XCTAssertEqual(capture.draft, "This are original.")
    XCTAssertEqual(capture.target.kind, .capturedField)
    XCTAssertEqual(capture.target.availableDeliveryActions, [.copyCorrection])
    XCTAssertFalse(capture.target.supportsAutomaticSubmit)
    XCTAssertEqual(capture.target.destinationLabel, "Clipboard")
    let outcome = try await fixture.service.deliver("This is original.", to: capture.target, action: .copyCorrection)
    XCTAssertEqual(outcome, .copied)
    XCTAssertEqual(fixture.writer.values, ["This is original."])
    XCTAssertEqual(fixture.accessibility.value, capture.draft)
    await assertRejected(fixture, target: capture.target, effect: .unknown)
    XCTAssertEqual(fixture.writer.values.count, 1)
  }

  func testStandaloneFactoryIssuesSingleUseCopyCapability() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.makeStandaloneTarget()
    let outcome = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection)
    XCTAssertEqual(outcome, .copied)
    await assertRejected(fixture, target: target, effect: .unknown)
    XCTAssertEqual(fixture.writer.values, ["Correction"])
    let next = try fixture.service.makeStandaloneTarget()
    XCTAssertNotEqual(target.id, next.id)
    let second = try await fixture.service.deliver("Next", to: next, action: .copyCorrection)
    XCTAssertEqual(second, .copied)
  }

  func testUnknownDiscardedAndDowngradedTargetIDsNeverAuthorizeCopy() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.captureFrontmostTarget().target
    let downgraded = copy(target, kind: .copyOnly)
    await assertRejected(fixture, target: downgraded, effect: .none)
    fixture.service.discard(target)
    await assertRejected(fixture, target: target, effect: .unknown)
    await assertRejected(fixture, target: downgraded, effect: .unknown)
    let invented = PromptTarget(kind: .copyOnly, applicationName: "Bex", guidance: "Copy")
    await assertRejected(fixture, target: invented, effect: .unknown)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testEveryCapturedTargetPropertyRemainsBoundToIssuedIdentity() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.captureFrontmostTarget().target
    let mutations = [
      copy(target, kind: .composerPaste), copy(target, processID: 322),
      copy(target, bundleID: "com.other.app"), copy(target, applicationName: "Other"),
      copy(target, guidance: "Different consent"),
      copy(target, context: PromptHookContext(requestID: UUID(), sessionID: "s", cwd: "/tmp", helperPID: 4)),
    ]
    for mutation in mutations { await assertRejected(fixture, target: mutation, effect: .none) }
    XCTAssertTrue(fixture.writer.values.isEmpty)
    let result = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection)
    XCTAssertEqual(result, .copied)
  }

  func testUnicodeEquivalentMetadataCannotAlterIssuedCapabilityBytes() {
    let original = PromptTarget(kind: .copyOnly, applicationName: "caf\u{00e9}", guidance: "Copy")
    let mutation = copy(original, applicationName: "cafe\u{0301}")
    XCTAssertEqual(original, mutation)
    XCTAssertFalse(original.matchesDeliveryIdentity(mutation))
    let context = PromptHookContext(requestID: UUID(), sessionID: "s", cwd: "/caf\u{00e9}", helperPID: 3)
    let target = PromptTarget(kind: .copyOnly, applicationName: "Editor", guidance: "Copy", hookContext: context)
    let changed = copy(target, context: PromptHookContext(requestID: context.requestID, sessionID: "s",
                                                         cwd: "/cafe\u{0301}", helperPID: 3))
    XCTAssertEqual(target, changed)
    XCTAssertFalse(target.matchesDeliveryIdentity(changed))
  }

  func testChangedFieldFocusRoleSubroleAndPermissionRejectBeforeClipboardWrite() async throws {
    let mutations: [(TargetFixture) -> Void] = [
      { $0.accessibility.value = "Edited after capture" },
      { $0.accessibility.sameElement = false },
      { $0.accessibility.role = kAXTextFieldRole as String },
      { $0.accessibility.subrole = kAXSecureTextFieldSubrole as String },
      { $0.accessibility.enabled = false }, { $0.accessibility.settable = false },
      { $0.accessibility.isTrusted = false }, { $0.accessibility.subroleError = true },
      { $0.applications.snapshot = nil },
      { $0.applications.replace(bundleID: "com.other.app") },
      { $0.applications.replace(launchDate: Date(timeIntervalSince1970: 99)) },
    ]
    for mutate in mutations {
      let fixture = TargetFixture()
      let target = try fixture.service.captureFrontmostTarget().target
      mutate(fixture)
      await assertRejected(fixture, target: target, effect: .none)
      XCTAssertTrue(fixture.writer.values.isEmpty)
    }
  }

  func testCanonicallyEquivalentButDifferentBytesAreAChangedRevision() async throws {
    let fixture = TargetFixture()
    fixture.accessibility.value = "caf\u{00e9}"
    let target = try fixture.service.captureFrontmostTarget().target
    fixture.accessibility.value = "cafe\u{0301}"
    await assertRejected(fixture, target: target, effect: .none)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testCaptureRechecksValueAndFrontmostProcessBeforeIssuance() throws {
    let fixture = TargetFixture()
    fixture.accessibility.onReadValue = { count in
      if count == 1 { fixture.accessibility.value = "Changed while reading" }
    }
    XCTAssertThrowsError(try fixture.service.captureFrontmostTarget())
    let switched = TargetFixture()
    switched.accessibility.onReadValue = { _ in switched.applications.isFrontmost = false }
    XCTAssertThrowsError(try switched.service.captureFrontmostTarget())
  }

  func testSecureOrUnreadableSecurityRoleNeverCaptures() throws {
    for unknownRole in [false, true] {
      let fixture = TargetFixture()
      fixture.accessibility.subrole = kAXSecureTextFieldSubrole as String
      fixture.accessibility.subroleError = unknownRole
      XCTAssertThrowsError(try fixture.service.captureFrontmostTarget())
      XCTAssertEqual(fixture.accessibility.readCount, 0)
    }
  }

  func testUntrustedUnsupportedEmptyOrUnidentifiableTargetUsesIssuedStandaloneFallback() async throws {
    let mutations: [(TargetFixture) -> Void] = [
      { $0.accessibility.isTrusted = false }, { $0.accessibility.role = "AXButton" },
      { $0.accessibility.value = "  " }, { $0.applications.replaceWithoutLaunchDate() },
    ]
    for mutate in mutations {
      let fixture = TargetFixture(); mutate(fixture)
      let capture = try fixture.service.captureFrontmostTarget()
      XCTAssertEqual(capture.source, .standalone)
      XCTAssertEqual(capture.draft, "")
      XCTAssertEqual(capture.target.availableDeliveryActions, [.copyCorrection])
      let outcome = try await fixture.service.deliver("Manual", to: capture.target, action: .copyCorrection)
      XCTAssertEqual(outcome, .copied)
    }
  }

  func testPasteAndReturnAreUnavailableEvenThroughLegacyBooleanEntryPoint() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.captureFrontmostTarget().target
    for action in [PromptDeliveryAction.pasteInDestination, .pasteAndSubmit] {
      do {
        _ = try await fixture.service.deliver("Correction", to: target, action: action)
        XCTFail("Unexpected automatic delivery")
      } catch { XCTAssertEqual((error as? PromptDeliveryFailure)?.effect, PromptDeliveryEffect.none) }
    }
    do {
      _ = try await fixture.service.deliver("Correction", to: target, pressReturn: true)
      XCTFail("Unexpected Return")
    } catch { XCTAssertEqual((error as? PromptDeliveryFailure)?.effect, PromptDeliveryEffect.none) }
    XCTAssertTrue(fixture.writer.values.isEmpty)
    XCTAssertEqual(fixture.accessibility.value, "This are original.")
  }

  func testHookComposerAlwaysCopiesRegardlessOfAppIdentityOrAccessibility() async throws {
    for trusted in [false, true] {
      for client in [PromptClient.claudeCode, .codex] {
        let fixture = TargetFixture(); fixture.accessibility.isTrusted = trusted
        let request = hookRequest(client: client)
        let target = try fixture.service.target(for: request)
        XCTAssertEqual(target.kind, .copyOnly)
        XCTAssertNil(target.processID)
        XCTAssertEqual(target.hookContext?.requestID, request.requestID)
        XCTAssertEqual(target.availableDeliveryActions, [.copyCorrection])
        let outcome = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection)
        XCTAssertEqual(outcome, .copied)
        await assertRejected(fixture, target: target, effect: .unknown)
      }
    }
  }

  func testHostManagedOMPStagingRemainsSingleUseAndNeverUsesClipboard() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.target(for: hookRequest(client: .ohMyPi))
    XCTAssertEqual(target.kind, .managedDraft)
    XCTAssertEqual(target.availableDeliveryActions, [.pasteInDestination])
    XCTAssertFalse(target.supportsAutomaticSubmit)
    let outcome = try await fixture.service.deliver("Correction", to: target, action: .pasteInDestination)
    XCTAssertEqual(outcome, .staged)
    await assertRejected(fixture, target: target, effect: .unknown)
    XCTAssertTrue(fixture.writer.values.isEmpty)
  }

  func testUncertainClipboardWriteConsumesCapabilityAndCannotRetry() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.makeStandaloneTarget()
    fixture.writer.failsAfterWrite = true
    await assertRejected(fixture, target: target, effect: .unknown)
    fixture.writer.failsAfterWrite = false
    await assertRejected(fixture, target: target, effect: .unknown)
    XCTAssertEqual(fixture.writer.values, ["Correction"])
  }

  func testCapabilityIsConsumedBeforePasteboardWriterCanReenter() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.makeStandaloneTarget()
    fixture.writer.onWrite = {
      do {
        try fixture.service.validateDelivery(to: target, action: .copyCorrection)
        XCTFail("Consumed capability authorized reentrant delivery")
      } catch { }
    }
    let outcome = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection)
    XCTAssertEqual(outcome, .copied)
    XCTAssertEqual(fixture.writer.values.count, 1)
  }

  func testCancellationBeforeWriteLeavesCapabilityUnconsumed() async throws {
    let fixture = TargetFixture()
    let target = try fixture.service.makeStandaloneTarget()
    let task = Task { try await fixture.service.deliver("Correction", to: target, action: .copyCorrection) }
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(fixture.writer.values.isEmpty)
    let outcome = try await fixture.service.deliver("Correction", to: target, action: .copyCorrection)
    XCTAssertEqual(outcome, .copied)
  }

  func testPendingRegistryIsBoundedAndDiscardReclaimsCapacity() throws {
    let fixture = TargetFixture(maximumPendingTargets: 2)
    let first = try fixture.service.makeStandaloneTarget()
    _ = try fixture.service.makeStandaloneTarget()
    XCTAssertThrowsError(try fixture.service.makeStandaloneTarget())
    fixture.service.discard(first)
    XCTAssertNoThrow(try fixture.service.makeStandaloneTarget())
  }

  func testExpiryRejectsOldCapabilityAndReclaimsRegistryWithoutAuthorizingReplay() async throws {
    let fixture = TargetFixture(maximumPendingTargets: 1)
    let target = try fixture.service.makeStandaloneTarget()
    fixture.date = fixture.date.addingTimeInterval(3600)
    let next = try fixture.service.makeStandaloneTarget()
    await assertRejected(fixture, target: target, effect: .unknown)
    let outcome = try await fixture.service.deliver("New", to: next, action: .copyCorrection)
    XCTAssertEqual(outcome, .copied)
  }

  func testMissingEnabledAttributeDefersToSettableButUnknownAXErrorsFail() throws {
    XCTAssertTrue(try SystemPromptAccessibilityService.resolveEnabled(result: .attributeUnsupported, value: nil))
    XCTAssertTrue(try SystemPromptAccessibilityService.resolveEnabled(result: .noValue, value: nil))
    XCTAssertFalse(try SystemPromptAccessibilityService.resolveEnabled(result: .success, value: kCFBooleanFalse))
    XCTAssertThrowsError(try SystemPromptAccessibilityService.resolveEnabled(result: .cannotComplete, value: nil))
  }

  private func assertRejected(_ fixture: TargetFixture, target: PromptTarget, effect: PromptDeliveryEffect) async {
    do {
      _ = try await fixture.service.deliver("Correction", to: target, pressReturn: false)
      XCTFail("Expected rejected target")
    } catch { XCTAssertEqual((error as? PromptDeliveryFailure)?.effect, effect) }
  }

  private func copy(_ target: PromptTarget, kind: PromptTargetKind? = nil, processID: Int32? = nil,
                    bundleID: String? = nil, applicationName: String? = nil, guidance: String? = nil,
                    context: PromptHookContext? = nil) -> PromptTarget {
    PromptTarget(id: target.id, kind: kind ?? target.kind, processID: processID ?? target.processID,
                 bundleID: bundleID ?? target.bundleID, applicationName: applicationName ?? target.applicationName,
                 guidance: guidance ?? target.guidance, hookContext: context ?? target.hookContext)
  }

  private func hookRequest(client: PromptClient) -> HookReviewRequest {
    HookReviewRequest(requestID: UUID(), client: client, prompt: "Prompt", sessionID: "session", cwd: "/tmp",
                      helperPID: 123, sourcePID: 321, sourceBundleID: "com.example.editor")
  }
}

@MainActor
private final class TargetFixture {
  let applications = TargetApplications()
  let accessibility = TargetAccessibility()
  let writer = TargetPasteboard()
  var date = Date(timeIntervalSince1970: 100)
  private(set) var service: PromptTargetService!

  init(maximumPendingTargets: Int = 64) {
    service = PromptTargetService(applications: applications, accessibility: accessibility,
                                  pasteboardWriter: writer, ownProcessID: 999,
                                  maximumPendingTargets: maximumPendingTargets, now: { [unowned self] in self.date })
  }
}

@MainActor
private final class TargetApplications: PromptApplicationServicing {
  var isFrontmost = true
  var snapshot: PromptApplicationSnapshot? = PromptApplicationSnapshot(
    processID: 321, bundleID: "com.example.editor", name: "Editor", launchDate: Date(timeIntervalSince1970: 1))
  func frontmostApplication(excluding processID: Int32) -> PromptApplicationSnapshot? { isFrontmost ? snapshot : nil }
  func application(processID: Int32) -> PromptApplicationSnapshot? { snapshot }
  func replace(bundleID: String = "com.example.editor", launchDate: Date = Date(timeIntervalSince1970: 1)) {
    snapshot = PromptApplicationSnapshot(processID: 321, bundleID: bundleID, name: "Editor", launchDate: launchDate)
  }
  func replaceWithoutLaunchDate() {
    snapshot = PromptApplicationSnapshot(processID: 321, bundleID: "com.example.editor", name: "Editor")
  }
}

@MainActor
private final class TargetAccessibility: PromptAccessibilityServicing {
  var isTrusted = true
  var role = kAXTextAreaRole as String
  var subrole: String?
  var subroleError = false
  var value = "This are original."
  var enabled = true
  var settable = true
  var sameElement = true
  var readCount = 0
  var onReadValue: ((Int) -> Void)?
  let element = AXUIElementCreateApplication(321)
  func requestTrust() -> Bool { isTrusted }
  func focusedElement(processID: Int32) throws -> AXUIElement { element }
  func role(of element: AXUIElement) throws -> String { role }
  func subrole(of element: AXUIElement) throws -> String? {
    if subroleError { throw BexError.unsupportedPromptTarget }
    return subrole
  }
  func isEnabled(_ element: AXUIElement) throws -> Bool { enabled }
  func isValueSettable(_ element: AXUIElement) throws -> Bool { settable }
  func stringValue(of element: AXUIElement) throws -> String {
    let snapshot = value
    readCount += 1
    onReadValue?(readCount)
    return snapshot
  }
  func isSameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { sameElement }
}

@MainActor
private final class TargetPasteboard: PasteboardWriting {
  var values: [String] = []
  var failsAfterWrite = false
  var onWrite: (() -> Void)?
  func write(_ string: String) throws {
    values.append(string)
    onWrite?()
    if failsAfterWrite { throw BexError.storageFailure("Write outcome is uncertain.") }
  }
}
