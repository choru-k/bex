#if !BEX_UI_TEST_ARTIFACT
  #error("App-hosted tests require the UITesting build configuration; normal Debug/Release hosts are unsafe for relaunch testing.")
#endif

import AppKit
import Darwin
import SwiftUI
import UserNotifications
import XCTest

@testable import Bex

final class UITestScenarioContractTests: XCTestCase {
  private func resolveArtifact(
    arguments: [String] = ["BexUIValidation"], environment: [String: String] = [:],
    debugBuild: Bool = true, artifactBuild: Bool = true,
    bundleIdentifier: String? = AppLaunchMode.artifactBundleIdentifier,
    artifactMarker: Any? = AppLaunchMode.artifactMarkerValue
  ) -> AppLaunchMode {
    AppLaunchMode.resolve(arguments: arguments, environment: environment,
      debugBuild: debugBuild, artifactBuild: artifactBuild,
      bundleIdentifier: bundleIdentifier, artifactMarker: artifactMarker)
  }

  func testLaunchSelectorsResolveOneFailClosedDebugMode() {
    for (arguments, environment) in [
      (["BexUIValidation"], [String: String]()),
      (["BexUIValidation", "--ui-testing"], [String: String]()),
      (["BexUIValidation"], ["BEX_UI_TESTING": "1"]),
      (["BexUIValidation", "--ui-testing"], ["BEX_UI_TESTING": "1"]),
      (["BexUIValidation"], ["BEX_UI_TEST_SCENARIO": "default"]),
    ] {
      XCTAssertEqual(resolveArtifact(arguments: arguments, environment: environment), .isolatedUITesting)
      XCTAssertEqual(resolveArtifact(arguments: arguments, environment: environment, debugBuild: false), .rejectedUITesting)
      XCTAssertEqual(resolveArtifact(arguments: arguments, environment: environment, artifactBuild: false), .rejectedUITesting)
    }
    for value in ["true", "0", ""] {
      XCTAssertEqual(resolveArtifact(environment: ["BEX_UI_TESTING": value]), .rejectedUITesting)
    }
    for debug in [true, false] {
      XCTAssertEqual(resolveArtifact(debugBuild: debug, artifactBuild: false,
        bundleIdentifier: "com.bex.desktop", artifactMarker: nil), .production)
    }
  }

  func testRealTargetRequiresSeparateManualModeAndNeverUpgradesIsolatedLaunch() {
    let environment = ["BEX_UI_TESTING": "1", "BEX_UI_TEST_REAL_TARGET": "1"]
    XCTAssertEqual(resolveArtifact(arguments: ["--ui-testing"], environment: environment), .rejectedUITesting)
    XCTAssertEqual(resolveArtifact(arguments: ["--ui-testing", "--ui-testing-system-target"], environment: environment), .manualSystemTargetTesting)
    XCTAssertEqual(resolveArtifact(arguments: ["--ui-testing", "--ui-testing-system-target"], environment: environment, debugBuild: false), .rejectedUITesting)
    XCTAssertEqual(resolveArtifact(arguments: ["--ui-testing", "--ui-testing-system-target"]), .rejectedUITesting)
    // A lost manual flag rejects; losing both markers downgrades to fixtures only.
    XCTAssertEqual(resolveArtifact(environment: ["BEX_UI_TEST_REAL_TARGET": "1"]), .rejectedUITesting)
    XCTAssertEqual(resolveArtifact(), .isolatedUITesting)
  }

  func testArtifactMetadataMismatchNeverFallsThroughToProduction() {
    let invalidMarkers: [Any?] = [nil, "", "false", "isolated-ui-v2", false, 1, NSNull(), ["mode": "isolated-ui-v1"]]
    for marker in invalidMarkers {
      XCTAssertEqual(resolveArtifact(artifactMarker: marker), .rejectedUITesting)
    }
    for identifier in [nil, "com.bex.desktop", "com.bex.desktop.manual-copy"] {
      XCTAssertEqual(resolveArtifact(bundleIdentifier: identifier), .rejectedUITesting)
    }
    for marker in invalidMarkers.compactMap({ $0 }) + [AppLaunchMode.artifactMarkerValue] {
      XCTAssertEqual(resolveArtifact(artifactBuild: false, bundleIdentifier: "com.bex.desktop",
        artifactMarker: marker), .rejectedUITesting)
    }
    XCTAssertEqual(resolveArtifact(artifactBuild: false, bundleIdentifier: "com.bex.desktop.manual-copy",
      artifactMarker: nil), .rejectedUITesting)
  }

  func testNormalDebugAndReleaseRejectEveryTestSelectorAndMalformedVariant() {
    for debug in [true, false] {
      for argument in ["--ui-testing", "--ui-testing-system-target", "--ui-testing=1",
        "--ui-testing-system-target=1", "--ui-testing-unknown", "--missing-credential",
        "--open-fix-and-send", "--bex-ui-artifact-probe"] {
        XCTAssertEqual(resolveArtifact(arguments: [argument], debugBuild: debug,
          artifactBuild: false, bundleIdentifier: "com.bex.desktop", artifactMarker: nil), .rejectedUITesting)
      }
      for environment in [["BEX_UI_TESTING": "1"], ["BEX_UI_TESTING": "0"],
        ["BEX_UI_TEST_SCENARIO": "default"], ["BEX_UI_TEST_REAL_TARGET": "1"]] {
        XCTAssertEqual(resolveArtifact(environment: environment, debugBuild: debug,
          artifactBuild: false, bundleIdentifier: "com.bex.desktop", artifactMarker: nil), .rejectedUITesting)
      }
    }
    for argument in ["--ui-testing=1", "--ui-testing-system-target=1", "--ui-testing-unknown"] {
      XCTAssertEqual(resolveArtifact(arguments: [argument]), .rejectedUITesting)
    }
  }

  func testCompiledHostHasDedicatedArtifactIdentityWithoutRuntimeSelectors() {
    XCTAssertTrue(AppLaunchMode.isUITestArtifactBuild)
    XCTAssertEqual(AppLaunchMode.resolve(arguments: [], environment: [:]), .isolatedUITesting)
    XCTAssertEqual(Bundle.main.bundleIdentifier, AppLaunchMode.artifactBundleIdentifier)
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: AppLaunchMode.artifactMarkerKey) as? String,
      AppLaunchMode.artifactMarkerValue)
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes"))
  }

  func testExecutableRelaunchWithNoArgumentsAndEmptyEnvironmentReachesFixtures() async throws {
    // Only the already admitted dedicated test host is spawned, never an arbitrary
    // path or normal build. This is authored Mac runtime evidence, not a cloud pass.
    XCTAssertEqual(AppLaunchMode.resolve(arguments: [], environment: [:]), .isolatedUITesting)
    guard AppLaunchMode.isUITestArtifactBuild,
      Bundle.main.bundleIdentifier == AppLaunchMode.artifactBundleIdentifier,
      let executable = Bundle.main.executableURL else {
      XCTFail("Refusing to launch an unmarked executable")
      return
    }
    for _ in 0..<2 {
      let ready = expectation(description: "Arg/env-free process constructed fixture graph")
      let output = Pipe()
      let recorder = UITestFixtureReadiness(expectation: ready)
      output.fileHandleForReading.readabilityHandler = { handle in
        recorder.consume(handle.availableData)
      }
      let process = Process()
      process.executableURL = executable
      process.arguments = []
      process.environment = [:]
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      defer {
        output.fileHandleForReading.readabilityHandler = nil
        // Only this test-owned child PID can be signaled; never an existing app.
        if process.isRunning {
          _ = kill(process.processIdentifier, SIGKILL)
          process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
      }
      try process.run()
      await fulfillment(of: [ready], timeout: 10)
      output.fileHandleForReading.readabilityHandler = nil
      if process.isRunning { process.terminate() }
      for _ in 0..<200 where process.isRunning {
        try await Task.sleep(for: .milliseconds(25))
      }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
  }

  @MainActor
  func testIsolatedFactoryInstallsOnlyFixtureCapabilitiesAndIndependentCredentials() async throws {
    let seeded = try await AppServices.uiTesting(seedCredential: true, environment: [:])
    let unseeded = try await AppServices.uiTesting(seedCredential: false, environment: [:])
    let firstKey = try await seeded.keychain.apiKey(for: .openAI)
    let secondKey = try await unseeded.keychain.apiKey(for: .openAI)
    XCTAssertEqual(firstKey, "ui-testing-key")
    XCTAssertNil(secondKey)
    await seeded.preferences.setSelectedProvider(.claude)
    let secondProvider = await unseeded.preferences.selectedProvider()
    XCTAssertEqual(secondProvider, .openAI)
    XCTAssertTrue(seeded.grammar is UITestingGrammarService)
    XCTAssertTrue(seeded.promptTarget is UITestingPromptTargetService)
    XCTAssertTrue(seeded.pasteboard is UITestingPasteboard)
    XCTAssertTrue(seeded.hookManager is UITestingHookManager)
    XCTAssertTrue(seeded.promptGateIPC is UITestingPromptGateIPC)
    let effects = seeded.runtimeEffects
    XCTAssertNil(effects.configureStudyNotifications(UITestNotificationDelegate()))
    XCTAssertFalse(effects.openAuthorizationURL(URL(string: "https://example.com")!))
    XCTAssertFalse(effects.permitsExternalFocus)
    XCTAssertFalse(effects.persistsWindowFrames)
    XCTAssertTrue(effects.usesUITestingCommands)
    // These injected closures have no real status-file or process target capability.
    effects.publishStudyStatus(1, .normal, nil, nil, Date(timeIntervalSince1970: 0))
    effects.activateExternalApplication(42)
    let hotKey = effects.makeHotKey()
    try hotKey.register(Shortcut(id: 77, chord: .defaultFixAndSend), action: {})
    hotKey.unregisterAll()
    do { _ = try await seeded.codexOAuth.begin(); XCTFail("UI validation must reject OAuth") }
    catch let error as BexError {
      XCTAssertEqual(error, .oauthFailure("Account login is unavailable in isolated UI validation."))
    }
  }

  @MainActor
  func testFactoryRejectsLegacyRealTargetBeforeBuildingServices() async {
    do {
      _ = try await AppServices.uiTesting(seedCredential: true,
        environment: ["BEX_UI_TEST_REAL_TARGET": "1"])
      XCTFail("A fixture flag cannot grant system target access")
    } catch {
      XCTAssertTrue(error is UITestingIsolationError)
    }
  }

  func testDisabledOAuthNeverConstructsListenerOrCallsTransport() async throws {
    let counter = UITestIsolationCounter()
    let transport = UITestRecordingTransport()
    let oauth = CodexOAuthService(
      keychain: KeychainStore(service: "UITestIsolation-\(UUID().uuidString)", inMemory: true),
      transport: transport, authorizationEnabled: false,
      makeListener: { _ in counter.increment(); return UITestingOAuthListener() }
    )
    for _ in 0..<2 {
      do { _ = try await oauth.begin(); XCTFail("OAuth must fail before admission") }
      catch { XCTAssertTrue(error is BexError) }
    }
    XCTAssertEqual(counter.value, 0)
    let calls = await transport.calls
    XCTAssertEqual(calls, 0)
  }

  func testFallbackTransportAndListenerDenyAllIO() async {
    do {
      _ = try await UITestingHTTPTransport().data(for: URLRequest(url: URL(string: "https://example.com/token")!))
      XCTFail("No request may leave validation")
    } catch { XCTAssertTrue(error is BexError) }
    do { try await UITestingOAuthListener().start(); XCTFail("No callback port may bind") }
    catch { XCTAssertTrue(error is BexError) }
    do { _ = try await UITestingOAuthListener().waitForCallback(); XCTFail("No callback may arrive") }
    catch { XCTAssertTrue(error is BexError) }
  }

  @MainActor
  func testIsolatedWindowsHaveNoAutosaveDomainAndSettingsCopiesToInjectedPasteboard() async throws {
    for configuration in [WindowCoordinator.mainWindowConfiguration, WindowCoordinator.welcomeWindowConfiguration] {
      let controller = WindowCoordinator.makeWindowController(configuration: configuration,
        rootView: EmptyView(), persistsWindowFrames: false)
      XCTAssertEqual(controller.window?.frameAutosaveName, "")
      controller.close()
    }
    let panel = PromptGatePanelController(rootView: AnyView(EmptyView()), cancelAction: {}, frameAutosaveName: nil)
    XCTAssertEqual(panel.window?.frameAutosaveName, "")
    panel.close()
    let services = try await AppServices.uiTesting(seedCredential: false, environment: [:])
    let recorder = UITestCopyRecorder()
    let settings = SettingsViewModel(preferences: services.preferences, keychain: services.keychain,
      grammar: services.grammar, codexOAuth: services.codexOAuth, promptTarget: services.promptTarget,
      hookManager: services.hookManager, applyAppearance: { _ in },
      openAuthorizationURL: services.runtimeEffects.openAuthorizationURL, pasteboard: recorder,
      initialWorkingDirectory: "/ui-validation", initialOMPExecutablePath: "/ui-validation/omp")
    settings.copyIntegrationArtifact("fixture integration preview")
    XCTAssertEqual(recorder.values, ["fixture integration preview"])
    XCTAssertEqual(settings.ompWorkingDirectory, "/ui-validation")
  }

  func testArtifactValidationRejectsExistingOutsideAndSymlinkPathsWithoutChangingThem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITestArtifacts-\(UUID().uuidString)", isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("UITestOutside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let sentinel = root.appendingPathComponent("existing.txt")
    try Data("keep me".utf8).write(to: sentinel)
    XCTAssertThrowsError(try UITestingArtifacts.validate(sentinel, beneath: root, mustBeNew: true))
    XCTAssertThrowsError(try UITestingArtifacts.validate(outside.appendingPathComponent("no.txt"), beneath: root, mustBeNew: true))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try UITestingArtifacts.validate(link.appendingPathComponent("no.txt"), beneath: root, mustBeNew: true))
    let internalLink = root.appendingPathComponent("internal-link")
    try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: root)
    XCTAssertThrowsError(try UITestingArtifacts.validate(internalLink.appendingPathComponent("no.txt"), beneath: root, mustBeNew: true))
    let dangling = root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing.txt"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dangling.path))
    XCTAssertThrowsError(try UITestingArtifacts.validate(dangling, beneath: root, mustBeNew: true))
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep me")
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("no.txt").path))
    try UITestingArtifacts.validate(root.appendingPathComponent("fresh.txt"), beneath: root, mustBeNew: true)
  }

  func testArtifactPreparationRejectsCanonicalAliasesAndOverlappingOutputs() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("UITestAliases-\(UUID().uuidString)", isDirectory: true)
    let alias = FileManager.default.temporaryDirectory.appendingPathComponent("UITestAlias-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
    defer { try? FileManager.default.removeItem(at: alias); try? FileManager.default.removeItem(at: base) }
    var duplicate = UITestFixtureConfiguration()
    duplicate.pasteboardPath = base.appendingPathComponent("same.txt").path
    duplicate.target.sinkPath = alias.appendingPathComponent("same.txt").path
    XCTAssertThrowsError(try UITestingArtifacts.prepare(configuration: &duplicate, scenario: .standard, temporaryDirectory: alias))
    var overlapping = UITestFixtureConfiguration()
    overlapping.pasteboardPath = base.appendingPathComponent("parent").path
    overlapping.integrationTranscriptPath = base.appendingPathComponent("parent/events.json").path
    XCTAssertThrowsError(try UITestingArtifacts.prepare(configuration: &overlapping, scenario: .standard, temporaryDirectory: base))
    for suffix in ["", "/data.json"] {
      var resume = UITestScenario.dirtyEditorResume.configuration
      resume.pasteboardPath = base.appendingPathComponent("BexUITesting-dirty-editor-resume" + suffix).path
      XCTAssertThrowsError(try UITestingArtifacts.prepare(configuration: &resume, scenario: .dirtyEditorResume, temporaryDirectory: alias))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
  }

  func testFreshArtifactsHaveDistinctRootsAndResumeRemainsInsideFixtureNamespace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITestRoots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var first = UITestFixtureConfiguration()
    var second = UITestFixtureConfiguration()
    let firstRoot = try UITestingArtifacts.prepare(configuration: &first, scenario: .standard, temporaryDirectory: root)
    let secondRoot = try UITestingArtifacts.prepare(configuration: &second, scenario: .standard, temporaryDirectory: root)
    XCTAssertNotEqual(firstRoot, secondRoot)
    XCTAssertTrue(try XCTUnwrap(first.pasteboardPath).hasPrefix(firstRoot.path + "/"))
    var resume = UITestScenario.dirtyEditorResume.configuration
    let resumeRoot = try UITestingArtifacts.prepare(configuration: &resume, scenario: .dirtyEditorResume, temporaryDirectory: root)
    let saved = resumeRoot.appendingPathComponent("data.json")
    try Data("preserve".utf8).write(to: saved)
    var resumed = UITestScenario.dirtyEditorResume.configuration
    XCTAssertEqual(try UITestingArtifacts.prepare(configuration: &resumed, scenario: .dirtyEditorResume, temporaryDirectory: root), resumeRoot)
    XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "preserve")
  }


  func testScenarioNamesAreStableCodableAndParseFromEnvironment() throws {
    XCTAssertEqual(
      UITestScenario.allCases.map(\.rawValue),
      [
        "default",
        "welcome",
        "fresh-consent",
        "configured-provider",
        "permission-denied",
        "permission-trusted",
        "hook-provided-client",
        "hook-skips-outbound-confirmation",
        "hook-check-in-flight",
        "hotkey-conflict",
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
    XCTAssertEqual(configuration.integrationTranscriptPath, "/tmp/bex-integrations.json")
    XCTAssertEqual(configuration.injectDriftIntegrationID, "omp-default")
    XCTAssertEqual(configuration.partialFailureIntegrationID, "omp-team")
  }

  func testNamedConfigurationsDeclareConsentPermissionHookFailureAndResumeStates() throws {
    let consent = UITestScenario.freshConsent.configuration
    XCTAssertEqual(consent.preferences.draftRetentionChoice, .undecided)
    XCTAssertEqual(consent.preferences.historyRetentionChoice, .undecided)
    XCTAssertEqual(consent.target.source, "A fresh consent UI test draft.")

    let configured = UITestScenario.configuredProvider.configuration
    XCTAssertEqual(configured.preferences.selectedProvider, .claude)
    XCTAssertEqual(configured.preferences.selectedModel, LLMProvider.claude.defaultModel)
    XCTAssertEqual(configured.preferences.selectedEffort, .high)
    XCTAssertEqual(configured.preferences.acceptedOutboundDisclosureProvider, .claude)
    XCTAssertEqual(configured.credentialProvider, .claude)

    XCTAssertEqual(configured.profiles, UITestFixtureConfiguration.populatedProfiles)
    XCTAssertEqual(
      configured.preferences.activeProfileID,
      UITestFixtureConfiguration.populatedProfiles.first?.id
    )
    XCTAssertFalse(UITestScenario.permissionDenied.configuration.target.isAccessibilityTrusted)
    XCTAssertFalse(UITestScenario.permissionDenied.configuration.target.requestedAccessibilityTrust)
    XCTAssertTrue(UITestScenario.permissionTrusted.configuration.target.isAccessibilityTrusted)
    XCTAssertTrue(UITestScenario.permissionTrusted.configuration.target.requestedAccessibilityTrust)

    let hook = try XCTUnwrap(UITestScenario.hookProvidedClient.configuration.hook)
    XCTAssertEqual(hook.client, .codex)
    XCTAssertEqual(hook.prompt, "Make this UI test prompt concise.")
    let directHook = UITestScenario.hookSkipsOutboundConfirmation.configuration
    XCTAssertEqual(directHook.preferences.acceptedOutboundDisclosureProvider, .openAI)
    XCTAssertEqual(directHook.preferences.confirmsHookOutboundPayloads, false)
    XCTAssertEqual(directHook.launchDestination, .hookPromptGate)
    let hookCheck = UITestScenario.hookCheckInFlight.configuration
    XCTAssertEqual(hookCheck.hook?.client, .claudeCode)
    XCTAssertEqual(hookCheck.preferences.confirmsHookOutboundPayloads, false)
    XCTAssertEqual(hookCheck.grammarBehavior, .holdPromptCheck)
    XCTAssertEqual(hookCheck.launchDestination, .hookPromptGate)
    XCTAssertEqual(
      UITestScenario.hotKeyConflict.configuration.hotKeyRegistration,
      .conflict
    )
    XCTAssertEqual(
      UITestScenario.promptDeliveryInFlight.configuration.target.deliveryGate,
      .untilReleased
    )

    XCTAssertEqual(
      UITestScenario.deliveryFailureEffect.configuration.target.deliveryFailureEffect,
      .copied
    )
    let dirtyEditor = UITestScenario.dirtyEditorResume.configuration
    XCTAssertTrue(dirtyEditor.preservesStoredState)
    XCTAssertEqual(
      dirtyEditor.preferences.savedDraft,
      "A saved UI test draft with unsent changes."
    )
    XCTAssertEqual(dirtyEditor.launchDestination, .history)
    XCTAssertTrue(UITestScenario.setupResume.configuration.preservesStoredState)
    XCTAssertEqual(UITestScenario.setupResume.configuration.credentialProvider, nil)
    XCTAssertEqual(UITestScenario.setupResume.configuration.launchDestination, .setup(.fixAndSend))
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
    let savedDraft = await fixture.preferences.savedDraft()
    XCTAssertEqual(savedDraft, "A saved UI test draft with unsent changes.")

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
    let services = try await AppServices.uiTesting(seedCredential: true, environment: [:])

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
    do {
      _ = try await denied.deliver("Must not submit", to: deniedTarget, pressReturn: true)
      XCTFail("Automatic Return must be unavailable")
    } catch {
      XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
    }
    let deniedOutcome = try await denied.deliver(
      "Copy-only correction",
      to: deniedTarget,
      action: .copyCorrection
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
      XCTAssertEqual(failure.effect, .copied)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: sinkURL.path))
    XCTAssertEqual(try String(contentsOf: copyURL, encoding: .utf8), "Corrected text")
    XCTAssertEqual(
      try JSONDecoder().decode(
        [UITestDeliveryEvent].self,
        from: Data(contentsOf: eventsURL)
      ),
      [UITestDeliveryEvent(sequence: 1, effect: .copied)]
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

@MainActor
private final class UITestNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {}

@MainActor
private final class UITestCopyRecorder: PasteboardWriting {
  var values: [String] = []
  func write(_ string: String) throws { values.append(string) }
}

private final class UITestIsolationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor UITestRecordingTransport: HTTPTransport {
  private(set) var calls = 0
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    calls += 1
    throw BexError.invalidResponse
  }
}

private final class UITestFixtureReadiness: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = Data()
  private var fulfilled = false
  private let expectation: XCTestExpectation

  init(expectation: XCTestExpectation) { self.expectation = expectation }

  func consume(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard !fulfilled else { return }
    bytes.append(data)
    if String(decoding: bytes, as: UTF8.self).contains("BEX_UI_FIXTURE_READY_V1\n") {
      fulfilled = true
      expectation.fulfill()
    }
  }
}
