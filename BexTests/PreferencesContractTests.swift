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
