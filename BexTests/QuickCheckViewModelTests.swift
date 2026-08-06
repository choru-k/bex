import Foundation
import XCTest

@testable import Bex

private struct QuickCheckCall: Equatable, Sendable {
  let text: String
  let provider: LLMProvider
  let model: String
  let writingStylePrompt: String?
  let ollamaEndpoint: String?
}

private enum QuickCheckStubError: LocalizedError {
  case failed

  var errorDescription: String? { "The test request failed." }
}

actor QuickCheckGrammarStub: GrammarServicing {

  private var checkCalls: [QuickCheckCall] = []
  private var rewriteCalls = 0
  private var defineTerms: [String] = []
  private var failDefine = false
  private var delayCheck = false
  private var delayRewrite = false
  private var failCheck = false
  private var checkWaiters: [CheckedContinuation<Void, Never>] = []
  private var rewriteWaiters: [CheckedContinuation<Void, Never>] = []

  func setDelayCheck(_ value: Bool) {
    delayCheck = value
  }

  func setDelayRewrite(_ value: Bool) {
    delayRewrite = value
  }

  func setFailCheck(_ value: Bool) {
    failCheck = value
  }

  fileprivate func recordedChecks() -> [QuickCheckCall] {
    checkCalls
  }

  func recordedRewriteCount() -> Int {
    rewriteCalls
  }

  func setFailDefine(_ value: Bool) {
    failDefine = value
  }

  func recordedDefineTerms() -> [String] {
    defineTerms
  }

  func resumeChecks() {
    delayCheck = false
    let waiters = checkWaiters
    checkWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func resumeRewrites() {
    delayRewrite = false
    let waiters = rewriteWaiters
    rewriteWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func check(
    text: String,
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    checkCalls.append(
      QuickCheckCall(
        text: text,
        provider: destination.provider,
        model: destination.model,
        writingStylePrompt: profilePrompt,
        ollamaEndpoint: destination.ollamaEndpoint
      )
    )
    if delayCheck {
      await withCheckedContinuation { continuation in
        checkWaiters.append(continuation)
      }
    }
    if failCheck {
      throw QuickCheckStubError.failed
    }
    return GrammarResult(
      corrected: "this is a test",
      explanation: "Changed subject-verb agreement."
    )
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    destination: OutboundDestination
  ) async throws -> String {
    rewriteCalls += 1
    if delayRewrite {
      await withCheckedContinuation { continuation in
        rewriteWaiters.append(continuation)
      }
    }
    return "This is a test."
  }

  func define(
    text: String,
    destination: OutboundDestination
  ) async throws -> DictionaryLookup {
    defineTerms.append(text)
    if failDefine { throw BexError.invalidResponse }
    return DictionaryLookup(
      english: "postpone",
      korean: "미루다",
      simple: "To move something to a later time.",
      example: "Let's postpone the review until Friday."
    )
  }

  /// Quick Check never classifies study patterns — that runs in the background, off the
  /// interactive path, precisely so it cannot add latency here.
  func classifyStudyPatterns(
    cards: [StudyCard],
    destination: OutboundDestination
  ) async throws -> [String: StudyPattern] {
    [:]
  }

  func generateProfile(
    context: ProfileContext,
    destination: OutboundDestination
  ) async throws -> String {
    "Generated profile"
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    [ModelOption(id: provider.defaultModel, name: provider.defaultModel)]
  }
}

@MainActor
final class RecordingPasteboard: PasteboardWriting {
  private(set) var value: String?

  func write(_ string: String) throws {
    value = string
  }
}

@MainActor
private final class QuickCheckDismissalRecorder {
  private(set) var reasons: [QuickCheckDismissalReason] = []

  func record(_ reason: QuickCheckDismissalReason) {
    reasons.append(reason)
  }
}

@MainActor
final class QuickCheckViewModelTests: XCTestCase {
  func testCheckCopyAndFormalRewriteUpdateOneHistoryEntry() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(
      fixture.viewModel.result,
      GrammarResult(
        corrected: "this is a test",
        explanation: "Changed subject-verb agreement."
      )
    )
    let provenance = try XCTUnwrap(fixture.viewModel.resultProvenance)
    XCTAssertEqual(provenance.provider, .openAI)
    XCTAssertEqual(provenance.model, LLMProvider.openAI.defaultModel)
    XCTAssertEqual(provenance.writingStyleName, "Bex Standard")
    XCTAssertLessThanOrEqual(provenance.completedAt, Date())
    XCTAssertTrue(
      fixture.viewModel.diff.contains { $0.kind == .removed && $0.text == "are" }
    )
    XCTAssertTrue(
      fixture.viewModel.diff.contains { $0.kind == .inserted && $0.text == "is" }
    )
    XCTAssertEqual(
      fixture.viewModel.diffAccessibilitySummary,
      AccessibleDiffSummary.make(from: fixture.viewModel.diff)
    )

    var history = try await fixture.data.loadHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].original, "this are a test")
    XCTAssertEqual(history[0].corrected, "this is a test")
    XCTAssertEqual(history[0].explanation, "Changed subject-verb agreement.")
    XCTAssertNil(history[0].profileName)

    fixture.viewModel.copy(closeAfter: false)
    XCTAssertEqual(fixture.pasteboard.value, "this is a test")

    fixture.viewModel.rewrite(.formal)
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.viewModel.result?.corrected, "This is a test.")
    XCTAssertEqual(
      fixture.viewModel.result?.explanation,
      "Changed subject-verb agreement.\n\nRewrite applied: More Formal"
    )
    history = try await fixture.data.loadHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history[0].corrected, "This is a test.")
    XCTAssertEqual(
      history[0].explanation,
      "Changed subject-verb agreement.\n\nRewrite applied: More Formal"
    )
  }

  func testFreshRetentionChoicesBlockDraftAndHistoryWrites() async throws {
    let fixture = try await makeFixture(
      draftRetention: .undecided,
      historyRetention: .undecided
    )
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    XCTAssertEqual(fixture.viewModel.draftRetentionChoice, .undecided)
    XCTAssertEqual(fixture.viewModel.historyRetentionChoice, .undecided)

    fixture.viewModel.input = "must stay in memory"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    let storedDraft = await fixture.preferences.quickDraft()
    let history = try await fixture.data.loadHistory()
    XCTAssertEqual(storedDraft, "")
    XCTAssertTrue(history.isEmpty)
    XCTAssertEqual(
      QuickCheckViewModel.historyStorageDisclosure,
      "Quick Check history is stored locally on this Mac: original, correction, explanation, provider, model, Writing Style, and timestamp, up to 500 items. Fix & Send is not stored."
    )
  }

  func testExplicitRetentionEnablePersistsCurrentDraftAndFutureHistory() async throws {
    let fixture = try await makeFixture(
      draftRetention: .undecided,
      historyRetention: .undecided
    )
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "persist after explicit choice"
    await fixture.viewModel.setDraftRetentionChoice(.enabled)
    await fixture.viewModel.setHistoryRetentionChoice(.enabled)

    let storedDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(storedDraft, "persist after explicit choice")

    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    let history = try await fixture.data.loadHistory()
    XCTAssertEqual(history.count, 1)
  }

  func testRetentionRaceAPIsPreventPendingDraftAndHistoryWrites() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "debounced value"
    await fixture.viewModel.setDraftRetentionChoice(.disabled)
    try await Task.sleep(nanoseconds: 350_000_000)
    let storedDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(storedDraft, "")

    await fixture.grammar.setDelayCheck(true)
    fixture.viewModel.input = "history race"
    fixture.viewModel.check()
    try await waitUntil { fixture.viewModel.isChecking }
    await fixture.viewModel.setHistoryRetentionChoice(.disabled)
    await fixture.grammar.resumeChecks()
    await fixture.viewModel.waitForCurrentWork()
    let history = try await fixture.data.loadHistory()
    XCTAssertTrue(history.isEmpty)
  }

  func testPersistedDraftDeletionSynchronizationCancelsStaleDebounce() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "stored first"
    try await Task.sleep(nanoseconds: 350_000_000)
    let initiallyStoredDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(initiallyStoredDraft, "stored first")

    fixture.viewModel.input = "must not resurrect"
    await fixture.preferences.deleteSavedQuickDraft()
    fixture.viewModel.persistedDraftWasDeleted()
    try await Task.sleep(nanoseconds: 350_000_000)

    let deletedDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(deletedDraft, "")
    XCTAssertEqual(fixture.viewModel.input, "must not resurrect")
  }

  func testFirstDestinationDisclosureShowsFrozenFullOutboundSummary() async throws {
    let fixture = try await makeFixture(acceptedDisclosure: false)
    defer { fixture.removeFiles() }
    let style = Profile(
      id: UUID(),
      name: "Direct",
      prompt: "Prefer short sentences.\nKeep every technical qualifier."
    )
    try await fixture.data.saveProfile(style)
    await fixture.preferences.setActiveProfileID(style.id)

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are the frozen draft"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(
      fixture.viewModel.outboundSummary,
      QuickCheckOutboundSummary(
        action: "Check draft",
        provider: "OpenAI",
        model: LLMProvider.openAI.defaultModel,
        writingStyle: QuickCheckOutboundWritingStyle(
          name: "Direct",
          guidance: "Prefer short sentences.\nKeep every technical qualifier."
        ),
        fullDraft: "this are the frozen draft",
        disclosure: "The full draft shown here will be sent to OpenAI."
      )
    )
    let preConfirmationCalls = await fixture.grammar.recordedChecks()
    XCTAssertTrue(preConfirmationCalls.isEmpty)

    fixture.viewModel.input = "edited after summary"
    fixture.viewModel.performPrimaryAction()
    await fixture.viewModel.waitForCurrentWork()

    let confirmedCalls = await fixture.grammar.recordedChecks()
    XCTAssertEqual(confirmedCalls.map(\.text), ["this are the frozen draft"])
    XCTAssertEqual(confirmedCalls.map(\.provider), [.openAI])
    XCTAssertEqual(confirmedCalls.map(\.model), [LLMProvider.openAI.defaultModel])
    XCTAssertNil(confirmedCalls.first?.ollamaEndpoint)
    XCTAssertEqual(
      confirmedCalls.first?.writingStylePrompt,
      "Prefer short sentences.\nKeep every technical qualifier."
    )

    fixture.viewModel.rewrite(.formal)
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertNil(fixture.viewModel.outboundSummary)
    let rewriteCount = await fixture.grammar.recordedRewriteCount()
    XCTAssertEqual(rewriteCount, 1)
  }

  func testManualActionsUseDestinationScopedDisclosureAcceptance() async throws {
    let accepted = try await makeFixture(acceptedDisclosure: true)
    defer { accepted.removeFiles() }
    await accepted.viewModel.loadContext()
    accepted.viewModel.input = "this are accepted"
    accepted.viewModel.check()
    await accepted.viewModel.waitForCurrentWork()
    XCTAssertNil(accepted.viewModel.outboundSummary)
    let acceptedCalls = await accepted.grammar.recordedChecks()
    XCTAssertEqual(acceptedCalls.count, 1)

    let unaccepted = try await makeFixture(acceptedDisclosure: false)
    defer { unaccepted.removeFiles() }
    await unaccepted.viewModel.loadContext()
    unaccepted.viewModel.input = "this are unaccepted"
    unaccepted.viewModel.check()
    await unaccepted.viewModel.waitForCurrentWork()
    XCTAssertNotNil(unaccepted.viewModel.outboundSummary)
    let unacceptedCalls = await unaccepted.grammar.recordedChecks()
    XCTAssertTrue(unacceptedCalls.isEmpty)
  }

  func testLoopbackOllamaRequiresFirstDisclosure() async throws {
    let fixture = try await makeFixture(
      provider: .ollama,
      acceptedDisclosure: false
    )
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are local"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertNotNil(fixture.viewModel.outboundSummary)
    let localCalls = await fixture.grammar.recordedChecks()
    XCTAssertTrue(localCalls.isEmpty)
    XCTAssertEqual(
      fixture.viewModel.processingDisclosure,
      "Processed locally by Ollama at http://localhost:11434. The draft does not leave this Mac."
    )
  }

  func testRemoteOllamaRequiresFirstDisclosure() async throws {
    let fixture = try await makeFixture(
      provider: .ollama,
      acceptedDisclosure: false,
      ollamaURL: "https://ollama.example.test"
    )
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are remote"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertNotNil(fixture.viewModel.outboundSummary)
    let calls = await fixture.grammar.recordedChecks()
    XCTAssertTrue(calls.isEmpty)
    XCTAssertEqual(
      fixture.viewModel.processingDisclosure,
      "The full draft is sent to the external Ollama endpoint at https://ollama.example.test for processing."
    )
  }

  func testOllamaRequestFreezesRefreshedEndpointAcrossConfirmation() async throws {
    let fixture = try await makeFixture(
      provider: .ollama,
      acceptedDisclosure: false
    )
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    XCTAssertEqual(
      fixture.viewModel.processingDisclosure,
      "Processed locally by Ollama at http://localhost:11434. The draft does not leave this Mac."
    )

    await fixture.preferences.setOllamaURL("https://ollama.example.test")
    fixture.viewModel.input = "this are now external"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertNotNil(fixture.viewModel.outboundSummary)
    XCTAssertEqual(
      fixture.viewModel.processingDisclosure,
      "The full draft is sent to the external Ollama endpoint at https://ollama.example.test for processing."
    )
    let callsBeforeConfirmation = await fixture.grammar.recordedChecks()
    XCTAssertTrue(callsBeforeConfirmation.isEmpty)

    await fixture.preferences.setOllamaURL("http://localhost:11434")
    fixture.viewModel.confirmOutbound()
    await fixture.viewModel.waitForCurrentWork()
    let calls = await fixture.grammar.recordedChecks()
    XCTAssertEqual(calls.map(\.ollamaEndpoint), ["https://ollama.example.test"])
  }

  func testDeactivationPreservesDraftInFlightWorkAndFocusAcrossReshow() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }
    await fixture.grammar.setDelayCheck(true)

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are preserved"
    fixture.viewModel.check()
    try await waitUntil { fixture.viewModel.isChecking }
    let focusBeforeReshow = fixture.viewModel.editorFocusRequest

    fixture.viewModel.panelDidDismiss(.applicationDeactivated)
    await fixture.viewModel.loadContext()

    XCTAssertEqual(fixture.viewModel.input, "this are preserved")
    XCTAssertTrue(fixture.viewModel.isChecking)
    XCTAssertTrue(fixture.viewModel.wantsEditorFocus)
    XCTAssertGreaterThan(fixture.viewModel.editorFocusRequest, focusBeforeReshow)

    await fixture.grammar.resumeChecks()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertNotNil(fixture.viewModel.result)
  }

  func testPreservedUserWorkBoundaryProtectsHistoryDraftReplacement() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }
    await fixture.grammar.setDelayCheck(true)

    await fixture.viewModel.loadContext()
    XCTAssertFalse(fixture.viewModel.hasPreservedUserWork)

    fixture.viewModel.input = "work that requires a replacement decision"
    XCTAssertTrue(fixture.viewModel.hasPreservedUserWork)
    fixture.viewModel.check()
    try await waitUntil { fixture.viewModel.isChecking }
    XCTAssertTrue(fixture.viewModel.hasPreservedUserWork)

    fixture.viewModel.replaceDraft(with: "history replacement")
    await fixture.grammar.resumeChecks()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.input, "history replacement")
    XCTAssertNil(fixture.viewModel.result)
    XCTAssertFalse(fixture.viewModel.isBusy)
    XCTAssertTrue(fixture.viewModel.hasPreservedUserWork)

    fixture.viewModel.replaceDraft(with: "")
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertFalse(fixture.viewModel.hasPreservedUserWork)
  }

  func testBackToInputCancelsReviewWorkButPreservesOriginalDraftAndFocusesEditor() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are the original draft"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertNotNil(fixture.viewModel.result)

    await fixture.grammar.setDelayRewrite(true)
    fixture.viewModel.rewrite(.formal)
    try await waitUntil { fixture.viewModel.rewritingIntent == .formal }
    let focusBeforeBack = fixture.viewModel.editorFocusRequest

    fixture.viewModel.backToInput()
    XCTAssertEqual(fixture.viewModel.input, "this are the original draft")
    XCTAssertNil(fixture.viewModel.result)
    XCTAssertNil(fixture.viewModel.outboundSummary)
    XCTAssertNil(fixture.viewModel.userVisibleError)
    XCTAssertFalse(fixture.viewModel.isBusy)
    XCTAssertGreaterThan(fixture.viewModel.editorFocusRequest, focusBeforeBack)

    await fixture.grammar.resumeRewrites()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertNil(fixture.viewModel.result)
  }

  func testAuxiliaryNavigationPreservesResultErrorAndRewriteState() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    let completedResult = fixture.viewModel.result

    fixture.viewModel.panelDidDismiss(.auxiliaryNavigation)
    await fixture.viewModel.loadContext()
    XCTAssertEqual(fixture.viewModel.result, completedResult)

    await fixture.grammar.setDelayRewrite(true)
    fixture.viewModel.rewrite(.formal)
    try await waitUntil { fixture.viewModel.rewritingIntent == .formal }
    fixture.viewModel.panelDidDismiss(.auxiliaryNavigation)
    await fixture.viewModel.loadContext()
    XCTAssertEqual(fixture.viewModel.rewritingIntent, .formal)
    XCTAssertEqual(fixture.viewModel.result, completedResult)

    await fixture.grammar.resumeRewrites()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertEqual(fixture.viewModel.result?.corrected, "This is a test.")

    let failure = try await makeFixture()
    defer { failure.removeFiles() }
    await failure.grammar.setFailCheck(true)
    await failure.viewModel.loadContext()
    failure.viewModel.input = "failure remains"
    failure.viewModel.check()
    await failure.viewModel.waitForCurrentWork()
    let error = try XCTUnwrap(failure.viewModel.userVisibleError)
    failure.viewModel.panelDidDismiss(.auxiliaryNavigation)
    await failure.viewModel.loadContext()
    XCTAssertEqual(failure.viewModel.userVisibleError, error)
  }

  func testExplicitAndWindowDismissalsDestroySessionAndSavedDraft() async throws {
    for reason in [QuickCheckDismissalReason.explicitCancel, .windowClose] {
      let fixture = try await makeFixture()
      await fixture.viewModel.loadContext()
      fixture.viewModel.input = "discard me"
      try await Task.sleep(nanoseconds: 350_000_000)
      fixture.viewModel.panelDidDismiss(reason)
      await fixture.viewModel.waitForCurrentWork()

      XCTAssertEqual(fixture.viewModel.input, "")
      XCTAssertNil(fixture.viewModel.result)
      XCTAssertNil(fixture.viewModel.userVisibleError)
      XCTAssertFalse(fixture.viewModel.isBusy)
      XCTAssertFalse(fixture.viewModel.wantsEditorFocus)
      let storedDraft = await fixture.preferences.quickDraft()
      XCTAssertEqual(storedDraft, "")
      fixture.removeFiles()
    }
  }

  func testDiscardDuringInitialContextLoadDoesNotStrandReopenedSession() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    var reopenedLoad: Task<Void, Never>?
    await fixture.viewModel.loadContext(didStart: {
      fixture.viewModel.panelDidDismiss(.windowClose)
      reopenedLoad = Task {
        await fixture.viewModel.loadContext()
      }
    })
    await reopenedLoad?.value

    XCTAssertTrue(fixture.viewModel.isContextLoaded)
    XCTAssertTrue(fixture.viewModel.wantsEditorFocus)
  }

  func testTypingDuringInitialContextLoadWinsOverStoredDraft() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }
    await fixture.preferences.setQuickDraft("stored draft")

    await fixture.viewModel.loadContext(didStart: {
      fixture.viewModel.input = "typed while loading"
    })

    XCTAssertEqual(fixture.viewModel.input, "typed while loading")
    let persistedDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(persistedDraft, "typed while loading")
  }

  func testSuccessfulCopyAndCloseDestroysSessionWithCompletedReason() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()
    fixture.viewModel.copy(closeAfter: true)
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertEqual(fixture.pasteboard.value, "this is a test")
    XCTAssertEqual(fixture.dismissals.reasons, [.completed])
    XCTAssertEqual(fixture.viewModel.input, "")
    XCTAssertNil(fixture.viewModel.result)
    let storedDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(storedDraft, "")
  }

  func testRewriteHistoryFinishesAfterImmediateCopyAndClose() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    await fixture.viewModel.waitForCurrentWork()

    fixture.viewModel.rewrite(.formal)
    try await waitUntil {
      fixture.viewModel.result?.corrected == "This is a test."
        && !fixture.viewModel.isBusy
    }
    fixture.viewModel.copy(closeAfter: true)
    await fixture.viewModel.waitForCurrentWork()

    let history = try await fixture.data.loadHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.corrected, "This is a test.")
    XCTAssertTrue(history.first?.explanation.contains("Rewrite applied: More Formal") == true)
  }

  func testAsyncOperationsPublishExactlyOneStartAndTerminalAnnouncementState() async throws {
    let fixture = try await makeFixture()
    XCTAssertNil(fixture.viewModel.busyLabel)
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    await fixture.grammar.setDelayCheck(true)
    fixture.viewModel.input = "this are a test"
    fixture.viewModel.check()
    try await waitUntil { fixture.viewModel.isChecking }
    XCTAssertEqual(fixture.viewModel.busyLabel, "Checking…")
    XCTAssertEqual(
      fixture.viewModel.accessibilityAnnouncement,
      QuickCheckAccessibilityAnnouncement(sequence: 1, message: "Checking started.")
    )
    await fixture.grammar.resumeChecks()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertNil(fixture.viewModel.busyLabel)
    XCTAssertEqual(
      fixture.viewModel.accessibilityAnnouncement,
      QuickCheckAccessibilityAnnouncement(sequence: 2, message: "Check complete.")
    )

    await fixture.grammar.setDelayRewrite(true)
    fixture.viewModel.rewrite(.formal)
    try await waitUntil { fixture.viewModel.rewritingIntent == .formal }
    XCTAssertEqual(fixture.viewModel.busyLabel, "Applying More Formal…")
    XCTAssertEqual(
      fixture.viewModel.accessibilityAnnouncement,
      QuickCheckAccessibilityAnnouncement(sequence: 3, message: "More Formal rewrite started.")
    )
    await fixture.grammar.resumeRewrites()
    await fixture.viewModel.waitForCurrentWork()
    XCTAssertNil(fixture.viewModel.busyLabel)
    XCTAssertEqual(
      fixture.viewModel.accessibilityAnnouncement,
      QuickCheckAccessibilityAnnouncement(sequence: 4, message: "Rewrite complete.")
    )
  }

  func testLookUpShowsAnEntryAndOnlySavesToStudyWhenAsked() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "미루다"
    fixture.viewModel.lookUp()
    await fixture.viewModel.waitForCurrentWork()

    let definedTerms = await fixture.grammar.recordedDefineTerms()
    XCTAssertEqual(definedTerms, ["미루다"])
    XCTAssertEqual(fixture.viewModel.lookup?.english, "postpone")
    XCTAssertFalse(fixture.viewModel.lookupSavedToStudy)
    // A lookup is not a correction: nothing lands in Quick Check history, and nothing
    // enters the study deck until the owner says so — the log has no delete.
    let history = try await fixture.data.loadHistory()
    XCTAssertTrue(history.isEmpty)
    let beforeSave = await fixture.learningLog.readAll()
    XCTAssertTrue(beforeSave.isEmpty)

    fixture.viewModel.saveLookupToStudy()
    XCTAssertTrue(fixture.viewModel.lookupSavedToStudy)
    await fixture.viewModel.waitForCurrentWork()

    let entries = await fixture.learningLog.readAll()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].client, "quick-check-dictionary")
    XCTAssertEqual(entries[0].corrected, "postpone")

    let cards = StudyCardBuilder.cards(
      from: entries.map {
        LearningSample(date: Date(), original: $0.original, explanation: $0.explanation)
      }
    )
    XCTAssertEqual(cards.map(\.correct), ["postpone"])

    // Saving twice must not double-log the same word.
    fixture.viewModel.saveLookupToStudy()
    await fixture.viewModel.waitForCurrentWork()
    let afterSecondSave = await fixture.learningLog.readAll()
    XCTAssertEqual(afterSecondSave.count, 1)
  }

  func testFailedLookUpSurfacesAnErrorAndLeavesNothingToSave() async throws {
    let fixture = try await makeFixture()
    defer { fixture.removeFiles() }

    await fixture.grammar.setFailDefine(true)
    await fixture.viewModel.loadContext()
    fixture.viewModel.input = "미루다"
    fixture.viewModel.lookUp()
    await fixture.viewModel.waitForCurrentWork()

    XCTAssertNil(fixture.viewModel.lookup)
    XCTAssertNotNil(fixture.viewModel.userVisibleError)
    XCTAssertFalse(fixture.viewModel.isBusy)

    fixture.viewModel.saveLookupToStudy()
    await fixture.viewModel.waitForCurrentWork()
    let entries = await fixture.learningLog.readAll()
    XCTAssertTrue(entries.isEmpty)
  }

  private func makeFixture(
    provider: LLMProvider = .openAI,
    draftRetention: RetentionChoice = .enabled,
    historyRetention: RetentionChoice = .enabled,
    acceptedDisclosure: Bool = true,
    ollamaURL: String? = nil
  ) async throws -> QuickCheckFixture {
    let identifier = UUID().uuidString
    let suite = "com.bex.desktop.tests.quick-check.\(identifier)"
    let preferences = PreferencesStore(defaults: UserDefaults(suiteName: suite)!)
    await preferences.setSelectedProvider(provider)
    if let ollamaURL {
      await preferences.setOllamaURL(ollamaURL)
    }
    await preferences.setDraftRetentionChoice(draftRetention)
    await preferences.setHistoryRetentionChoice(historyRetention)
    if acceptedDisclosure {
      let destination = try await preferences.outboundDestination()
      await preferences.acceptCurrentOutboundDisclosure(for: destination)
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexQuickCheckTests-\(identifier)")
    let data = BexDataStore(fileURL: directory.appendingPathComponent("data.json"))
    let keychain = KeychainStore(
      service: "com.bex.desktop.tests.quick-check.\(identifier)", inMemory: true)
    if provider != .ollama {
      try await keychain.saveAPIKey("test-key", for: provider)
    }
    let grammar = QuickCheckGrammarStub()
    let pasteboard = RecordingPasteboard()
    let dismissals = QuickCheckDismissalRecorder()
    // Always a temp directory: the default `LearningLogStore()` writes to the real
    // ~/Library/Application Support, and a test that saves a lookup would append to the
    // owner's actual study deck.
    let learningLog = LearningLogStore(
      directoryURL: directory.appendingPathComponent("LearningLog", isDirectory: true))
    let viewModel = QuickCheckViewModel(
      preferences: preferences,
      keychain: keychain,
      data: data,
      grammar: grammar,
      pasteboard: pasteboard,
      learningLog: learningLog,
      onDismiss: { reason in dismissals.record(reason) }
    )
    return QuickCheckFixture(
      suite: suite,
      directory: directory,
      preferences: preferences,
      data: data,
      grammar: grammar,
      pasteboard: pasteboard,
      dismissals: dismissals,
      learningLog: learningLog,
      viewModel: viewModel
    )
  }

  private func waitUntil(
    _ predicate: @escaping @MainActor () async -> Bool
  ) async throws {
    for _ in 0..<200 {
      if await predicate() { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Timed out waiting for Quick Check state")
  }
}

@MainActor
private struct QuickCheckFixture {
  let suite: String
  let directory: URL
  let preferences: PreferencesStore
  let data: BexDataStore
  let grammar: QuickCheckGrammarStub
  let pasteboard: RecordingPasteboard
  let dismissals: QuickCheckDismissalRecorder
  let learningLog: LearningLogStore
  let viewModel: QuickCheckViewModel

  func removeFiles() {
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }
}
