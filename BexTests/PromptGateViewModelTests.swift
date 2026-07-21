import Foundation
import XCTest

@testable import Bex

@MainActor
final class PromptGateViewModelTests: XCTestCase {
  func testDisclosureOnboardingThenCorrectionUsesFrozenOriginalSnapshot() async throws {
    let fixture = try await Fixture(disclosureAccepted: false)
    let session = fixture.standardSession(text: "This are original.")

    XCTAssertTrue(fixture.viewModel.begin(session))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .onboarding)

    fixture.viewModel.acceptDisclosure()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    XCTAssertEqual(fixture.viewModel.review?.original, "This are original.")
    XCTAssertEqual(fixture.viewModel.review?.corrected, "This is original.")
  }

  func testReviewEditRecomputesDiffAndBlankCorrectionCannotBeApproved() async throws {
    let fixture = try await Fixture()
    XCTAssertTrue(fixture.viewModel.begin(fixture.standardSession(text: "This are original.")))
    await fixture.viewModel.waitForCurrentWork()

    fixture.viewModel.updateCorrected("This is edited.")
    XCTAssertEqual(fixture.viewModel.review?.corrected, "This is edited.")
    XCTAssertTrue(fixture.viewModel.review?.diff.contains { $0.kind != .unchanged } == true)

    fixture.viewModel.updateCorrected("  \n")
    XCTAssertFalse(fixture.viewModel.canApprove)
    fixture.viewModel.approve()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    XCTAssertEqual(fixture.target.deliveries.count, 0)
  }

  func testStandardApprovalDoesNotIssueHookReceiptAndHonorsSubmitPreference() async throws {
    let fixture = try await Fixture()
    await fixture.hooks.setStatus(.active(lastSeen: Date()))
    XCTAssertTrue(fixture.viewModel.begin(fixture.standardSession(text: "This are original.")))
    await fixture.viewModel.waitForCurrentWork()

    fixture.viewModel.approve()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.phase, .closed)
    XCTAssertEqual(fixture.target.deliveries.map(\.text), ["This is original."])
    XCTAssertEqual(fixture.target.deliveries.map(\.pressReturn), [true])
    let receiptDirectoryExists = FileManager.default.fileExists(
      atPath: fixture.receiptDirectory.path
    )
    if receiptDirectoryExists {
      XCTAssertTrue(
        try FileManager.default.contentsOfDirectory(atPath: fixture.receiptDirectory.path).isEmpty
      )
    }
  }

  func testHookApprovalRequiresLiveInstallationAndRevokesReceiptWhenAcknowledgementFails() async throws {
    let fixture = try await Fixture()
    let requestID = UUID()
    let session = fixture.hookSession(requestID: requestID, text: "This are original.")

    await fixture.hooks.setStatus(.notInstalled)
    XCTAssertTrue(fixture.viewModel.begin(session))
    await fixture.viewModel.waitForCurrentWork()
    fixture.viewModel.approve()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    XCTAssertTrue(fixture.viewModel.errorMessage?.contains("authorize") == true)
    let inactiveCalls = await fixture.responder.recordedCalls()
    XCTAssertEqual(inactiveCalls.count, 0)

    await fixture.hooks.setStatus(.active(lastSeen: Date()))
    await fixture.responder.setError(BexError.promptDeliveryFailed("ack failed"))
    fixture.viewModel.approve()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    XCTAssertTrue(fixture.viewModel.errorMessage?.contains("ack failed") == true)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.receiptDirectory.path).isEmpty)
    XCTAssertEqual(fixture.target.deliveries.count, 0)
  }

  func testHookApprovalAcknowledgesBeforeComposerDeliveryAndNeverPressesReturn() async throws {
    let fixture = try await Fixture()
    let requestID = UUID()
    await fixture.hooks.setStatus(.active(lastSeen: Date()))
    XCTAssertTrue(fixture.viewModel.begin(fixture.hookSession(requestID: requestID, text: "This are original.")))
    await fixture.viewModel.waitForCurrentWork()

    fixture.viewModel.approve()
    await fixture.viewModel.waitForCurrentWork()

    let calls = await fixture.responder.recordedCalls()
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.requestID, requestID)
    XCTAssertEqual(calls.first?.outcome, .approved)
    XCTAssertEqual(calls.first?.awaitAcknowledgement, true)
    XCTAssertEqual(fixture.target.deliveries.map(\.pressReturn), [false])
    XCTAssertEqual(fixture.viewModel.phase, .closed)
  }

  func testCancellationAndInvalidationPreventLateCorrectionFromCrossingSessions() async throws {
    let grammar = SuspendedPromptGrammar()
    let fixture = try await Fixture(grammar: grammar)
    let requestID = UUID()
    XCTAssertTrue(fixture.viewModel.begin(fixture.hookSession(requestID: requestID, text: "First draft")))
    await grammar.waitUntilStarted()

    fixture.viewModel.invalidateHookRequest(id: requestID)
    XCTAssertEqual(fixture.viewModel.phase, .invalidated)
    await grammar.resume(with: GrammarResult(corrected: "Late result", explanation: "late"))
    await Task.yield()

    XCTAssertEqual(fixture.viewModel.phase, .invalidated)
    XCTAssertNil(fixture.viewModel.review)
    XCTAssertFalse(fixture.viewModel.begin(fixture.standardSession(text: "Second draft")))
  }
}

private actor StubPromptGrammar: PromptGrammarServicing {
  func checkPrompt(text: String, provider: LLMProvider, model: String) async throws -> GrammarResult {
    GrammarResult(
      corrected: text.replacingOccurrences(of: " are ", with: " is "),
      explanation: "Fixed agreement."
    )
  }
}

private actor SuspendedPromptGrammar: PromptGrammarServicing {
  private var resultContinuation: CheckedContinuation<GrammarResult, Never>?
  private var startContinuation: CheckedContinuation<Void, Never>?

  func checkPrompt(text: String, provider: LLMProvider, model: String) async throws -> GrammarResult {
    startContinuation?.resume()
    startContinuation = nil
    return await withCheckedContinuation { resultContinuation = $0 }
  }

  func waitUntilStarted() async {
    if resultContinuation != nil { return }
    await withCheckedContinuation { startContinuation = $0 }
  }

  func resume(with result: GrammarResult) {
    resultContinuation?.resume(returning: result)
    resultContinuation = nil
  }
}

private actor StubHookManager: HookInstallationManaging {
  private var installationStatus: HookInstallationStatus = .notInstalled

  func setStatus(_ status: HookInstallationStatus) { installationStatus = status }
  func status(for client: PromptClient) async -> HookInstallationStatus { installationStatus }
  func install(_ client: PromptClient) async throws {}
  func uninstall(_ client: PromptClient) async throws {}
}

private actor StubHookResponder: HookReviewResponding {
  struct Call: Sendable {
    let requestID: UUID
    let outcome: HookReviewOutcome
    let awaitAcknowledgement: Bool
  }

  private var calls: [Call] = []
  private var error: Error?

  func setError(_ error: Error?) { self.error = error }
  func recordedCalls() -> [Call] { calls }

  func complete(
    requestID: UUID,
    outcome: HookReviewOutcome,
    awaitAcknowledgement: Bool
  ) async throws {
    calls.append(Call(
      requestID: requestID,
      outcome: outcome,
      awaitAcknowledgement: awaitAcknowledgement
    ))
    if let error { throw error }
  }
}

@MainActor
private final class StubPromptTarget: PromptTargetServicing {
  struct Delivery {
    let text: String
    let target: PromptTarget
    let pressReturn: Bool
  }

  var isAccessibilityTrusted = true
  var deliveries: [Delivery] = []
  var discarded: [PromptTarget] = []

  func requestAccessibilityTrust() -> Bool { isAccessibilityTrusted }
  func captureFrontmostTarget() throws -> PromptCapture { fatalError("Not used") }
  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget { fatalError("Not used") }

  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome {
    deliveries.append(Delivery(text: correctedText, target: target, pressReturn: pressReturn))
    return pressReturn ? .submitted : .pasted
  }

  func discard(_ target: PromptTarget) { discarded.append(target) }
}

@MainActor
private final class Fixture {
  let viewModel: PromptGateViewModel
  let target = StubPromptTarget()
  let hooks = StubHookManager()
  let responder = StubHookResponder()
  let receiptDirectory: URL

  init(
    disclosureAccepted: Bool = true,
    grammar: any PromptGrammarServicing = StubPromptGrammar()
  ) async throws {
    let suite = "com.bex.tests.prompt-gate-vm.\(UUID().uuidString)"
    let preferences = makePromptGatePreferences(suite: suite)
    await preferences.setPromptGateDisclosureAccepted(disclosureAccepted)
    let keychain = KeychainStore(service: suite, inMemory: true)
    try await keychain.saveAPIKey("secret", for: .openAI)
    receiptDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PromptGateReceipts-\(UUID().uuidString)", isDirectory: true)
    let approvalStore = PromptApprovalStore(directoryURL: receiptDirectory)

    viewModel = PromptGateViewModel(
      preferences: preferences,
      keychain: keychain,
      promptGrammar: grammar,
      targetService: target,
      approvalStore: approvalStore,
      hookManager: hooks,
      hookResponder: responder,
      onClose: {},
      onOpenSettings: {}
    )
  }

  deinit {
    try? FileManager.default.removeItem(at: receiptDirectory)
  }

  func standardSession(text: String) -> PromptGateSession {
    PromptGateSession(
      initialDraft: text,
      target: PromptTarget(
        kind: .capturedField,
        processID: 100,
        bundleID: "com.example.editor",
        applicationName: "Editor",
        guidance: "Captured field"
      ),
      source: .capturedField
    )
  }

  func hookSession(requestID: UUID, text: String) -> PromptGateSession {
    PromptGateSession(
      initialDraft: text,
      target: PromptTarget(
        kind: .composerPaste,
        processID: 200,
        bundleID: "com.example.terminal",
        applicationName: "Terminal",
        guidance: "Paste manually",
        hookContext: PromptHookContext(
          requestID: requestID,
          sessionID: "session-1",
          cwd: "/tmp/project",
          helperPID: 123
        )
      ),
      knownClient: .claudeCode,
      source: .hook(requestID: requestID)
    )
  }
}

private func makePromptGatePreferences(suite: String) -> PreferencesStore {
  PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
}
