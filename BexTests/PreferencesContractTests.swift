import XCTest

@testable import Bex

final class PreferencesContractTests: XCTestCase {
  func testFreshInstallStartsUndecidedAndDoesNotPersistDraft() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let draftChoice = await preferences.draftRetentionChoice()
    let historyChoice = await preferences.historyRetentionChoice()
    XCTAssertEqual(draftChoice, .undecided)
    XCTAssertEqual(historyChoice, .undecided)

    await preferences.setQuickDraft("must not persist")
    let draft = await preferences.quickDraft()
    XCTAssertEqual(draft, "")
  }

  /// Per-job models must be additive: an owner who never opens the Models section has to keep
  /// exactly the behaviour they had, which means every job falls back to `selectedModel` and
  /// Correction has no separate copy of it to drift from.
  func testJobModelsInheritTheCorrectionModelUntilOverridden() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }
    let preferences = fixture.store

    await preferences.setSelectedProvider(.claude)
    await preferences.setSelectedModel("base-model", for: .claude)

    for job in ModelJob.allCases {
      let model = await preferences.model(for: job, provider: .claude)
      XCTAssertEqual(model, "base-model", "\(job.rawValue) should inherit the correction model")
    }

    await preferences.setModelOverride("heavy-model", for: .background, provider: .claude)
    let background = await preferences.model(for: .background, provider: .claude)
    let correction = await preferences.model(for: .correction, provider: .claude)
    let ask = await preferences.model(for: .ask, provider: .claude)
    XCTAssertEqual(background, "heavy-model")
    XCTAssertEqual(correction, "base-model", "overriding one job must not move the sacred path")
    XCTAssertEqual(ask, "base-model")

    // Clearing puts the job back to following Correction rather than pinning the old value.
    await preferences.setModelOverride(nil, for: .background, provider: .claude)
    let clearedBackground = await preferences.model(for: .background, provider: .claude)
    XCTAssertEqual(clearedBackground, "base-model")
  }

  /// Overrides are per provider, so switching providers never sends a model name to a
  /// provider that has never heard of it.
  func testJobModelOverridesAreProviderScoped() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }
    let preferences = fixture.store

    await preferences.setSelectedModel("claude-base", for: .claude)
    await preferences.setSelectedModel("openai-base", for: .openAI)
    await preferences.setModelOverride("claude-heavy", for: .background, provider: .claude)

    let claudeBackground = await preferences.model(for: .background, provider: .claude)
    let openAIBackground = await preferences.model(for: .background, provider: .openAI)
    XCTAssertEqual(claudeBackground, "claude-heavy")
    XCTAssertEqual(openAIBackground, "openai-base")
  }

  /// Writing a job's model into `.correction` is the same as setting the provider's model —
  /// two stores for one value could disagree about what the sacred path actually uses.
  func testSettingTheCorrectionJobWritesTheProviderModel() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }
    let preferences = fixture.store

    await preferences.setModelOverride("chosen", for: .correction, provider: .claude)
    let selected = await preferences.selectedModel(for: .claude)
    let override = await preferences.modelOverride(for: .correction, provider: .claude)
    XCTAssertEqual(selected, "chosen")
    XCTAssertNil(override)
  }

  func testHookOutboundConfirmationDefaultsOnAndPersistsOptOut() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let confirmsByDefault = await preferences.confirmsHookOutboundPayloads()
    XCTAssertTrue(confirmsByDefault)

    await preferences.setConfirmsHookOutboundPayloads(false)

    let confirmsAfterOptOut = await preferences.confirmsHookOutboundPayloads()
    XCTAssertFalse(confirmsAfterOptOut)
  }

  func testDraftRetentionDisableStopsWritesWithoutDeletingSavedDraft() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    await preferences.setDraftRetentionChoice(.enabled)
    await preferences.setQuickDraft("saved draft")
    let savedDraft = await preferences.quickDraft()
    XCTAssertEqual(savedDraft, "saved draft")

    await preferences.setDraftRetentionChoice(.disabled)
    await preferences.setQuickDraft("ignored replacement")
    let disabledDraft = await preferences.quickDraft()
    XCTAssertEqual(disabledDraft, "")

    await preferences.setDraftRetentionChoice(.enabled)
    let restoredDraft = await preferences.quickDraft()
    XCTAssertEqual(restoredDraft, "saved draft")

    await preferences.deleteSavedQuickDraft()
    let deletedDraft = await preferences.quickDraft()
    XCTAssertEqual(deletedDraft, "")
  }

  func testRetentionChoicesRemainIndependent() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    await preferences.setDraftRetentionChoice(.enabled)
    await preferences.setHistoryRetentionChoice(.disabled)

    let draftChoice = await preferences.draftRetentionChoice()
    let historyChoice = await preferences.historyRetentionChoice()
    XCTAssertEqual(draftChoice, .enabled)
    XCTAssertEqual(historyChoice, .disabled)
  }

  func testOutboundDisclosureIsProviderScoped() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let openAI = try OutboundDestination(
      provider: .openAI,
      model: LLMProvider.openAI.defaultModel
    )
    let claude = try OutboundDestination(
      provider: .claude,
      model: LLMProvider.claude.defaultModel
    )
    let initialOpenAI = await preferences.hasAcceptedCurrentOutboundDisclosure(for: openAI)
    let initialClaude = await preferences.hasAcceptedCurrentOutboundDisclosure(for: claude)
    XCTAssertFalse(initialOpenAI)
    XCTAssertFalse(initialClaude)

    await preferences.acceptCurrentOutboundDisclosure(for: openAI)

    let acceptedOpenAI = await preferences.hasAcceptedCurrentOutboundDisclosure(for: openAI)
    let acceptedClaude = await preferences.hasAcceptedCurrentOutboundDisclosure(for: claude)
    XCTAssertTrue(acceptedOpenAI)
    XCTAssertFalse(acceptedClaude)
  }

  func testOutboundConfirmationMatrixKeepsAmbiguousAndHookFlowsGated() {
    XCTAssertFalse(
      OutboundConfirmationContext.quickCheckExternal.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertFalse(
      OutboundConfirmationContext.manualCapturedField.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertTrue(
      OutboundConfirmationContext.ambiguousManual.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertTrue(
      OutboundConfirmationContext.hook.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertFalse(
      OutboundConfirmationContext.hook.requiresConfirmation(
        hasAcceptedDisclosure: true,
        confirmsHookOutboundPayloads: false
      )
    )
    XCTAssertTrue(
      OutboundConfirmationContext.hook.requiresConfirmation(
        hasAcceptedDisclosure: false,
        confirmsHookOutboundPayloads: false
      )
    )
    XCTAssertTrue(
      OutboundConfirmationContext.quickCheckExternal.requiresConfirmation(
        hasAcceptedDisclosure: false
      )
    )
  }

  func testOllamaDisclosureAcceptanceIsEndpointScoped() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let accepted = try OutboundDestination(
      provider: .ollama,
      model: LLMProvider.ollama.defaultModel,
      ollamaEndpoint: "HTTP://LOCALHOST:11434/"
    )
    let equivalent = try OutboundDestination(
      provider: .ollama,
      model: LLMProvider.ollama.defaultModel,
      ollamaEndpoint: "http://localhost:11434"
    )
    let remote = try OutboundDestination(
      provider: .ollama,
      model: LLMProvider.ollama.defaultModel,
      ollamaEndpoint: "https://ollama.example.test"
    )

    await fixture.store.acceptCurrentOutboundDisclosure(for: accepted)

    let acceptedEquivalent =
      await fixture.store.hasAcceptedCurrentOutboundDisclosure(for: equivalent)
    let acceptedRemote =
      await fixture.store.hasAcceptedCurrentOutboundDisclosure(for: remote)
    XCTAssertTrue(acceptedEquivalent)
    XCTAssertFalse(acceptedRemote)
  }

  func testWelcomeCompletionVersionPersists() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let initialVersion = await fixture.store.welcomeCompletedVersion()
    XCTAssertEqual(initialVersion, 0)
    await fixture.store.setWelcomeCompletedVersion(1)
    let reloadedVersion = await fixture.reloadedStore().welcomeCompletedVersion()
    XCTAssertEqual(reloadedVersion, 1)
  }

  func testLastLearningViewedAtDefaultsNilAndPersists() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let initial = await preferences.lastLearningViewedAt()
    XCTAssertNil(initial)

    let viewedAt = Date(timeIntervalSince1970: 1_700_000_000)
    await preferences.setLastLearningViewedAt(viewedAt)

    let reloaded = await fixture.reloadedStore().lastLearningViewedAt()
    XCTAssertEqual(reloaded, viewedAt)
  }

  func testKeyChordsDefaultAndPersistIndependently() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let defaultQuickCheck = await preferences.quickCheckKeyChord()
    let defaultFixAndSend = await preferences.fixAndSendKeyChord()
    XCTAssertEqual(defaultQuickCheck, .defaultQuickCheck)
    XCTAssertEqual(defaultFixAndSend, .defaultFixAndSend)

    let quickCheck = KeyChord(keyCode: 12, modifiers: 768)
    let fixAndSend = KeyChord(keyCode: 13, modifiers: 1_024)
    await preferences.setQuickCheckKeyChord(quickCheck)
    await preferences.setFixAndSendKeyChord(fixAndSend)

    let reloaded = fixture.reloadedStore()
    let reloadedQuickCheck = await reloaded.quickCheckKeyChord()
    let reloadedFixAndSend = await reloaded.fixAndSendKeyChord()
    XCTAssertEqual(reloadedQuickCheck, quickCheck)
    XCTAssertEqual(reloadedFixAndSend, fixAndSend)
  }
}

private struct PreferencesFixture {
  let suiteName = "PreferencesContractTests-\(UUID().uuidString)"
  let store: PreferencesStore

  init() {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Could not create isolated defaults")
    }
    defaults.removePersistentDomain(forName: suiteName)
    store = PreferencesStore(defaults: defaults)
  }

  func reloadedStore() -> PreferencesStore {
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Could not reload isolated defaults")
    }
    return PreferencesStore(defaults: defaults)
  }

  func remove() {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
  }
}
