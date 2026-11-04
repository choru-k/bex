import Foundation
import XCTest

@testable import Bex

/// Source-authored lifecycle tests, not native IPC/TCC or app-activation proof.
/// Every coordinator capture is retired before its synthetic reply is released:
/// none intentionally reaches successful capture UI presentation.
@MainActor
final class IndependentCaptureCompositionTests: XCTestCase {
  func testDefaultConstructionDoesNotSelectOrStartIndependentService() async throws {
    let fixture = try CompositionCoordinatorFixture()
    defer { fixture.remove() }
    let coordinator = WindowCoordinator(services: fixture.services)

    XCTAssertFalse(coordinator.usesIndependentAccessibility)
    await coordinator.shutdownIndependentAccessibility()

    XCTAssertEqual(fixture.client.captureCount, 0)
    XCTAssertEqual(fixture.client.statusCount, 0)
    XCTAssertEqual(fixture.client.stopCount, 0)
    await assertNoExternalWork(fixture)
  }

  func testSecondHotKeyCoalescesWhileFirstCaptureIsPending() async throws {
    let fixture = try CompositionCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.closePromptGate()
      fixture.client.resumeAll()
      fixture.remove()
    }
    fixture.client.pauseCapture = true
    coordinator.showPromptGate()
    try await waitUntil { fixture.client.captureCount == 1 }

    coordinator.showPromptGate()
    coordinator.showPromptGate()
    XCTAssertEqual(try captureTasks(coordinator).count, 1)
    XCTAssertEqual(fixture.client.captureCount, 1)

    // Do not open a real successful-capture panel just to finish this test.
    coordinator.closePromptGate()
    fixture.client.resumeCapture()
    try await waitUntil {
      fixture.client.discards.count == 1 && (try? self.captureTasks(coordinator).isEmpty) == true
    }

    XCTAssertEqual(fixture.client.captureCount, 1)
    try assertDiscardedOriginalCapture(fixture.client)
    try assertNoPromptGateWasCreated(coordinator)
    await assertNoExternalWork(fixture)
  }

  func testCloseDuringPendingCaptureDiscardsLateResultWithoutOpeningReview() async throws {
    let fixture = try CompositionCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.closePromptGate()
      fixture.client.resumeAll()
      fixture.remove()
    }
    fixture.client.pauseCapture = true
    coordinator.showPromptGate()
    try await waitUntil { fixture.client.captureCount == 1 }
    let capture = try XCTUnwrap(fixture.client.captures.first)

    coordinator.closePromptGate()
    XCTAssertTrue(fixture.client.discards.isEmpty)
    XCTAssertEqual(try captureTasks(coordinator).count, 1, "Cancelled work must remain owned until it drains")
    fixture.client.resumeCapture()
    try await waitUntil {
      fixture.client.discards.count == 1 && (try? self.captureTasks(coordinator).isEmpty) == true
    }

    XCTAssertEqual(fixture.client.discards.first?.0, capture.capture.token)
    XCTAssertEqual(fixture.client.discards.first?.1, capture.session)
    XCTAssertEqual(fixture.client.currentSession, capture.session, "Close must not stop the shared helper")
    XCTAssertEqual(fixture.client.stopCount, 0)
    try assertNoPromptGateWasCreated(coordinator)
    await assertNoExternalWork(fixture)
  }

  func testShutdownDrainsLateCaptureAndRejectsLaterInvocations() async throws {
    let fixture = try CompositionCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.closePromptGate()
      fixture.client.resumeAll()
      fixture.remove()
    }
    fixture.client.pauseCapture = true
    coordinator.showPromptGate()
    try await waitUntil { fixture.client.captureCount == 1 }
    let didShutDown = CompositionFlag()
    let shutdown = Task { @MainActor in
      await coordinator.shutdownIndependentAccessibility()
      didShutDown.value = true
    }
    defer { shutdown.cancel() }
    try await waitUntil { fixture.client.stopCount == 1 }

    XCTAssertFalse(didShutDown.value, "Shutdown must join the still-suspended capture")
    XCTAssertNil(fixture.client.currentSession)
    coordinator.showPromptGate()
    XCTAssertEqual(try captureTasks(coordinator).count, 1)
    fixture.client.resumeCapture()
    try await waitUntil { didShutDown.value && fixture.client.discards.count == 1 }
    await shutdown.value

    let lateHook = HookReviewRequest(client: .claudeCode, prompt: "Do not open after stop",
      sessionID: "late-hook", cwd: "/synthetic", helperPID: 7)
    XCTAssertFalse(coordinator.showPromptGate(hookRequest: lateHook))
    coordinator.showPromptGate()
    coordinator.showPromptGate()
    XCTAssertTrue(try captureTasks(coordinator).isEmpty)
    XCTAssertEqual(fixture.client.captureCount, 1)
    try assertDiscardedOriginalCapture(fixture.client)
    try assertNoPromptGateWasCreated(coordinator)
    await assertNoExternalWork(fixture)
  }

  func testSynchronousAdmissionCloseRejectsQueuedCaptureBeforeAsyncDrain() async throws {
    let fixture = try CompositionCoordinatorFixture()
    let coordinator = fixture.coordinator()
    defer {
      coordinator.closePromptGate()
      fixture.client.resumeAll()
      fixture.remove()
    }

    // No suspension between scheduling the capture and closing admission. The
    // queued MainActor capture task has not reached even the synthetic client.
    coordinator.showPromptGate()
    XCTAssertEqual(try captureTasks(coordinator).count, 1)
    XCTAssertEqual(fixture.client.captureCount, 0)
    coordinator.closeIndependentAccessibilityAdmission()
    coordinator.showPromptGate()

    XCTAssertEqual(try captureTasks(coordinator).count, 1)
    XCTAssertEqual(fixture.client.stopCount, 0, "Admission closes before async transport teardown")
    try await waitUntil { (try? self.captureTasks(coordinator).isEmpty) == true }
    XCTAssertEqual(fixture.client.captureCount, 0)
    XCTAssertTrue(fixture.client.discards.isEmpty)
    try assertNoPromptGateWasCreated(coordinator)

    await coordinator.shutdownIndependentAccessibility()
    XCTAssertEqual(fixture.client.stopCount, 1)
    coordinator.showPromptGate()
    XCTAssertTrue(try captureTasks(coordinator).isEmpty)
    await assertNoExternalWork(fixture)
  }

  func testCancellingOneStatusObserverKeepsSharedTransportAndCapturedSessionAlive() async throws {
    let client = CompositionAXClient()
    let recorder = CompositionCopyRecorder()
    let service = IndependentAccessibilityTargetService(client: client, pasteboard: recorder)
    defer { client.resumeAll() }
    let capture = try await service.captureFrontmostTarget()
    let originalSession = try XCTUnwrap(client.currentSession)
    client.pauseStatus = true
    let firstFinished = CompositionFlag()
    let first = Task { @MainActor in
      defer { firstFinished.value = true }
      return try await service.accessibilityStatus()
    }
    defer { first.cancel() }
    try await waitUntil { client.statusCount == 1 }
    let secondStarted = CompositionFlag()
    let secondFinished = CompositionFlag()
    let second = Task { @MainActor in
      defer { secondFinished.value = true }
      secondStarted.value = true
      return try await service.accessibilityStatus()
    }
    defer { second.cancel() }
    try await waitUntil { secondStarted.value }

    first.cancel()
    XCTAssertEqual(client.statusCount, 1)
    XCTAssertEqual(client.currentSession, originalSession)
    client.resumeStatus()
    try await waitUntil { firstFinished.value && secondFinished.value }

    do {
      _ = try await first.value
      XCTFail("The cancelled observer must not receive a usable status")
    } catch is CancellationError {
      // The observer is cancelled, not the owned shared transport.
    } catch {
      XCTFail("Unexpected cancellation error: \(error)")
    }
    let trusted = try await second.value
    XCTAssertTrue(trusted)
    XCTAssertEqual(client.statusCount, 1, "Concurrent observers must share one status request")
    XCTAssertFalse(client.statusObservedCancellation)
    XCTAssertEqual(client.currentSession, originalSession)
    XCTAssertEqual(client.stopCount, 0)

    // The capability captured before the cancelled observer is still usable.
    try await service.validateDelivery(to: capture.target, action: .copyCorrection)
    XCTAssertEqual(client.validationCount, 1)
    XCTAssertEqual(client.validations.first?.1, originalSession)
    XCTAssertTrue(client.consumptions.isEmpty)
    XCTAssertTrue(recorder.values.isEmpty)
    service.discard(capture.target)
    try await waitUntil { client.discards.count == 1 }
    await service.stop()
  }

  /// A bounded scheduler wait: failure returns instead of hanging on a fake
  /// continuation. Each test releases all fake gates in its failure cleanup.
  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("The synthetic operation did not reach its expected state", file: file, line: line)
    throw CompositionTestFailure.timedOut
  }

  /// No public test-only production API or UI construction is needed to inspect
  /// ownership. Fail explicitly if the stored-property shape changes.
  private func captureTasks(_ coordinator: WindowCoordinator) throws -> [UUID: Task<Void, Never>] {
    let member = try XCTUnwrap(Mirror(reflecting: coordinator).children.first {
      $0.label == "independentCaptureTasks"
    })
    return try XCTUnwrap(member.value as? [UUID: Task<Void, Never>])
  }

  private func assertNoPromptGateWasCreated(_ coordinator: WindowCoordinator) throws {
    for name in ["promptGatePanelController", "promptGateViewModel"] {
      let member = try XCTUnwrap(Mirror(reflecting: coordinator).children.first { $0.label == name })
      let optional = Mirror(reflecting: member.value)
      XCTAssertEqual(optional.displayStyle, .optional)
      XCTAssertTrue(optional.children.isEmpty, "Retired capture must not create \(name)")
    }
  }

  private func assertDiscardedOriginalCapture(_ client: CompositionAXClient) throws {
    let capture = try XCTUnwrap(client.captures.first)
    XCTAssertEqual(client.discards.count, 1)
    XCTAssertEqual(client.discards.first?.0, capture.capture.token)
    XCTAssertEqual(client.discards.first?.1, capture.session)
  }

  private func assertNoExternalWork(_ fixture: CompositionCoordinatorFixture) async {
    XCTAssertEqual(fixture.legacyTarget.callCount, 0, "The helper path must never fall back to main-app Accessibility")
    XCTAssertTrue(fixture.recorder.values.isEmpty)
    XCTAssertTrue(fixture.client.consumptions.isEmpty)
    let providerCalls = await fixture.grammar.callCount
    let hookCalls = await fixture.hooks.callCount
    let ipcCalls = await fixture.ipc.callCount
    XCTAssertEqual(providerCalls, 0)
    XCTAssertEqual(hookCalls, 0)
    XCTAssertEqual(ipcCalls, 0)
    XCTAssertEqual(fixture.services.packagedCorrectionWindows.phase, .idle)
  }
}

@MainActor
private final class CompositionFlag { var value = false }

private enum CompositionTestFailure: Error { case timedOut, unexpectedOperation }

/// Every store is isolated to a unique test domain or temporary directory.
/// The provider, legacy capture, hooks, IPC and OAuth transports are inert fakes.
@MainActor
private final class CompositionCoordinatorFixture {
  let client = CompositionAXClient()
  let recorder = CompositionCopyRecorder()
  let legacyTarget = CompositionUnusedTarget()
  let grammar = CompositionUnusedGrammar()
  let hooks = CompositionUnusedHooks()
  let ipc = CompositionUnusedIPC()
  let services: AppServices
  let helper: IndependentAccessibilityTargetService
  private let defaults: UserDefaults
  private let suite: String
  private let directory: URL

  init() throws {
    let suite = "com.bex.tests.independent-composition.\(UUID().uuidString)"
    self.suite = suite
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    self.defaults = defaults
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    let keychain = KeychainStore(service: suite, inMemory: true)
    helper = IndependentAccessibilityTargetService(client: client, pasteboard: recorder)
    services = AppServices(
      preferences: PreferencesStore(defaults: defaults),
      keychain: keychain,
      data: BexDataStore(fileURL: directory.appendingPathComponent("data.json")),
      learningLog: LearningLogStore(directoryURL: directory.appendingPathComponent("learning")),
      studyState: StudyStateStore(directoryURL: directory.appendingPathComponent("study")),
      considerTaps: ConsiderTapStore(directoryURL: directory.appendingPathComponent("consider")),
      writerLevel: WriterLevelStore(directoryURL: directory.appendingPathComponent("writer")),
      studyPatterns: StudyPatternStore(directoryURL: directory.appendingPathComponent("patterns")),
      grammar: grammar,
      promptGrammar: grammar,
      pasteboard: recorder,
      promptTarget: legacyTarget,
      approvalStore: PromptApprovalStore(directoryURL: directory.appendingPathComponent("receipts")),
      hookManager: hooks,
      promptGateIPC: ipc,
      codexOAuth: CodexOAuthService(keychain: keychain, transport: CompositionOfflineTransport(),
        authorizationEnabled: false, makeListener: { _ in CompositionOfflineListener() }),
      runtimeEffects: .uiTesting(hotKeyBehavior: .succeed, permitsSystemTarget: false)
    )
  }

  func coordinator() -> WindowCoordinator {
    WindowCoordinator(services: services, independentTargetService: helper)
  }

  func remove() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}

@MainActor
private final class CompositionUnusedTarget: PromptTargetServicing {
  private(set) var callCount = 0
  var isAccessibilityTrusted: Bool { callCount += 1; return false }
  func requestAccessibilityTrust() -> Bool { callCount += 1; return false }
  func makeStandaloneTarget() throws -> PromptTarget { try rejected() }
  func captureFrontmostTarget() throws -> PromptCapture { try rejected() }
  func validateDelivery(to target: PromptTarget, action: PromptDeliveryAction) throws {
    let _: Void = try rejected()
  }
  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget { try rejected() }
  func deliver(_ correctedText: String, to target: PromptTarget, pressReturn: Bool) async throws -> PromptDeliveryOutcome {
    try rejected()
  }
  func discard(_ target: PromptTarget) { callCount += 1 }
  private func rejected<T>() throws -> T {
    callCount += 1
    throw CompositionTestFailure.unexpectedOperation
  }
}

private actor CompositionUnusedGrammar: GrammarServicing, PromptGrammarServicing {
  private(set) var callCount = 0
  func check(text: String, destination: OutboundDestination, profilePrompt: String?) async throws -> GrammarResult { try rejected() }
  func checkPrompt(text: String, destination: OutboundDestination, profilePrompt: String?) async throws -> GrammarResult { try rejected() }
  func rewrite(text: String, intent: RewriteIntent, destination: OutboundDestination) async throws -> String { try rejected() }
  func define(text: String, destination: OutboundDestination) async throws -> DictionaryLookup { try rejected() }
  func answerQuestion(question: String, context: String, destination: OutboundDestination) async throws -> AskAnswer { try rejected() }
  func classifyStudyPatterns(cards: [StudyCard], destination: OutboundDestination) async throws -> [String: StudyPattern.Verdict] { try rejected() }
  func refreshWriterLevel(samples: [LearningSample], destination: OutboundDestination, now: Date) async throws -> WriterLevelProfile { try rejected() }
  func generateProfile(context: ProfileContext, destination: OutboundDestination) async throws -> String { try rejected() }
  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] { try rejected() }
  private func rejected<T>() throws -> T {
    callCount += 1
    throw CompositionTestFailure.unexpectedOperation
  }
}

private actor CompositionUnusedHooks: HookInstallationManaging {
  private(set) var callCount = 0
  func status(for client: PromptClient) async -> HookInstallationStatus {
    callCount += 1
    return .unavailable("Synthetic fixture")
  }
  func install(_ client: PromptClient) async throws { callCount += 1; throw CompositionTestFailure.unexpectedOperation }
  func uninstall(_ client: PromptClient) async throws { callCount += 1; throw CompositionTestFailure.unexpectedOperation }
}

private actor CompositionUnusedIPC: PromptGateIPCServicing, HookReviewResponding {
  private(set) var callCount = 0
  func setHandlers(onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
    onInvalidation: @escaping @Sendable (UUID) async -> Void) async { callCount += 1 }
  func start() async throws { callCount += 1; throw CompositionTestFailure.unexpectedOperation }
  func stop() async { callCount += 1 }
  func complete(requestID: UUID, outcome: HookReviewOutcome, awaitAcknowledgement: Bool,
    approvedPrompt: String?, integrationID: String?) async throws {
    callCount += 1
    throw CompositionTestFailure.unexpectedOperation
  }
}

private struct CompositionOfflineTransport: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw CompositionTestFailure.unexpectedOperation
  }
}

private struct CompositionOfflineListener: CodexOAuthListening {
  func start() async throws { throw CompositionTestFailure.unexpectedOperation }
  func waitForCallback() async throws -> URL { throw CompositionTestFailure.unexpectedOperation }
  func stop() async {}
}
