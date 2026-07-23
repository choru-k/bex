import XCTest

@testable import Bex

final class UITestScenarioContractTests: XCTestCase {
  func testScenarioNamesAreStableCodableAndParseFromEnvironment() throws {
    XCTAssertEqual(
      UITestScenario.allCases.map(\.rawValue),
      [
        "default",
        "welcome",
        "fresh-consent",
        "fresh-quick-check",
        "configured-provider",
        "permission-denied",
        "permission-trusted",
        "hook-provided-client",
        "hotkey-conflict",
        "quick-check-grammar-in-flight",
        "prompt-delivery-in-flight",
        "delivery-failure-effect",
        "dirty-editor-resume",
        "setup-resume",
        "history-empty",
        "history-populated",
        "profiles-empty",
        "profiles-populated",
        "integrations",
      ]
    )

    for scenario in UITestScenario.allCases {
      XCTAssertEqual(
        UITestScenario.parse(environment: [UITestScenario.environmentKey: scenario.rawValue]),
        scenario
      )
      let encoded = try JSONEncoder().encode(scenario)
      XCTAssertEqual(try JSONDecoder().decode(UITestScenario.self, from: encoded), scenario)
    }
  }

  func testMissingEmptyAndUnknownScenarioUseCompatibleDefaultFixture() {
    for environment in [
      [String: String](),
      [UITestScenario.environmentKey: ""],
      [UITestScenario.environmentKey: "not-a-scenario"],
    ] {
      XCTAssertEqual(UITestScenario.parse(environment: environment), .standard)
    }

    let configuration = UITestFixtureConfiguration.resolve(environment: [:])
    XCTAssertFalse(configuration.preservesStoredState)
    XCTAssertEqual(configuration.credentialProvider, .openAI)
    XCTAssertEqual(configuration.target, UITestTargetSeed())
    XCTAssertNil(configuration.profiles)
    XCTAssertNil(configuration.history)
    XCTAssertEqual(configuration.launchDestination, .none)
  }

  func testLegacyEnvironmentInputsAreCentralizedAsFixtureOverrides() {
    let configuration = UITestFixtureConfiguration.resolve(
      environment: [
        "BEX_UI_TEST_PROMPT_SOURCE": "Existing editor text",
        "BEX_UI_TEST_PROMPT_TARGET_PATH": "/tmp/bex-target.txt",
        "BEX_UI_TEST_PASTEBOARD_PATH": "/tmp/bex-pasteboard.txt",
        "BEX_UI_TEST_PROMPT_DELIVERY_EVENTS_PATH": "/tmp/bex-delivery-events.json",
        "BEX_UI_TEST_PROMPT_DELIVERY_ERROR": "1",
        "BEX_UI_TEST_REAL_TARGET": "1",
        "BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH": "/tmp/bex-integrations.json",
        "BEX_UI_TEST_INJECT_DRIFT_ID": "omp-default",
        "BEX_UI_TEST_PARTIAL_FAILURE_ID": "omp-team",
      ]
    )

    XCTAssertEqual(configuration.target.source, "Existing editor text")
    XCTAssertEqual(configuration.target.sinkPath, "/tmp/bex-target.txt")
    XCTAssertEqual(configuration.pasteboardPath, "/tmp/bex-pasteboard.txt")
    XCTAssertEqual(
      configuration.target.deliveryEventsPath,
      "/tmp/bex-delivery-events.json"
    )
    XCTAssertEqual(configuration.target.deliveryFailureEffect, PromptDeliveryEffect.none)
    XCTAssertTrue(configuration.target.usesRealTarget)
    XCTAssertEqual(configuration.preferences.promptDeliveryMode, .pasteOnly)
    XCTAssertEqual(configuration.integrationTranscriptPath, "/tmp/bex-integrations.json")
    XCTAssertEqual(configuration.injectDriftIntegrationID, "omp-default")
    XCTAssertEqual(configuration.partialFailureIntegrationID, "omp-team")
  }

  func testNamedConfigurationsDeclareConsentPermissionHookFailureAndResumeStates() throws {
    let consent = UITestScenario.freshConsent.configuration
    XCTAssertEqual(consent.preferences.draftRetentionChoice, .undecided)
    XCTAssertEqual(consent.preferences.historyRetentionChoice, .undecided)
    XCTAssertEqual(consent.target.source, "A fresh consent UI test draft.")

    let freshQuickCheck = UITestScenario.freshQuickCheck.configuration
    XCTAssertEqual(freshQuickCheck.preferences.selectedProvider, .claude)
    XCTAssertEqual(freshQuickCheck.preferences.selectedModel, LLMProvider.claude.defaultModel)
    XCTAssertEqual(freshQuickCheck.preferences.draftRetentionChoice, .undecided)
    XCTAssertEqual(freshQuickCheck.preferences.historyRetentionChoice, .undecided)
    XCTAssertEqual(
      freshQuickCheck.preferences.activeProfileID,
      UITestFixtureConfiguration.populatedProfiles.first?.id
    )
    XCTAssertEqual(freshQuickCheck.profiles, UITestFixtureConfiguration.populatedProfiles)
    XCTAssertEqual(freshQuickCheck.launchDestination, .quickCheck)

    let configured = UITestScenario.configuredProvider.configuration
    XCTAssertEqual(configured.preferences.selectedProvider, .claude)
    XCTAssertEqual(configured.preferences.selectedModel, LLMProvider.claude.defaultModel)
    XCTAssertEqual(configured.preferences.selectedEffort, .high)
    XCTAssertEqual(configured.preferences.acceptedOutboundDisclosureProvider, .claude)
    XCTAssertEqual(configured.credentialProvider, .claude)

    XCTAssertFalse(UITestScenario.permissionDenied.configuration.target.isAccessibilityTrusted)
    XCTAssertFalse(UITestScenario.permissionDenied.configuration.target.requestedAccessibilityTrust)
    XCTAssertTrue(UITestScenario.permissionTrusted.configuration.target.isAccessibilityTrusted)
    XCTAssertTrue(UITestScenario.permissionTrusted.configuration.target.requestedAccessibilityTrust)

    let hook = try XCTUnwrap(UITestScenario.hookProvidedClient.configuration.hook)
    XCTAssertEqual(hook.client, .codex)
    XCTAssertEqual(hook.prompt, "Make this UI test prompt concise.")
    XCTAssertEqual(
      UITestScenario.hookProvidedClient.configuration.preferences.preferredPromptClient,
      .codex
    )
    XCTAssertEqual(
      UITestScenario.hotKeyConflict.configuration.hotKeyRegistration,
      .conflict
    )
    XCTAssertEqual(
      UITestScenario.quickCheckGrammarInFlight.configuration.grammarBehavior,
      .holdFirstCheckThenFailSubsequent
    )
    XCTAssertEqual(
      UITestScenario.promptDeliveryInFlight.configuration.target.deliveryGate,
      .untilReleased
    )

    XCTAssertEqual(
      UITestScenario.deliveryFailureEffect.configuration.target.deliveryFailureEffect,
      .pastedNotSubmitted
    )
    XCTAssertTrue(UITestScenario.dirtyEditorResume.configuration.preservesStoredState)
    XCTAssertTrue(UITestScenario.setupResume.configuration.preservesStoredState)
    XCTAssertEqual(UITestScenario.setupResume.configuration.credentialProvider, nil)
    XCTAssertEqual(UITestScenario.setupResume.configuration.launchDestination, .setup(.quickCheck))
    let integrations = UITestScenario.integrations.configuration
    XCTAssertEqual(integrations.integrations.map(\.id), ["omp-default", "omp-team"])
    XCTAssertEqual(integrations.launchDestination, .settings)
    XCTAssertEqual(integrations.integrationStatuses["omp-default"], .installedUnconfirmed)
  }

  func testPreferenceAndCollectionSeedsAreDeterministic() async throws {
    let fixture = try UITestSeedFixture()
    defer { fixture.remove() }

    try await UITestScenario.configuredProvider.configuration.seed(
      preferences: fixture.preferences,
      data: fixture.data
    )
    let provider = await fixture.preferences.selectedProvider()
    let model = await fixture.preferences.selectedModel(for: .claude)
    let effort = await fixture.preferences.selectedEffort(for: .claude)
    let draftRetention = await fixture.preferences.draftRetentionChoice()
    let historyRetention = await fixture.preferences.historyRetentionChoice()
    let destination = try await fixture.preferences.outboundDestination()
    let outboundDisclosure =
      await fixture.preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
    XCTAssertEqual(provider, .claude)
    XCTAssertEqual(model, LLMProvider.claude.defaultModel)
    XCTAssertEqual(effort, .high)
    XCTAssertEqual(draftRetention, .enabled)
    XCTAssertEqual(historyRetention, .enabled)
    XCTAssertTrue(outboundDisclosure)

    try await UITestScenario.dirtyEditorResume.configuration.seed(
      preferences: fixture.preferences,
      data: fixture.data
    )
    let quickDraft = await fixture.preferences.quickDraft()
    XCTAssertEqual(quickDraft, "A saved UI test draft with unsent changes.")

    try await UITestScenario.profilesPopulated.configuration.seed(
      preferences: fixture.preferences,
      data: fixture.data
    )
    let profiles = try await fixture.data.loadProfiles()
    let activeProfileID = await fixture.preferences.activeProfileID()
    let defaultProfileID = await fixture.preferences.defaultProfileID()
    XCTAssertEqual(profiles, UITestFixtureConfiguration.populatedProfiles)
    XCTAssertEqual(activeProfileID, UITestFixtureConfiguration.populatedProfiles.first?.id)
    XCTAssertEqual(defaultProfileID, UITestFixtureConfiguration.populatedProfiles.first?.id)

    try await UITestScenario.historyPopulated.configuration.seed(
      preferences: fixture.preferences,
      data: fixture.data
    )
    let history = try await fixture.data.loadHistory()
    XCTAssertEqual(history, UITestFixtureConfiguration.populatedHistory)

    try await UITestScenario.historyEmpty.configuration.seed(
      preferences: fixture.preferences,
      data: fixture.data
    )
    let emptyHistory = try await fixture.data.loadHistory()
    XCTAssertEqual(emptyHistory, [])

    try await UITestScenario.profilesEmpty.configuration.seed(
      preferences: fixture.preferences,
      data: fixture.data
    )
    let emptyProfiles = try await fixture.data.loadProfiles()
    XCTAssertEqual(emptyProfiles, [])
  }

  @MainActor
  func testDefaultServiceFactoryKeepsLegacySeedBehavior() async throws {
    let services = await AppServices.uiTesting(seedCredential: true)

    let provider = await services.preferences.selectedProvider()
    let draftRetention = await services.preferences.draftRetentionChoice()
    let historyRetention = await services.preferences.historyRetentionChoice()
    let apiKey = try await services.keychain.apiKey(for: .openAI)
    let profiles = try await services.data.loadProfiles()
    let history = try await services.data.loadHistory()
    XCTAssertEqual(provider, .openAI)
    XCTAssertEqual(draftRetention, .undecided)
    XCTAssertEqual(historyRetention, .undecided)
    XCTAssertEqual(apiKey, "ui-testing-key")
    XCTAssertEqual(profiles, [])
    XCTAssertEqual(history, [])
    XCTAssertTrue(services.promptTarget.isAccessibilityTrusted)
    XCTAssertFalse(services.autoDismissQuickCheck)
  }

  func testGrammarGateReleasesFirstRequestAndFailsTheNextDeterministically() async throws {
    let grammar = UITestingGrammarService(behavior: .holdFirstCheckThenFailSubsequent)
    let destination = try OutboundDestination(
      provider: .claude,
      model: LLMProvider.claude.defaultModel
    )
    let first = Task {
      try await grammar.check(
        text: "this are a test",
        destination: destination,
        profilePrompt: nil
      )
    }
    await grammar.releaseCheck()
    let firstResult = try await first.value
    XCTAssertEqual(
      firstResult,
      GrammarResult(
        corrected: "this is a test",
        explanation: "Changed subject-verb agreement."
      )
    )

    do {
      _ = try await grammar.check(
        text: "this are a test",
        destination: destination,
        profilePrompt: nil
      )
      XCTFail("Expected the deterministic subsequent-request failure")
    } catch let error as BexError {
      XCTAssertEqual(error, .connectionFailure("Forced UI test grammar failure."))
    }
  }

  @MainActor
  func testTargetSeedsExposePermissionCopyOnlyAndCountedDeliveryEffect() async throws {
    let copyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("UITestScenarioCopy-\(UUID().uuidString).txt")
    let pasteboard = UITestingPasteboard(path: copyURL.path)
    defer { try? FileManager.default.removeItem(at: copyURL) }
    let denied = UITestingPromptTargetService(
      configuration: UITestScenario.permissionDenied.configuration.target,
      pasteboard: pasteboard
    )
    XCTAssertFalse(denied.isAccessibilityTrusted)
    XCTAssertFalse(denied.requestAccessibilityTrust())
    let deniedTarget = try denied.captureFrontmostTarget().target
    XCTAssertEqual(deniedTarget.kind, .copyOnly)
    let deniedOutcome = try await denied.deliver(
      "Copy-only correction",
      to: deniedTarget,
      pressReturn: true
    )
    XCTAssertEqual(deniedOutcome, .copied)
    XCTAssertEqual(
      try String(contentsOf: copyURL, encoding: .utf8),
      "Copy-only correction"
    )

    let sinkURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("UITestScenarioDelivery-\(UUID().uuidString).txt")
    let eventsURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("UITestScenarioDelivery-\(UUID().uuidString).json")
    defer {
      try? FileManager.default.removeItem(at: sinkURL)
      try? FileManager.default.removeItem(at: eventsURL)
    }
    var targetSeed = UITestScenario.deliveryFailureEffect.configuration.target
    targetSeed.sinkPath = sinkURL.path
    targetSeed.deliveryEventsPath = eventsURL.path
    let targetService = UITestingPromptTargetService(
      configuration: targetSeed,
      pasteboard: pasteboard
    )
    let target = try targetService.captureFrontmostTarget().target

    do {
      _ = try await targetService.deliver("Corrected text", to: target, pressReturn: false)
      XCTFail("Expected the deterministic delivery failure")
    } catch let failure as PromptDeliveryFailure {
      XCTAssertEqual(failure.effect, .pastedNotSubmitted)
    }
    XCTAssertEqual(try String(contentsOf: sinkURL, encoding: .utf8), "Corrected text")
    XCTAssertEqual(
      try JSONDecoder().decode(
        [UITestDeliveryEvent].self,
        from: Data(contentsOf: eventsURL)
      ),
      [UITestDeliveryEvent(sequence: 1, effect: .pastedNotSubmitted)]
    )
  }
}

private struct UITestSeedFixture {
  let suiteName: String
  let directory: URL
  let preferences: PreferencesStore
  let data: BexDataStore

  init() throws {
    suiteName = "UITestScenarioContractTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw NSError(domain: "UITestScenarioContractTests", code: 1)
    }
    defaults.removePersistentDomain(forName: suiteName)
    preferences = PreferencesStore(defaults: defaults)
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("UITestScenarioContractTests-\(UUID().uuidString)")
    data = BexDataStore(fileURL: directory.appendingPathComponent("data.json"))
  }

  func remove() {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }
}
