import Foundation
import XCTest

@testable import Bex

private struct PromptGrammarCall: Equatable, Sendable {
  let text: String
  let provider: LLMProvider
  let model: String
  let ollamaEndpoint: String?
}

@MainActor
final class PromptGateViewModelTests: XCTestCase {
  func testConsentMatrixUsesSourceAndDestinationScopedDisclosure() async throws {
    let captured = try await Fixture(acceptedDisclosure: true)
    XCTAssertTrue(
      captured.viewModel.begin(
        captured.capturedSession(text: "This are original.")
      ))
    XCTAssertEqual(captured.viewModel.phase, .onboarding)
    XCTAssertTrue(captured.viewModel.isLoadingSession)
    await captured.viewModel.waitForCurrentWork()
    XCTAssertFalse(captured.viewModel.isLoadingSession)
    XCTAssertEqual(captured.viewModel.phase, .reviewing)

    let ambiguousManual = try await Fixture(acceptedDisclosure: true)
    XCTAssertTrue(
      ambiguousManual.viewModel.begin(
        ambiguousManual.composerSession(text: "This are original.")
      ))
    await ambiguousManual.viewModel.waitForCurrentWork()
    XCTAssertEqual(ambiguousManual.viewModel.phase, .onboarding)

    let hook = try await Fixture(acceptedDisclosure: true)
    XCTAssertTrue(
      hook.viewModel.begin(
        hook.hookSession(requestID: UUID(), text: "This are original.")
      ))
    await hook.viewModel.waitForCurrentWork()
    XCTAssertEqual(hook.viewModel.phase, .onboarding)
  }

  func testConsentNamesProviderAndModelAndShowsMaskedPayloadWithoutWritingStyle() async throws {
    let fixture = try await Fixture(
      acceptedDisclosure: false
    )
    let source = "Explain `swift test` to the teammate. Project alpha is ordinary prose."
    XCTAssertTrue(fixture.viewModel.begin(fixture.capturedSession(text: source)))
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.phase, .onboarding)
    XCTAssertTrue(fixture.viewModel.providerDisclosure.contains("OpenAI"))
    XCTAssertTrue(fixture.viewModel.providerDisclosure.contains(fixture.viewModel.selectedModel))
    XCTAssertFalse(fixture.viewModel.providerDisclosure.contains("Writing Style"))
    XCTAssertFalse(fixture.viewModel.outboundPayload.contains("swift test"))
    XCTAssertTrue(fixture.viewModel.outboundPayload.contains("Project alpha is ordinary prose"))
    XCTAssertTrue(fixture.viewModel.protectedSpanDisclosure.contains("fenced and inline code"))
    XCTAssertTrue(
      fixture.viewModel.protectedSpanDisclosure.contains("restores those recognized spans locally"))
    XCTAssertTrue(fixture.viewModel.protectedSpanDisclosure.contains("Unmatched prose"))

    fixture.viewModel.acceptDisclosure()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.review?.original, source)
    let acceptedDestination = try await fixture.preferences.outboundDestination()
    let acceptedOpenAI = await fixture.preferences.hasAcceptedCurrentOutboundDisclosure(
      for: acceptedDestination
    )
    XCTAssertTrue(acceptedOpenAI)

    fixture.viewModel.cancel()
    await fixture.viewModel.waitForCurrentWork()
    await fixture.preferences.setSelectedProvider(.claude)
    await fixture.preferences.setSelectedModel("claude-test-model", for: .claude)
    XCTAssertTrue(fixture.viewModel.begin(fixture.capturedSession(text: "Another prompt")))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .composing)
    XCTAssertTrue(fixture.viewModel.needsProviderSetup)
    XCTAssertTrue(fixture.viewModel.providerDisclosure.contains("Claude"))
    XCTAssertTrue(fixture.viewModel.providerDisclosure.contains("claude-test-model"))
  }

  func testComposerConfirmsOnlyAfterDraftExistsAndEveryChangedRequest() async throws {
    let fixture = try await Fixture(
      acceptedDisclosure: true
    )
    XCTAssertTrue(fixture.viewModel.begin(fixture.composerSession(text: "")))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .composing)

    fixture.viewModel.draft = "First manual prompt"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .onboarding)
    fixture.viewModel.acceptDisclosure()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)

    fixture.viewModel.backToEdit()
    fixture.viewModel.draft = "Changed manual prompt"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .onboarding)
  }

  func testCheckpointReturnsWithoutRequestAndChangedSourceRechecks() async throws {
    let grammar = RecordingPromptGrammar()
    let fixture = try await Fixture(grammar: grammar)
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()
    let initialCalls = await grammar.recordedCalls()
    XCTAssertEqual(initialCalls.map(\.text), ["This are original."])
    XCTAssertEqual(initialCalls.map(\.provider), [.openAI])
    XCTAssertEqual(initialCalls.map(\.model), ["gpt-test-model"])
    XCTAssertNil(initialCalls.first?.ollamaEndpoint)

    fixture.viewModel.backToEdit()
    XCTAssertEqual(fixture.viewModel.composerPrimaryActionLabel, "Return to Review")
    fixture.viewModel.check()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    let callsAfterReturn = await grammar.recordedCalls()
    XCTAssertEqual(callsAfterReturn.map(\.text), ["This are original."])

    fixture.viewModel.backToEdit()
    fixture.viewModel.draft = "Those are changed."
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.review?.original, "Those are changed.")
    let callsAfterRecheck = await grammar.recordedCalls()
    XCTAssertEqual(
      callsAfterRecheck.map(\.text),
      ["This are original.", "Those are changed."]
    )
  }

  func testHumanEditedCheckpointRequiresReplacementConfirmation() async throws {
    let grammar = RecordingPromptGrammar()
    let fixture = try await Fixture(grammar: grammar)
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()

    fixture.viewModel.updateCorrected("My carefully edited correction.")
    fixture.viewModel.backToEdit()
    fixture.viewModel.draft = "A changed source draft."
    fixture.viewModel.check()

    XCTAssertTrue(fixture.viewModel.showsCheckpointReplacementConfirmation)
    XCTAssertEqual(fixture.viewModel.focusRequest?.accessibility, .discardAlert)
    XCTAssertEqual(fixture.viewModel.phase, .composing)
    let callsBeforeReplacement = await grammar.recordedCalls()
    XCTAssertEqual(callsBeforeReplacement.count, 1)

    fixture.viewModel.keepCheckpoint()
    XCTAssertFalse(fixture.viewModel.showsCheckpointReplacementConfirmation)
    fixture.viewModel.check()
    fixture.viewModel.confirmCheckpointReplacement()
    await fixture.viewModel.waitForCurrentWork()

    let callsAfterReplacement = await grammar.recordedCalls()
    XCTAssertEqual(callsAfterReplacement.count, 2)
    XCTAssertEqual(fixture.viewModel.review?.original, "A changed source draft.")
    XCTAssertFalse(fixture.viewModel.showsCheckpointReplacementConfirmation)
  }

  func testOnlyHumanCorrectionEditsTriggerDiscardWarning() async throws {
    let aiOnly = try await Fixture()
    XCTAssertTrue(aiOnly.viewModel.begin(aiOnly.capturedSession(text: "This are original.")))
    await aiOnly.viewModel.waitForCurrentWork()
    aiOnly.viewModel.cancel()
    await aiOnly.viewModel.waitForCurrentWork()
    XCTAssertEqual(aiOnly.viewModel.phase, .closed)
    XCTAssertFalse(aiOnly.viewModel.showsDiscardConfirmation)

    let humanEdited = try await Fixture()
    XCTAssertTrue(
      humanEdited.viewModel.begin(
        humanEdited.capturedSession(text: "This are original.")
      ))
    await humanEdited.viewModel.waitForCurrentWork()
    let aiCorrection = try XCTUnwrap(humanEdited.viewModel.review?.aiCorrected)
    humanEdited.viewModel.updateCorrected("A human correction.")
    humanEdited.viewModel.cancel()
    XCTAssertEqual(humanEdited.viewModel.phase, .reviewing)
    XCTAssertTrue(humanEdited.viewModel.showsDiscardConfirmation)
    XCTAssertEqual(humanEdited.viewModel.focusRequest?.accessibility, .discardAlert)

    humanEdited.viewModel.keepEditing()
    humanEdited.viewModel.updateCorrected(aiCorrection)
    humanEdited.viewModel.cancel()
    await humanEdited.viewModel.waitForCurrentWork()
    XCTAssertEqual(humanEdited.viewModel.phase, .closed)
    XCTAssertFalse(humanEdited.viewModel.showsDiscardConfirmation)
  }

  func testNoChangeReviewIsEditableAndTransitionsToChangedReview() async throws {
    let grammar = RecordingPromptGrammar(mode: .unchanged)
    let fixture = try await Fixture(grammar: grammar)
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "Already correct.")
      ))
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertTrue(fixture.viewModel.isNoChangeReview)
    XCTAssertEqual(fixture.viewModel.accessibleDiffSummary, "No differences")
    fixture.viewModel.updateCorrected("Already correct, with an edit.")
    XCTAssertFalse(fixture.viewModel.isNoChangeReview)
    XCTAssertNotEqual(fixture.viewModel.accessibleDiffSummary, "No differences")
    XCTAssertTrue(fixture.viewModel.canApprove)
  }

  func testFocusAndAnnouncementsFollowConsentCheckingAndReviewMatrix() async throws {
    let grammar = SuspendedPromptGrammar()
    let fixture = try await Fixture(
      acceptedDisclosure: false,
      grammar: grammar
    )
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.focusRequest?.keyboard, .primaryAction)
    XCTAssertEqual(fixture.viewModel.focusRequest?.accessibility, .disclosureHeading)
    XCTAssertEqual(fixture.viewModel.accessibilityAnnouncementHistory.count, 1)

    fixture.viewModel.acceptDisclosure()
    await grammar.waitUntilStarted()
    XCTAssertEqual(fixture.viewModel.phase, .checking)
    XCTAssertEqual(fixture.viewModel.accessibilityAnnouncementHistory.count, 2)
    XCTAssertTrue(fixture.viewModel.accessibilityAnnouncementHistory[1].contains("Checking"))

    await grammar.resume(
      with: GrammarResult(
        corrected: "This is original.",
        explanation: "Fixed agreement."
      ))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.focusRequest?.keyboard, .correctedEditor)
    XCTAssertEqual(fixture.viewModel.focusRequest?.accessibility, .changesHeading)
    XCTAssertEqual(fixture.viewModel.accessibilityAnnouncementHistory.count, 3)
    XCTAssertTrue(fixture.viewModel.accessibilityAnnouncementHistory[2].contains("Changes ready"))

    fixture.viewModel.backToEdit()
    XCTAssertEqual(fixture.viewModel.focusRequest?.keyboard, .draftEditor)
    XCTAssertEqual(fixture.viewModel.focusRequest?.accessibility, .composerHeading)
  }

  func testTargetActionsNameDestinationAndDescribeExactEffect() async throws {
    let fixture = try await Fixture()
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(
      fixture.viewModel.availableDeliveryActions,
      [.pasteInDestination, .pasteAndSubmit]
    )
    XCTAssertEqual(fixture.viewModel.primaryDeliveryAction, .pasteAndSubmit)
    XCTAssertEqual(
      fixture.viewModel.deliveryActionLabel(.pasteInDestination),
      "Paste in Editor"
    )
    XCTAssertEqual(
      fixture.viewModel.deliveryActionLabel(.pasteAndSubmit),
      "Paste & Send in Editor"
    )
    XCTAssertTrue(
      fixture.viewModel.deliveryEffectDescription(for: .pasteInDestination)
        .contains("will not press Return")
    )
    XCTAssertTrue(
      fixture.viewModel.deliveryEffectDescription(for: .pasteAndSubmit)
        .contains("presses Return once")
    )
  }

  func testNoEffectFailureAllowsRetryButPartialPasteNeverRepastes() async throws {
    let safeRetry = try await Fixture()
    XCTAssertTrue(
      safeRetry.viewModel.begin(
        safeRetry.capturedSession(text: "This are original.")
      ))
    await safeRetry.viewModel.waitForCurrentWork()
    safeRetry.target.deliveryError = PromptDeliveryFailure(
      effect: .none,
      underlyingError: BexError.promptDeliveryFailed("Could not activate target.")
    )
    safeRetry.viewModel.approve()
    await safeRetry.viewModel.waitForCurrentWork()

    XCTAssertEqual(safeRetry.viewModel.deliveryFailureEffect, PromptDeliveryEffect.none)
    XCTAssertTrue(safeRetry.viewModel.canApprove)
    XCTAssertFalse(safeRetry.viewModel.availableDeliveryActions.isEmpty)
    XCTAssertTrue(safeRetry.viewModel.errorMessage?.contains("Nothing was delivered") == true)

    safeRetry.target.deliveryError = nil
    safeRetry.viewModel.approve()
    await safeRetry.viewModel.waitForCurrentWork()
    XCTAssertEqual(safeRetry.target.deliveries.count, 2)
    XCTAssertEqual(safeRetry.viewModel.phase, .closed)

    let partial = try await Fixture()
    XCTAssertTrue(
      partial.viewModel.begin(
        partial.capturedSession(text: "This are original.")
      ))
    await partial.viewModel.waitForCurrentWork()
    let correction = try XCTUnwrap(partial.viewModel.review?.corrected)
    partial.target.deliveryError = PromptDeliveryFailure(
      effect: .pastedNotSubmitted,
      underlyingError: BexError.promptDeliveryFailed("Return failed.")
    )
    partial.viewModel.approve()
    await partial.viewModel.waitForCurrentWork()

    XCTAssertEqual(partial.viewModel.deliveryFailureEffect, .pastedNotSubmitted)
    XCTAssertEqual(partial.viewModel.review?.corrected, correction)
    XCTAssertFalse(partial.viewModel.canApprove)
    XCTAssertTrue(partial.viewModel.availableDeliveryActions.isEmpty)
    XCTAssertTrue(partial.viewModel.errorMessage?.contains("already in Editor") == true)
    XCTAssertTrue(partial.viewModel.errorMessage?.contains("Press Return there") == true)
    XCTAssertTrue(partial.viewModel.errorMessage?.contains("will not paste it again") == true)
    partial.viewModel.approve()
    XCTAssertEqual(partial.target.deliveries.count, 1)
  }

  func testTerminalDeliveryEffectsSuppressNavigationAndIgnoreBack() async throws {
    for effect in [
      PromptDeliveryEffect.copied,
      .pastedNotSubmitted,
      .unknown,
    ] {
      let fixture = try await Fixture()
      XCTAssertTrue(
        fixture.viewModel.begin(
          fixture.capturedSession(text: "This are original.")
        ))
      await fixture.viewModel.waitForCurrentWork()
      let review = try XCTUnwrap(fixture.viewModel.review)
      fixture.target.deliveryError = PromptDeliveryFailure(
        effect: effect,
        underlyingError: BexError.promptDeliveryFailed("Terminal delivery failure.")
      )

      fixture.viewModel.approve()
      await fixture.viewModel.waitForCurrentWork()

      XCTAssertEqual(fixture.viewModel.phase, .reviewing)
      XCTAssertEqual(fixture.viewModel.deliveryFailureEffect, effect)
      XCTAssertTrue(fixture.viewModel.hasTerminalDeliveryFailure)
      XCTAssertTrue(fixture.viewModel.availableDeliveryActions.isEmpty)
      fixture.viewModel.backToEdit()
      XCTAssertEqual(fixture.viewModel.phase, .reviewing)
      XCTAssertEqual(fixture.viewModel.review, review)
      XCTAssertEqual(fixture.viewModel.deliveryFailureEffect, effect)
      XCTAssertEqual(fixture.target.deliveries.count, 1)
    }
  }

  func testCancelDuringDeliveryIsIgnoredUntilFailureEffectIsSurfaced() async throws {
    let fixture = try await Fixture()
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()
    fixture.target.suspendsDelivery = true
    fixture.target.deliveryError = PromptDeliveryFailure(
      effect: .unknown,
      underlyingError: BexError.promptDeliveryFailed("Delivery state is unknown.")
    )

    fixture.viewModel.approve()
    await fixture.target.waitUntilDeliveryStarted()
    XCTAssertEqual(fixture.viewModel.phase, .delivering)

    fixture.viewModel.cancel()
    XCTAssertEqual(fixture.viewModel.phase, .delivering)
    XCTAssertNotNil(fixture.viewModel.session)
    XCTAssertTrue(fixture.target.discarded.isEmpty)

    fixture.target.resumeDelivery()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    XCTAssertEqual(fixture.viewModel.deliveryFailureEffect, .unknown)
    XCTAssertTrue(fixture.viewModel.hasTerminalDeliveryFailure)
  }

  func testHookAlwaysConfirmsAcknowledgesThenUsesPasteOnlyAction() async throws {
    let fixture = try await Fixture()
    let requestID = UUID()
    await fixture.hooks.setStatus(.active(lastSeen: Date()))
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.hookSession(requestID: requestID, text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .onboarding)

    fixture.viewModel.acceptDisclosure()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.availableDeliveryActions, [.pasteInDestination])
    XCTAssertTrue(
      fixture.viewModel.deliveryActionLabel(.pasteInDestination)
        .hasPrefix("Acknowledge &")
    )

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

  func testHookAcknowledgementFailureIsUnknownAndCannotBeRetried() async throws {
    let fixture = try await Fixture()
    await fixture.hooks.setStatus(.active(lastSeen: Date()))
    await fixture.responder.setError(BexError.promptDeliveryFailed("ack failed"))
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.hookSession(requestID: UUID(), text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()
    fixture.viewModel.acceptDisclosure()
    await fixture.viewModel.waitForCurrentWork()

    fixture.viewModel.approve()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.deliveryFailureEffect, .unknown)
    XCTAssertFalse(fixture.viewModel.canApprove)
    XCTAssertTrue(fixture.viewModel.availableDeliveryActions.isEmpty)
    XCTAssertEqual(fixture.target.deliveries.count, 0)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(
        atPath: fixture.receiptDirectory.path
      ).isEmpty)
  }

  func testPermissionGuidanceDistinguishesManualCaptureAndHookSupply() async throws {
    let manual = try await Fixture(accessibilityTrusted: false)
    XCTAssertTrue(manual.viewModel.begin(manual.composerSession(text: "")))
    await manual.viewModel.waitForCurrentWork()
    XCTAssertTrue(manual.viewModel.permissionGuidance.contains("manual capture"))
    XCTAssertTrue(manual.viewModel.permissionGuidance.contains("Enabled client hooks"))

    manual.viewModel.requestAccessibility()
    XCTAssertTrue(
      manual.viewModel.accessibilityStatusMessage?.contains("invoke Fix & Send again") == true)
    manual.target.isAccessibilityTrusted = true
    manual.viewModel.refreshAccessibilityState()
    XCTAssertTrue(
      manual.viewModel.accessibilityStatusMessage?.contains("Invoke Fix & Send again") == true)

    let hook = try await Fixture(accessibilityTrusted: false)
    XCTAssertTrue(
      hook.viewModel.begin(
        hook.hookSession(requestID: UUID(), text: "Hook prompt")
      ))
    await hook.viewModel.waitForCurrentWork()
    XCTAssertTrue(hook.viewModel.permissionGuidance.contains("hook supplied the prompt"))
    XCTAssertTrue(hook.viewModel.permissionGuidance.contains("still review"))
  }

  func testMissingProviderSetupFocusesRecoveryWithoutStartingCorrection() async throws {
    let grammar = RecordingPromptGrammar()
    let fixture = try await Fixture(providerSetUp: false, grammar: grammar)
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "Keep this draft.")
      ))
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.phase, .composing)
    XCTAssertTrue(fixture.viewModel.needsProviderSetup)
    XCTAssertFalse(fixture.viewModel.canReview)
    XCTAssertEqual(fixture.viewModel.focusRequest?.keyboard, .recoveryAction)
    XCTAssertEqual(fixture.viewModel.focusRequest?.accessibility, .errorHeading)
    XCTAssertTrue(fixture.viewModel.errorMessage?.contains("OpenAI") == true)
    let calls = await grammar.recordedCalls()
    XCTAssertTrue(calls.isEmpty)
  }

  func testConfigurationRefreshPreservesSessionAndDoesNotStartCorrection() async throws {
    let grammar = RecordingPromptGrammar()
    let fixture = try await Fixture(
      acceptedDisclosure: true,
      grammar: grammar
    )
    let source = "Preserve this manual draft."
    XCTAssertTrue(fixture.viewModel.begin(fixture.capturedSession(text: source)))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    let callsBeforeRefresh = await grammar.recordedCalls()
    XCTAssertEqual(callsBeforeRefresh.map(\.text), [source])

    await fixture.preferences.setSelectedProvider(.claude)
    await fixture.preferences.setSelectedModel("claude-refreshed-model", for: .claude)
    let refreshedDestination = try await fixture.preferences.outboundDestination()
    await fixture.preferences.acceptCurrentOutboundDisclosure(for: refreshedDestination)
    fixture.target.isAccessibilityTrusted = false

    await fixture.viewModel.refreshConfigurationAfterSettings()

    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    XCTAssertEqual(fixture.viewModel.draft, source)
    XCTAssertEqual(fixture.viewModel.selectedProvider, .claude)
    XCTAssertEqual(fixture.viewModel.selectedModel, "claude-refreshed-model")
    XCTAssertFalse(fixture.viewModel.providerIsSetUp)
    XCTAssertTrue(fixture.viewModel.providerDisclosureIsAccepted)
    XCTAssertFalse(fixture.viewModel.isAccessibilityTrusted)
    let callsAfterRefresh = await grammar.recordedCalls()
    XCTAssertEqual(callsAfterRefresh, callsBeforeRefresh)
  }

  func testExistingAcceptedManualSessionRecheckProceedsDirectly() async throws {
    let grammar = RecordingPromptGrammar()
    let fixture = try await Fixture(
      acceptedDisclosure: true,
      grammar: grammar
    )
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "This are original.")
      ))
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.phase, .reviewing)

    fixture.viewModel.backToEdit()
    fixture.viewModel.draft = "This are changed."
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.phase, .reviewing)
    let calls = await grammar.recordedCalls()
    XCTAssertEqual(calls.map(\.text), ["This are original.", "This are changed."])
  }

  func testConsentPreviewPayloadIsExactTransportPayloadAndProtectedSpansRestore() async throws {
    let grammar = RecordingPromptGrammar()
    let fixture = try await Fixture(
      acceptedDisclosure: false,
      grammar: grammar
    )
    let source = "Review `/tmp/a.swift` because this are wrong."
    XCTAssertTrue(fixture.viewModel.begin(fixture.capturedSession(text: source)))
    await fixture.viewModel.waitForCurrentWork()

    let preview = fixture.viewModel.outboundPayload
    XCTAssertFalse(preview.contains("/tmp/a.swift"))
    XCTAssertTrue(preview.contains("BEX_PROTECTED_"))

    fixture.viewModel.acceptDisclosure()
    await fixture.viewModel.waitForCurrentWork()

    let calls = await grammar.recordedCalls()
    XCTAssertEqual(calls.map(\.text), [preview])
    XCTAssertEqual(
      fixture.viewModel.review?.corrected,
      "Review `/tmp/a.swift` because this is wrong."
    )
  }

  func testCancellationAndInvalidationPreventLateCorrectionFromCrossingSessions() async throws {
    let grammar = SuspendedPromptGrammar()
    let fixture = try await Fixture(grammar: grammar)
    let requestID = UUID()
    XCTAssertTrue(
      fixture.viewModel.begin(
        fixture.hookSession(requestID: requestID, text: "First draft")
      ))
    await fixture.viewModel.waitForCurrentWork()
    fixture.viewModel.acceptDisclosure()
    await grammar.waitUntilStarted()

    fixture.viewModel.invalidateHookRequest(id: requestID)
    XCTAssertEqual(fixture.viewModel.phase, .invalidated)
    XCTAssertEqual(fixture.viewModel.focusRequest?.keyboard, .recoveryAction)
    XCTAssertEqual(fixture.viewModel.focusRequest?.accessibility, .statusHeading)
    await grammar.resume(with: GrammarResult(corrected: "Late result", explanation: "late"))
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.phase, .invalidated)
    XCTAssertNil(fixture.viewModel.review)
    XCTAssertFalse(
      fixture.viewModel.begin(
        fixture.capturedSession(text: "Second draft")
      ))
  }
}

private actor RecordingPromptGrammar: PromptGrammarServicing {

  enum Mode: Equatable, Sendable {
    case corrected
    case unchanged
  }

  private let mode: Mode
  private var calls: [PromptGrammarCall] = []

  init(mode: Mode = .corrected) {
    self.mode = mode
  }

  func checkPrompt(
    text: String,
    destination: OutboundDestination
  ) async throws -> GrammarResult {
    calls.append(
      PromptGrammarCall(
        text: text,
        provider: destination.provider,
        model: destination.model,
        ollamaEndpoint: destination.ollamaEndpoint
      )
    )
    let corrected =
      mode == .unchanged
      ? text
      : text.replacingOccurrences(of: " are ", with: " is ")
    return GrammarResult(corrected: corrected, explanation: "Checked grammar.")
  }

  func checkPrompt(
    protectedText: PromptTechnicalSpanProtector.ProtectedText,
    destination: OutboundDestination
  ) async throws -> GrammarResult {
    calls.append(
      PromptGrammarCall(
        text: protectedText.masked,
        provider: destination.provider,
        model: destination.model,
        ollamaEndpoint: destination.ollamaEndpoint
      )
    )
    let corrected =
      mode == .unchanged
      ? protectedText.masked
      : protectedText.masked.replacingOccurrences(of: " are ", with: " is ")
    return GrammarResult(
      corrected: try protectedText.restore(corrected),
      explanation: "Checked grammar."
    )
  }
  func recordedCalls() -> [PromptGrammarCall] { calls }
}

private actor SuspendedPromptGrammar: PromptGrammarServicing {

  private var resultContinuation: CheckedContinuation<GrammarResult, Never>?
  private var startContinuation: CheckedContinuation<Void, Never>?

  func checkPrompt(
    text: String,
    destination: OutboundDestination
  ) async throws -> GrammarResult {
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
    awaitAcknowledgement: Bool,
    approvedPrompt: String?,
    integrationID: String?
  ) async throws {
    calls.append(
      Call(
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

  var isAccessibilityTrusted: Bool
  var deliveries: [Delivery] = []
  var discarded: [PromptTarget] = []
  var deliveryError: Error?
  var deliveryOutcome: PromptDeliveryOutcome?
  var suspendsDelivery = false
  private var deliveryContinuation: CheckedContinuation<Void, Never>?
  private var deliveryStartContinuation: CheckedContinuation<Void, Never>?

  init(isAccessibilityTrusted: Bool) {
    self.isAccessibilityTrusted = isAccessibilityTrusted
  }

  func requestAccessibilityTrust() -> Bool { isAccessibilityTrusted }
  func captureFrontmostTarget() throws -> PromptCapture { fatalError("Not used") }
  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget { fatalError("Not used") }

  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome {
    if suspendsDelivery {
      deliveryStartContinuation?.resume()
      deliveryStartContinuation = nil
      await withCheckedContinuation { deliveryContinuation = $0 }
    }
    deliveries.append(Delivery(text: correctedText, target: target, pressReturn: pressReturn))
    if let deliveryError { throw deliveryError }
    if let deliveryOutcome { return deliveryOutcome }
    if target.kind == .copyOnly { return .copied }
    return pressReturn ? .submitted : .pasted
  }

  func waitUntilDeliveryStarted() async {
    if deliveryContinuation != nil { return }
    await withCheckedContinuation { deliveryStartContinuation = $0 }
  }

  func resumeDelivery() {
    deliveryContinuation?.resume()
    deliveryContinuation = nil
  }

  func discard(_ target: PromptTarget) { discarded.append(target) }
}

@MainActor
private final class Fixture {
  let viewModel: PromptGateViewModel
  let preferences: PreferencesStore
  let target: StubPromptTarget
  let hooks = StubHookManager()
  let responder = StubHookResponder()
  let receiptDirectory: URL
  private let suite: String

  init(
    acceptedDisclosure: Bool = true,
    accessibilityTrusted: Bool = true,
    providerSetUp: Bool = true,
    grammar: any PromptGrammarServicing = RecordingPromptGrammar()
  ) async throws {
    suite = "com.bex.tests.prompt-gate-vm.\(UUID().uuidString)"
    preferences = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
    await preferences.setSelectedProvider(.openAI)
    await preferences.setSelectedModel("gpt-test-model", for: .openAI)
    if acceptedDisclosure {
      let destination = try await preferences.outboundDestination()
      await preferences.acceptCurrentOutboundDisclosure(for: destination)
    }
    let keychain = KeychainStore(service: suite, inMemory: true)
    if providerSetUp {
      try await keychain.saveAPIKey("secret", for: .openAI)
    }
    receiptDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PromptGateReceipts-\(UUID().uuidString)", isDirectory: true)
    let approvalStore = PromptApprovalStore(directoryURL: receiptDirectory)
    target = StubPromptTarget(isAccessibilityTrusted: accessibilityTrusted)

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
    UserDefaults.standard.removePersistentDomain(forName: suite)
  }

  func capturedSession(text: String) -> PromptGateSession {
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

  func composerSession(text: String) -> PromptGateSession {
    PromptGateSession(
      initialDraft: text,
      target: PromptTarget(
        kind: .composerPaste,
        processID: 100,
        bundleID: "com.example.editor",
        applicationName: "Editor",
        guidance: "Composer"
      ),
      source: .composer
    )
  }

  func hookSession(requestID: UUID, text: String) -> PromptGateSession {
    PromptGateSession(
      initialDraft: text,
      target: PromptTarget(
        kind: target.isAccessibilityTrusted ? .composerPaste : .copyOnly,
        processID: target.isAccessibilityTrusted ? 200 : nil,
        bundleID: "com.example.terminal",
        applicationName: "Terminal",
        guidance: "Hook prompt",
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
