import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest

@testable import Bex

@MainActor
final class SettingsNavigationTests: XCTestCase {
  func testStatusAndApplicationMenusKeepTaskFallbacksAndNativeCommands() {
    let quickCheckChord = KeyChord(
      keyCode: UInt32(kVK_ANSI_K),
      modifiers: UInt32(cmdKey | optionKey)
    )
    let fixAndSendChord = KeyChord(
      keyCode: UInt32(kVK_ANSI_J),
      modifiers: UInt32(controlKey | shiftKey)
    )

    let menuTarget = MenuTargetProbe()
    let statusMenu = AppDelegate.makeStatusMenu(
      target: menuTarget,
      quickCheckChord: quickCheckChord,
      fixAndSendChord: fixAndSendChord
    )
    XCTAssertEqual(Array(statusMenu.items.prefix(2).map(\.title)), ["Quick Check", "Fix & Send…"])
    XCTAssertEqual(statusMenu.items[1].action, NSSelectorFromString("openPromptGate"))
    XCTAssertTrue(
      NSApp.sendAction(statusMenu.items[1].action!, to: statusMenu.items[1].target, from: nil)
    )
    XCTAssertEqual(menuTarget.fixAndSendInvocations, 1)
    XCTAssertEqual(statusMenu.item(withTitle: "Writing Styles")?.title, "Writing Styles")
    XCTAssertNil(statusMenu.item(withTitle: "Profiles"))

    let statusQuickCheck = shortcutItem(.quickCheck, in: statusMenu)
    let statusFixAndSend = shortcutItem(.fixAndSend, in: statusMenu)
    XCTAssertEqual(statusQuickCheck?.keyEquivalent, "k")
    XCTAssertEqual(statusQuickCheck?.keyEquivalentModifierMask, [.command, .option])
    XCTAssertEqual(statusFixAndSend?.keyEquivalent, "j")
    XCTAssertEqual(statusFixAndSend?.keyEquivalentModifierMask, [.control, .shift])

    let mainMenu = AppDelegate.makeMainMenu(
      target: nil,
      quickCheckChord: quickCheckChord,
      fixAndSendChord: fixAndSendChord
    )
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

    XCTAssertEqual(shortcutItem(.quickCheck, in: mainMenu)?.keyEquivalent, "k")
    XCTAssertEqual(shortcutItem(.fixAndSend, in: mainMenu)?.keyEquivalent, "j")
  }

  func testShortcutEditingRejectsDuplicatesAndOSConflictsWithoutChangingPersistence() async {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    let persistedQuickCheck = KeyChord(
      keyCode: UInt32(kVK_ANSI_U),
      modifiers: UInt32(cmdKey | shiftKey)
    )
    await fixture.preferences.setQuickCheckKeyChord(persistedQuickCheck)

    let shortcutProbe = ShortcutUpdateProbe()
    let viewModel = fixture.makeViewModel { shortcut, chord in
      try shortcutProbe.update(shortcut, chord: chord)
    }
    await viewModel.load()

    XCTAssertEqual(viewModel.quickCheckKeyChord, persistedQuickCheck)
    XCTAssertEqual(viewModel.fixAndSendKeyChord, KeyChord.defaultFixAndSend)

    XCTAssertEqual(
      viewModel.updateKeyChord(KeyChord.defaultFixAndSend, for: BexShortcut.quickCheck),
      .rejected
    )
    XCTAssertTrue(shortcutProbe.attemptedUpdates.isEmpty)
    XCTAssertEqual(
      viewModel.shortcutError(for: BexShortcut.quickCheck),
      "That shortcut is already assigned to another Bex command."
    )
    XCTAssertEqual(viewModel.quickCheckKeyChord, persistedQuickCheck)
    let persistedAfterDuplicate = await fixture.preferences.quickCheckKeyChord()
    XCTAssertEqual(persistedAfterDuplicate, persistedQuickCheck)

    let osConflict = KeyChord(
      keyCode: UInt32(kVK_ANSI_I),
      modifiers: UInt32(cmdKey | optionKey)
    )
    shortcutProbe.failingChord = osConflict
    XCTAssertEqual(
      viewModel.updateKeyChord(osConflict, for: BexShortcut.quickCheck),
      .rejected
    )
    XCTAssertEqual(shortcutProbe.attemptedUpdates.map(\.1), [osConflict])
    XCTAssertEqual(
      viewModel.shortcutError(for: BexShortcut.quickCheck),
      "macOS or another app is already using that shortcut."
    )
    XCTAssertEqual(viewModel.quickCheckKeyChord, persistedQuickCheck)
    let persistedAfterConflict = await fixture.preferences.quickCheckKeyChord()
    XCTAssertEqual(persistedAfterConflict, persistedQuickCheck)

    let replacement = KeyChord(
      keyCode: UInt32(kVK_ANSI_L),
      modifiers: UInt32(controlKey | shiftKey)
    )
    shortcutProbe.failingChord = nil
    XCTAssertEqual(
      viewModel.updateKeyChord(replacement, for: BexShortcut.quickCheck),
      .accepted
    )
    await viewModel.waitForCurrentWork()
    XCTAssertEqual(viewModel.quickCheckKeyChord, replacement)
    XCTAssertNil(viewModel.shortcutError(for: BexShortcut.quickCheck))
    let persistedAfterSuccess = await fixture.preferences.quickCheckKeyChord()
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
    let historyDisclosure = SettingsViewModel.historyRetentionDisclosure
    XCTAssertTrue(draftDisclosure.contains("never block correction"))
    for requiredDetail in [
      "original", "correction", "explanation", "provider", "model", "Writing Style name",
      "timestamp", "at most 500 entries", "Fix & Send is not stored",
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

  func testSelectedProviderConnectionIsTaskFirstAndRoutesToItsOrigin() async throws {
    let fixture = SettingsFixture()
    defer { fixture.remove() }
    await fixture.preferences.setSelectedProvider(.claude)
    try await fixture.keychain.saveAPIKey("test-key", for: .claude)

    var routeIntents: [SettingsRouteIntent] = []
    let viewModel = fixture.makeViewModel(
      setupOrigin: .quickCheck,
      connectionSucceeds: true,
      onSetupRoute: { routeIntents.append($0) }
    )
    await viewModel.load()

    XCTAssertTrue(viewModel.isSelectedProviderConnected)
    XCTAssertEqual(viewModel.setupRouteTitle, "Return to Quick Check")
    XCTAssertNil(viewModel.modelFetchError)
    XCTAssertTrue(viewModel.hookStatuses.values.allSatisfy { $0 == .unavailable("Offline") })

    await viewModel.requestSetupRoute()
    XCTAssertEqual(routeIntents, [.returnToQuickCheck])

    var fixAndSendRoutes: [SettingsRouteIntent] = []
    let fixAndSendViewModel = fixture.makeViewModel(
      setupOrigin: .fixAndSend,
      connectionSucceeds: true,
      onSetupRoute: { fixAndSendRoutes.append($0) }
    )
    await fixAndSendViewModel.load()
    XCTAssertEqual(
      fixAndSendViewModel.setupRouteTitle,
      "Return to Target and Invoke Fix & Send"
    )
    await fixAndSendViewModel.requestSetupRoute()
    XCTAssertEqual(fixAndSendRoutes, [.returnToFixAndSendTarget])
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
      "Quick Check sends the full draft plus any custom Writing Style guidance.",
      "Rewrite sends the corrected draft.",
      "Fix & Send sends the masked prompt; the payload is shown for approval whenever confirmation is required.",
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

  func testStandardWindowsHaveDistinctAutosaveNamesAndContentMinimums() throws {
    let configurations = [
      WindowCoordinator.historyWindowConfiguration,
      WindowCoordinator.writingStylesWindowConfiguration,
      WindowCoordinator.settingsWindowConfiguration,
    ]

    XCTAssertEqual(
      Set(configurations.map(\.frameAutosaveName)),
      Set(["Bex.HistoryWindow", "Bex.WritingStylesWindow", "Bex.SettingsWindow"])
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

  @objc func openPromptGate() {
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
