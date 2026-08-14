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

    await preferences.setSavedDraft("must not persist")
    let draft = await preferences.savedDraft()
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

  /// The hourly work existed before it had a switch, so the switch has to default on —
  /// shipping it off would silently stop pattern grouping and the writer profile.
  func testBackgroundAgentDefaultsOnAndPersistsOptOut() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }
    let preferences = fixture.store

    let enabledByDefault = await preferences.backgroundAgentEnabled()
    XCTAssertTrue(enabledByDefault)

    await preferences.setBackgroundAgentEnabled(false)
    let afterOptOut = await preferences.backgroundAgentEnabled()
    XCTAssertFalse(afterOptOut)
  }

  /// Non-negotiable 3: an approval that cannot be taken back is not a choice. Revoking has to
  /// return the destination to unapproved, which is what stops the background pass.
  func testRevokingTheOutboundDisclosureReturnsToUnapproved() async throws {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }
    let preferences = fixture.store

    await preferences.setSelectedProvider(.claude)
    let destination = try await preferences.outboundDestination()
    await preferences.acceptCurrentOutboundDisclosure(for: destination)
    let accepted = await preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
    XCTAssertTrue(accepted)

    await preferences.revokeOutboundDisclosure(for: destination)
    let revoked = await preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
    XCTAssertFalse(revoked)
  }

  /// A background pass that leaves no trace is indistinguishable from one that never ran.
  func testLastBackgroundRunRoundTrips() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }
    let preferences = fixture.store

    let never = await preferences.lastBackgroundRun()
    XCTAssertNil(never)

    let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
    await preferences.setLastBackgroundRun(
      BackgroundRunSummary(finishedAt: finishedAt, correctionsRead: 41, cardsGrouped: 3))

    let stored = await preferences.lastBackgroundRun()
    XCTAssertEqual(stored?.correctionsRead, 41)
    XCTAssertEqual(stored?.cardsGrouped, 3)
    XCTAssertEqual(stored?.finishedAt, finishedAt)
  }

  /// The two session sources are listed but inert until the corpus gate has been run on them
  /// (non-negotiable 8). If one ever flips to available by accident, this fails.
  func testOnlyTheAlreadyLocalBackgroundSourceIsRead() {
    XCTAssertTrue(BackgroundSource.bexHistory.isAvailable)
    XCTAssertNil(BackgroundSource.bexHistory.unavailableReason)
    for source in [BackgroundSource.claudeCodeSessions, .codexSessions] {
      XCTAssertFalse(source.isAvailable, "\(source.rawValue) needs a corpus measurement first")
      XCTAssertNotNil(source.unavailableReason)
    }
  }

  func testHookOutboundConfirmationDefaultsOffAndPersistsOptIn() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let confirmsByDefault = await preferences.confirmsHookOutboundPayloads()
    XCTAssertFalse(confirmsByDefault)

    await preferences.setConfirmsHookOutboundPayloads(true)

    let confirmsAfterOptIn = await preferences.confirmsHookOutboundPayloads()
    XCTAssertTrue(confirmsAfterOptIn)
  }

  func testDraftRetentionDisableStopsWritesWithoutDeletingSavedDraft() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    await preferences.setDraftRetentionChoice(.enabled)
    await preferences.setSavedDraft("saved draft")
    let savedDraft = await preferences.savedDraft()
    XCTAssertEqual(savedDraft, "saved draft")

    await preferences.setDraftRetentionChoice(.disabled)
    await preferences.setSavedDraft("ignored replacement")
    let disabledDraft = await preferences.savedDraft()
    XCTAssertEqual(disabledDraft, "")

    await preferences.setDraftRetentionChoice(.enabled)
    let restoredDraft = await preferences.savedDraft()
    XCTAssertEqual(restoredDraft, "saved draft")

    await preferences.deleteSavedDraft()
    let deletedDraft = await preferences.savedDraft()
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

  func testOutboundConfirmationMatrixKeepsDisclosureAndOptInGates() {
    XCTAssertFalse(
      OutboundConfirmationContext.standaloneFixAndSend.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertFalse(
      OutboundConfirmationContext.manualCapturedField.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertFalse(
      OutboundConfirmationContext.hook.requiresConfirmation(
        hasAcceptedDisclosure: true
      )
    )
    XCTAssertTrue(
      OutboundConfirmationContext.hook.requiresConfirmation(
        hasAcceptedDisclosure: true,
        confirmsHookOutboundPayloads: true
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
      OutboundConfirmationContext.standaloneFixAndSend.requiresConfirmation(
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

  func testLegacyDraftAndRetentionChoicesMigrateWithoutOverwritingCurrentValues() async {
    let suiteName = "PreferencesMigrationTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      XCTFail("Could not create isolated defaults")
      return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("legacy draft", forKey: "quickDraft")
    defaults.set(RetentionChoice.enabled.rawValue, forKey: "storage.quickDraft.choice")
    defaults.set(RetentionChoice.enabled.rawValue, forKey: "storage.history.choice")

    let migrated = PreferencesStore(defaults: UserDefaults(suiteName: suiteName)!)
    let migratedDraft = await migrated.savedDraft()
    let migratedDraftChoice = await migrated.draftRetentionChoice()
    let migratedHistoryChoice = await migrated.historyRetentionChoice()
    XCTAssertEqual(migratedDraft, "legacy draft")
    XCTAssertEqual(migratedDraftChoice, .enabled)
    XCTAssertEqual(migratedHistoryChoice, .undecided)
    let migratedDefaults = UserDefaults(suiteName: suiteName)!
    XCTAssertNil(migratedDefaults.object(forKey: "quickDraft"))
    XCTAssertNil(migratedDefaults.object(forKey: "storage.quickDraft.choice"))
    XCTAssertNil(migratedDefaults.object(forKey: "storage.history.choice"))
    let disabledSuiteName = "PreferencesDisabledMigrationTests-\(UUID().uuidString)"
    guard let disabledDefaults = UserDefaults(suiteName: disabledSuiteName) else {
      XCTFail("Could not create isolated disabled defaults")
      return
    }
    disabledDefaults.removePersistentDomain(forName: disabledSuiteName)
    defer { disabledDefaults.removePersistentDomain(forName: disabledSuiteName) }
    disabledDefaults.set(
      RetentionChoice.disabled.rawValue,
      forKey: "storage.history.choice"
    )
    let disabled = PreferencesStore(defaults: UserDefaults(suiteName: disabledSuiteName)!)
    let disabledHistoryChoice = await disabled.historyRetentionChoice()
    XCTAssertEqual(disabledHistoryChoice, .disabled)
    let migratedDisabledDefaults = UserDefaults(suiteName: disabledSuiteName)!
    XCTAssertNil(migratedDisabledDefaults.object(forKey: "storage.history.choice"))

    let currentSuiteName = "PreferencesCurrentMigrationTests-\(UUID().uuidString)"
    guard let currentSeed = UserDefaults(suiteName: currentSuiteName) else {
      XCTFail("Could not create isolated current defaults")
      return
    }
    currentSeed.removePersistentDomain(forName: currentSuiteName)
    defer { UserDefaults.standard.removePersistentDomain(forName: currentSuiteName) }
    currentSeed.set("current draft", forKey: "fixAndSend.savedDraft")
    currentSeed.set(
      RetentionChoice.enabled.rawValue,
      forKey: "storage.fixAndSendDraft.choice"
    )
    currentSeed.set(
      RetentionChoice.enabled.rawValue,
      forKey: "storage.correctionHistory.choice"
    )
    currentSeed.set("stale legacy draft", forKey: "quickDraft")
    currentSeed.set(RetentionChoice.disabled.rawValue, forKey: "storage.quickDraft.choice")
    currentSeed.set(RetentionChoice.disabled.rawValue, forKey: "storage.history.choice")

    let current = PreferencesStore(defaults: currentSeed)
    let currentDraft = await current.savedDraft()
    let currentDraftChoice = await current.draftRetentionChoice()
    let currentHistoryChoice = await current.historyRetentionChoice()
    XCTAssertEqual(currentDraft, "current draft")
    XCTAssertEqual(currentDraftChoice, .enabled)
    XCTAssertEqual(currentHistoryChoice, .enabled)
  }

  func testFixAndSendKeyChordDefaultsAndPersists() async {
    let fixture = PreferencesFixture()
    defer { fixture.remove() }

    let preferences = fixture.store
    let defaultFixAndSend = await preferences.fixAndSendKeyChord()
    XCTAssertEqual(defaultFixAndSend, .defaultFixAndSend)

    let fixAndSend = KeyChord(keyCode: 13, modifiers: 1_024)
    await preferences.setFixAndSendKeyChord(fixAndSend)

    let reloaded = fixture.reloadedStore()
    let reloadedFixAndSend = await reloaded.fixAndSendKeyChord()
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
