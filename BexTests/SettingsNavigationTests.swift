import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest

@testable import Bex

@MainActor
final class SettingsNavigationTests: XCTestCase {
  func testApplicationMenuKeepsTaskFallbacksAndNativeCommands() throws {
    let fixAndSendChord = KeyChord(
      keyCode: UInt32(kVK_ANSI_J),
      modifiers: UInt32(controlKey | shiftKey)
    )

    let menuTarget = MenuTargetProbe()
    let mainMenu = AppDelegate.makeMainMenu(
      target: menuTarget,
      fixAndSendChord: fixAndSendChord
    )

    // The status item is a popover now (see `MenuBarHubView`), so the application menu is
    // the only menu left carrying the task commands — and it has to keep carrying them:
    // it is the fallback the hot-key conflict message points the owner at.
    let toolsMenu = mainMenu.item(withTitle: "Tools")?.submenu
    XCTAssertEqual(
      toolsMenu?.items.map(\.title),
      ["Fix & Send…", "", "Learn", "History", "Writing Styles"]
    )
    let fixAndSendItem = try XCTUnwrap(toolsMenu?.item(withTitle: "Fix & Send…"))
    XCTAssertEqual(fixAndSendItem.action, NSSelectorFromString("openStandaloneFixAndSend"))
    XCTAssertTrue(NSApp.sendAction(fixAndSendItem.action!, to: fixAndSendItem.target, from: nil))
    XCTAssertEqual(menuTarget.fixAndSendInvocations, 1)
    XCTAssertNil(toolsMenu?.item(withTitle: "Profiles"))
    // Learning and Study collapsed into the one Learn page; two names for one destination
    // would just be a way for them to drift apart.
    XCTAssertNil(toolsMenu?.item(withTitle: "Learning"))
    XCTAssertNil(toolsMenu?.item(withTitle: "Study"))
    XCTAssertEqual(mainMenu.items.map(\.title), ["Bex", "Edit", "Tools", "Window", "Help"])

    let appItems = mainMenu.item(withTitle: "Bex")?.submenu?.items ?? []
    let appTitles = appItems.map(\.title)
    for expected in [
      "About Bex", "Settings…", "Services", "Hide Bex", "Hide Others", "Show All",
      "Quit Bex",
    ] {
      XCTAssertTrue(
        appTitles.contains(expected), "Missing standard application command: \(expected)")
    }
    XCTAssertNotNil(mainMenu.item(withTitle: "Bex")?.submenu?.item(withTitle: "Services")?.submenu)

    let editMenu = mainMenu.item(withTitle: "Edit")?.submenu
    for expected in [
      "Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style", "Delete",
      "Select All", "Find", "Spelling and Grammar", "Substitutions", "Transformations",
      "Speech",
    ] {
      XCTAssertNotNil(
        editMenu?.item(withTitle: expected), "Missing standard Edit command: \(expected)")
    }

    let windowMenu = mainMenu.item(withTitle: "Window")?.submenu
    for expected in ["Close", "Minimize", "Zoom", "Bring All to Front"] {
      XCTAssertNotNil(
        windowMenu?.item(withTitle: expected), "Missing standard Window command: \(expected)")
    }

    XCTAssertEqual(shortcutItem(.fixAndSend, in: mainMenu)?.keyEquivalent, "j")
  }

  func testHotKeyConflictMessageNamesFixAndSendFailure() {
    XCTAssertNil(AppDelegate.hotKeyConflictMessage(for: []))
    XCTAssertEqual(
      AppDelegate.hotKeyConflictMessage(for: [.fixAndSend]),
      "Fix & Send shortcut could not be registered. The command remains available here and "
        + "in the Bex menu."
    )
  }

  func testShortcutEditingRejectsOSConflictWithoutChangingPersistence() async {
    let fixture = SettingsFixture()
    defer { fixture.remove() }

    let shortcutProbe = ShortcutUpdateProbe()
    let viewModel = fixture.makeViewModel { shortcut, chord in
      try shortcutProbe.update(shortcut, chord: chord)
    }
    await viewModel.load()

    XCTAssertEqual(viewModel.fixAndSendKeyChord, KeyChord.defaultFixAndSend)

    let osConflict = KeyChord(
      keyCode: UInt32(kVK_ANSI_I),
      modifiers: UInt32(cmdKey | optionKey)
    )
    shortcutProbe.failingChord = osConflict
    XCTAssertEqual(
      viewModel.updateKeyChord(osConflict, for: BexShortcut.fixAndSend),
      .rejected
    )
    XCTAssertEqual(shortcutProbe.attemptedUpdates.map(\.1), [osConflict])
    XCTAssertEqual(
      viewModel.shortcutError(for: BexShortcut.fixAndSend),
      "macOS or another app is already using that shortcut."
    )
    XCTAssertEqual(viewModel.fixAndSendKeyChord, KeyChord.defaultFixAndSend)
    let persistedAfterConflict = await fixture.preferences.fixAndSendKeyChord()
    XCTAssertEqual(persistedAfterConflict, KeyChord.defaultFixAndSend)

    let replacement = KeyChord(
      keyCode: UInt32(kVK_ANSI_L),
      modifiers: UInt32(controlKey | shiftKey)
    )
    shortcutProbe.failingChord = nil
    XCTAssertEqual(
      viewModel.updateKeyChord(replacement, for: BexShortcut.fixAndSend),
      .accepted
    )
    await viewModel.waitForCurrentWork()
    XCTAssertEqual(viewModel.fixAndSendKeyChord, replacement)
    XCTAssertNil(viewModel.shortcutError(for: BexShortcut.fixAndSend))
    let persistedAfterSuccess = await fixture.preferences.fixAndSendKeyChord()
    XCTAssertEqual(persistedAfterSuccess, replacement)
  }

  func testRetentionBindingsAndDestructiveIntentsRemainIndependent() async {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    var deletedDraftCount = 0
    var clearedHistoryCount = 0
    let viewModel = fixture.makeViewModel(
      onDeleteSavedDraft: { deletedDraftCount += 1 },
      onClearHistory: { clearedHistoryCount += 1 }
    )
    await viewModel.load()

    viewModel.selectDraftRetentionChoice(.enabled)
    viewModel.selectHistoryRetentionChoice(.disabled)
    viewModel.setConfirmsHookOutboundPayloads(false)
    viewModel.deleteSavedDraft()
    viewModel.clearHistory()
    await viewModel.waitForCurrentWork()

    XCTAssertEqual(viewModel.draftRetentionChoice, .enabled)
    XCTAssertEqual(viewModel.historyRetentionChoice, .disabled)
    XCTAssertFalse(viewModel.confirmsHookOutboundPayloads)
    let storedDraftRetention = await fixture.preferences.draftRetentionChoice()
    let storedHistoryRetention = await fixture.preferences.historyRetentionChoice()
    XCTAssertEqual(storedDraftRetention, .enabled)
    XCTAssertEqual(storedHistoryRetention, .disabled)
    let storedHookConfirmation = await fixture.preferences.confirmsHookOutboundPayloads()
    XCTAssertFalse(storedHookConfirmation)
    XCTAssertEqual(deletedDraftCount, 1)
    XCTAssertEqual(clearedHistoryCount, 1)
    XCTAssertFalse(viewModel.isClearingHistory)
    XCTAssertNil(viewModel.userVisibleError)
    let draftDisclosure = SettingsViewModel.draftRetentionDisclosure
    XCTAssertTrue(draftDisclosure.contains("standalone Fix & Send draft"))
    XCTAssertTrue(draftDisclosure.contains("restored after Bex relaunches"))
    XCTAssertTrue(draftDisclosure.contains("never block correction"))
    let historyDisclosure = SettingsViewModel.historyRetentionDisclosure
    for requiredDetail in [
      "standalone and target-bound Fix & Send flows", "original", "correction", "explanation",
      "provider", "model", "Writing Style name", "timestamp", "at most 500 entries",
    ] {
      XCTAssertTrue(
        historyDisclosure.contains(requiredDetail),
        "Missing history disclosure detail: \(requiredDetail)"
      )
    }
  }

  func testClearHistoryFailureIsVisible() async {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    let viewModel = fixture.makeViewModel(
      onClearHistory: {
        throw SettingsClearHistoryError.storageUnavailable
      }
    )
    await viewModel.load()

    viewModel.clearHistory()
    await viewModel.waitForCurrentWork()

    XCTAssertEqual(
      viewModel.userVisibleError,
      "Couldn’t clear History. The History database is unavailable."
    )
    XCTAssertFalse(viewModel.isClearingHistory)
  }

  func testAccessibilityRequestVisibilityAndActivationRefreshState() async {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    fixture.target.isAccessibilityTrusted = false
    let viewModel = fixture.makeViewModel()
    await viewModel.load()

    XCTAssertFalse(viewModel.accessibilityTrusted)
    XCTAssertTrue(viewModel.showsAccessibilityRequest)

    fixture.target.grantsOnRequest = true
    viewModel.requestAccessibility()
    XCTAssertTrue(viewModel.accessibilityTrusted)
    XCTAssertFalse(viewModel.showsAccessibilityRequest)
    XCTAssertEqual(fixture.target.requestCount, 1)
    XCTAssertEqual(
      viewModel.accessibilityStatusMessage,
      "Accessibility is enabled. Invoke Fix & Send again to capture the focused field."
    )

    fixture.target.isAccessibilityTrusted = false
    viewModel.refreshAccessibilityState()
    XCTAssertFalse(viewModel.accessibilityTrusted)
    XCTAssertTrue(viewModel.showsAccessibilityRequest)
    XCTAssertEqual(
      viewModel.accessibilityStatusMessage,
      "Accessibility was revoked. Fix & Send will use copy-only fallback for manual capture."
    )

    fixture.target.isAccessibilityTrusted = true
    viewModel.refreshAccessibilityState()
    XCTAssertTrue(viewModel.accessibilityTrusted)
    XCTAssertFalse(viewModel.showsAccessibilityRequest)
    XCTAssertTrue(viewModel.accessibilityStatusMessage?.contains("Invoke Fix & Send again") == true)
  }

  func testSelectedProviderConnectionRoutesBackToFixAndSendTarget() async throws {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    await fixture.preferences.setSelectedProvider(.claude)
    try await fixture.keychain.saveAPIKey("test-key", for: .claude)

    var routeIntents: [SettingsRouteIntent] = []
    let viewModel = fixture.makeViewModel(
      setupOrigin: .fixAndSend,
      connectionSucceeds: true,
      onSetupRoute: { routeIntents.append($0) }
    )
    await viewModel.load()

    XCTAssertTrue(viewModel.isSelectedProviderConnected)
    XCTAssertEqual(viewModel.setupRouteTitle, "Return to Target and Invoke Fix & Send")
    XCTAssertNil(viewModel.modelFetchError)
    XCTAssertTrue(viewModel.hookStatuses.values.allSatisfy { $0 == .unavailable("Offline") })

    await viewModel.requestSetupRoute()
    XCTAssertEqual(routeIntents, [.returnToFixAndSendTarget])
  }

  func testProviderDisclosureNamesEachActionPayloadAndOllamaLocation() async {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    await fixture.preferences.setSelectedProvider(.ollama)
    await fixture.preferences.setOllamaURL("http://127.0.0.1:11434")

    let localViewModel = fixture.makeViewModel()
    await localViewModel.load()
    XCTAssertTrue(
      localViewModel.providerDisclosure.hasPrefix(
        "The configured Ollama endpoint is local to this Mac."
      )
    )
    for requiredDetail in [
      "Standalone Fix & Send sends the full draft plus any custom Writing Style guidance.",
      "Rewrite sends the corrected draft.",
      "Target-bound Fix & Send sends the masked prompt; the payload is shown for approval whenever confirmation is required.",
      "Writing Style generation sends the labeled context fields you fill in: Role, Audience,"
        + " Tone, Formality, Domain, and Additional notes.",
    ] {
      XCTAssertTrue(
        localViewModel.providerDisclosure.contains(requiredDetail),
        "Missing provider payload disclosure: \(requiredDetail)"
      )
    }

    await fixture.preferences.setOllamaURL("https://127.foo.bar.baz")
    let deceptiveHostViewModel = fixture.makeViewModel()
    await deceptiveHostViewModel.load()
    XCTAssertTrue(
      deceptiveHostViewModel.providerDisclosure.hasPrefix(
        "The configured Ollama endpoint is external;"
      )
    )
    XCTAssertFalse(deceptiveHostViewModel.providerDisclosure.contains("local to this Mac"))

    await fixture.preferences.setOllamaURL("https://ollama.example.com")
    let externalViewModel = fixture.makeViewModel()
    await externalViewModel.load()
    XCTAssertTrue(
      externalViewModel.providerDisclosure.hasPrefix(
        "The configured Ollama endpoint is external;"
      )
    )
    XCTAssertFalse(externalViewModel.providerDisclosure.contains("local to this Mac"))

    await fixture.preferences.setSelectedProvider(.claude)
    let cloudViewModel = fixture.makeViewModel()
    await cloudViewModel.load()
    XCTAssertTrue(
      cloudViewModel.providerDisclosure.hasPrefix("Bex sends these payloads to Claude."))
  }

  func testOMPExecutableDiscoveryFindsNewestRegularMiseInstallOutsideGUIPath() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexOMPDiscovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let miseDataDirectory = root.appendingPathComponent("mise", isDirectory: true)

    func makeExecutable(version: String) throws -> URL {
      let executable =
        miseDataDirectory
        .appendingPathComponent(
          "installs/npm-oh-my-pi-pi-coding-agent/\(version)/node_modules/.bin/omp"
        )
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("#!/bin/sh\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: executable.path
      )
      return executable
    }

    _ = try makeExecutable(version: "17.2.9")
    let newest = try makeExecutable(version: "17.10.0")
    let symlink =
      miseDataDirectory
      .appendingPathComponent(
        "installs/npm-oh-my-pi-pi-coding-agent/99.0.0/node_modules/.bin/omp"
      )
    try FileManager.default.createDirectory(
      at: symlink.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: newest)

    let discovered = SettingsViewModel.defaultOMPExecutablePath(
      environment: [
        "PATH": root.appendingPathComponent("gui-path-without-omp").path,
        "MISE_DATA_DIR": miseDataDirectory.path,
      ],
      homeDirectory: root
    )
    XCTAssertEqual(
      URL(fileURLWithPath: discovered).resolvingSymlinksInPath(),
      newest.resolvingSymlinksInPath()
    )
  }

  func testOMPExecutableDiscoveryDoesNotSuggestANonexistentHomebrewPath() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexOMPDiscoveryEmpty-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    XCTAssertEqual(
      SettingsViewModel.defaultOMPExecutablePath(
        environment: [
          "PATH": root.appendingPathComponent("empty-path").path,
          "MISE_DATA_DIR": root.appendingPathComponent("empty-mise").path,
        ],
        homeDirectory: root
      ),
      ""
    )
  }

  func testStandardWindowsHaveDistinctAutosaveNamesAndContentMinimums() throws {
    let configurations = [
      WindowCoordinator.mainWindowConfiguration,
      WindowCoordinator.welcomeWindowConfiguration,
    ]

    XCTAssertEqual(
      Set(configurations.map(\.frameAutosaveName)),
      Set(["Bex.MainWindow", "Bex.WelcomeWindow"])
    )
    for configuration in configurations {
      let controller = WindowCoordinator.makeWindowController(
        configuration: configuration,
        rootView: EmptyView()
      )
      let window = try XCTUnwrap(controller.window)
      XCTAssertEqual(window.frameAutosaveName, configuration.frameAutosaveName)
      XCTAssertEqual(window.contentMinSize, configuration.minimumContentSize)
      XCTAssertLessThanOrEqual(
        configuration.minimumContentSize.width,
        configuration.defaultContentSize.width
      )
      XCTAssertLessThanOrEqual(
        configuration.minimumContentSize.height,
        configuration.defaultContentSize.height
      )
    }
  }

  private func shortcutItem(_ shortcut: BexShortcut, in menu: NSMenu) -> NSMenuItem? {
    let identifier = "bex-shortcut-\(shortcut.rawValue)"
    for item in menu.items {
      if item.identifier?.rawValue == identifier { return item }
      if let submenu = item.submenu, let match = shortcutItem(shortcut, in: submenu) {
        return match
      }
    }
    return nil
  }
}

@MainActor
private final class MenuTargetProbe: NSObject {
  private(set) var fixAndSendInvocations = 0

  @objc func openStandaloneFixAndSend() {
    fixAndSendInvocations += 1
  }
}

@MainActor
private final class SettingsFixture {
  let preferences: PreferencesStore
  let keychain: KeychainStore
  let target = SettingsPromptTargetStub()
  let hooks = SettingsHookManagerStub()
  private let service: String

  init() {
    service = "com.bex.tests.settings.\(UUID().uuidString)"
    UserDefaults.standard.removePersistentDomain(forName: service)
    preferences = PreferencesStore(defaults: UserDefaults(suiteName: service)!)
    keychain = KeychainStore(service: service, inMemory: true)
  }

  func remove() {
    UserDefaults.standard.removePersistentDomain(forName: service)
  }

  func makeViewModel(
    setupOrigin: SettingsSetupOrigin? = nil,
    connectionSucceeds: Bool = false,
    updateShortcut: @escaping @MainActor (BexShortcut, KeyChord) throws -> Void = { _, _ in },
    onDeleteSavedDraft: @escaping @MainActor () -> Void = {},
    onClearHistory: @escaping @MainActor () async throws -> Void = {},
    onSetupRoute: @escaping @MainActor (SettingsRouteIntent) -> Void = { _ in }
  ) -> SettingsViewModel {
    let transport = SettingsOfflineTransport()
    return SettingsViewModel(
      preferences: preferences,
      keychain: keychain,
      grammar: SettingsGrammarStub(connectionSucceeds: connectionSucceeds),
      codexOAuth: CodexOAuthService(keychain: keychain, transport: transport),
      promptTarget: target,
      hookManager: hooks,
      applyAppearance: { _ in },
      setupOrigin: setupOrigin,
      updateShortcut: updateShortcut,
      onDeleteSavedDraft: onDeleteSavedDraft,
      onClearHistory: onClearHistory,
      onSetupRoute: onSetupRoute
    )
  }
}
@MainActor
private final class ShortcutUpdateProbe {
  var failingChord: KeyChord?
  private(set) var attemptedUpdates: [(BexShortcut, KeyChord)] = []

  func update(_ shortcut: BexShortcut, chord: KeyChord) throws {
    attemptedUpdates.append((shortcut, chord))
    if chord == failingChord {
      throw HotKeyRegistrationError.carbon(status: OSStatus(eventHotKeyExistsErr))
    }
  }
}

private struct SettingsOfflineTransport: HTTPTransport {
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw URLError(.notConnectedToInternet)
  }
}

private struct SettingsGrammarStub: GrammarServicing {
  let connectionSucceeds: Bool

  func check(
    text: String,
    destination: OutboundDestination,
    profilePrompt: String?
  ) async throws -> GrammarResult {
    throw URLError(.notConnectedToInternet)
  }

  func rewrite(
    text: String,
    intent: RewriteIntent,
    destination: OutboundDestination
  ) async throws -> String {
    throw URLError(.notConnectedToInternet)
  }

  func define(
    text: String,
    destination: OutboundDestination
  ) async throws -> DictionaryLookup {
    throw URLError(.notConnectedToInternet)
  }

  func answerQuestion(
    question: String,
    context: String,
    destination: OutboundDestination
  ) async throws -> AskAnswer {
    throw BexError.invalidResponse
  }

  func classifyStudyPatterns(

    cards: [StudyCard],

    destination: OutboundDestination

  ) async throws -> [String: StudyPattern.Verdict] {

    [:]

  }

  func refreshWriterLevel(
    samples: [LearningSample],
    destination: OutboundDestination,
    now: Date
  ) async throws -> WriterLevelProfile {
    throw BexError.invalidResponse
  }

  func generateProfile(
    context: ProfileContext,
    destination: OutboundDestination
  ) async throws -> String {
    throw URLError(.notConnectedToInternet)
  }

  func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
    guard connectionSucceeds else { throw URLError(.notConnectedToInternet) }
    return [ModelOption(id: provider.defaultModel, name: provider.defaultModel)]
  }
}

private actor SettingsHookManagerStub: HookInstallationManaging {
  func status(for client: PromptClient) async -> HookInstallationStatus {
    .unavailable("Offline")
  }

  func install(_ client: PromptClient) async throws {}
  func uninstall(_ client: PromptClient) async throws {}
}

private enum SettingsClearHistoryError: LocalizedError {
  case storageUnavailable

  var errorDescription: String? {
    "The History database is unavailable."
  }
}

@MainActor
private final class SettingsPromptTargetStub: PromptTargetServicing {
  var isAccessibilityTrusted = false
  var grantsOnRequest = false
  private(set) var requestCount = 0

  func requestAccessibilityTrust() -> Bool {
    requestCount += 1
    if grantsOnRequest {
      isAccessibilityTrusted = true
    }
    return isAccessibilityTrusted
  }

  func captureFrontmostTarget() throws -> PromptCapture { fatalError("Not used") }
  func target(for hookRequest: HookReviewRequest) throws -> PromptTarget { fatalError("Not used") }

  func deliver(
    _ correctedText: String,
    to target: PromptTarget,
    pressReturn: Bool
  ) async throws -> PromptDeliveryOutcome {
    fatalError("Not used")
  }

  func discard(_ target: PromptTarget) {}
}
