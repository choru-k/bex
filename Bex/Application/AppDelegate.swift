import AppKit
import Carbon.HIToolbox
import OSLog

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var services: AppServices?
  private var windowCoordinator: WindowCoordinator?
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var globalHotKey: GlobalHotKey?
  private var shortcutMenuItems: [BexShortcut: [NSMenuItem]] = [:]
  private var shortcutChords: [BexShortcut: KeyChord] = [
    .quickCheck: .defaultQuickCheck,
    .fixAndSend: .defaultFixAndSend,
  ]
  private let signposter: OSSignposter
  private var launchInterval: OSSignpostIntervalState?

  override init() {
    let signposter = OSSignposter(subsystem: "com.bex.desktop", category: "ui")
    self.signposter = signposter
    launchInterval = signposter.beginInterval("ApplicationLaunch")
    super.init()
  }

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      app.run()
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    #if DEBUG
      let processInfo = ProcessInfo.processInfo
      let arguments = processInfo.arguments
      let environment = processInfo.environment
      if arguments.contains("--ui-testing") || environment["BEX_UI_TESTING"] == "1" {
        let missingCredential =
          arguments.contains("--missing-credential")
          || environment["BEX_UI_TEST_MISSING_CREDENTIAL"] == "1"
        let explicitQuickCheck =
          arguments.contains("--open-quick-check")
          || environment["BEX_UI_TEST_OPEN_QUICK_CHECK"] == "1"
        let explicitPromptGate =
          arguments.contains("--open-prompt-gate")
          || environment["BEX_UI_TEST_OPEN_PROMPT_GATE"] == "1"
        let launchDestination: UITestLaunchDestination
        if explicitPromptGate {
          launchDestination = .promptGate
        } else if explicitQuickCheck {
          launchDestination = .quickCheck
        } else {
          launchDestination = UITestScenario.current.configuration.launchDestination
        }
        Task { [weak self] in
          let services = await AppServices.uiTesting(
            seedCredential: !missingCredential
          )
          self?.finishLaunching(
            with: services,
            openQuickCheck: launchDestination == .quickCheck,
            openPromptGate: launchDestination == .promptGate,
            showWelcomeIfNeeded: UITestScenario.current == .welcome
          )
          switch launchDestination {
          case .settings:
            self?.windowCoordinator?.showSettings()
          case let .setup(origin):
            self?.windowCoordinator?.showSettings(origin: origin)
          case .history:
            self?.windowCoordinator?.showHistory()
          case .profiles:
            self?.windowCoordinator?.showProfiles()
          case .none, .quickCheck, .promptGate, .hookPromptGate:
            break
          }
        }
        return
      }
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return
      }
    #endif

    WindowCoordinator.applyAppearance(PreferencesStore.standardAppearance())
    finishLaunching(with: AppServices.production())
  }

  private func finishLaunching(
    with services: AppServices,
    openQuickCheck: Bool = false,
    openPromptGate: Bool = false,
    showWelcomeIfNeeded: Bool = true
  ) {
    let coordinator = installCoordinator(services: services)
    installMainMenu()
    installStatusItem()
    #if DEBUG
      installUITestingCommands()
    #endif

    let globalHotKey: GlobalHotKey
    #if DEBUG
      if ProcessInfo.processInfo.environment["BEX_UI_TESTING"] == "1" {
        let behavior = UITestScenario.current.configuration.hotKeyRegistration
        globalHotKey = GlobalHotKey(
          backend: UITestingHotKeyRegistrationBackend(behavior: behavior)
        )
      } else {
        globalHotKey = GlobalHotKey()
      }
    #else
      globalHotKey = GlobalHotKey()
    #endif
    self.globalHotKey = globalHotKey
    Task { [weak self] in
      async let quickCheckChord = services.preferences.quickCheckKeyChord()
      async let fixAndSendChord = services.preferences.fixAndSendKeyChord()
      let chords: [BexShortcut: KeyChord] = [
        .quickCheck: await quickCheckChord,
        .fixAndSend: await fixAndSendChord,
      ]
      await MainActor.run {
        guard let self else { return }
        self.shortcutChords = chords
        self.refreshShortcutMenuItems()
        for shortcut in BexShortcut.allCases {
          let chord = chords[shortcut] ?? shortcut.defaultChord
          do {
            try globalHotKey.register(
              Shortcut(id: shortcut.rawValue, chord: chord),
              action: self.shortcutAction(for: shortcut)
            )
          } catch {
            self.showHotKeyConflict(
              "\(shortcut.title) shortcut could not be registered: \(error.localizedDescription) "
                + "The command remains available from the Bex menu."
            )
          }
        }
        BexShortcutBridge.updater = { [weak self] shortcut, chord in
          guard let self else { throw HotKeyRegistrationError.updaterUnavailable }
          try self.replaceShortcut(shortcut, with: chord)
        }
      }
    }

    Task { [weak self, weak coordinator] in
      await services.promptGateIPC.setHandlers(
        onRequest: { [weak coordinator] request in
          await MainActor.run {
            coordinator?.showPromptGate(hookRequest: request) ?? false
          }
        },
        onInvalidation: { [weak coordinator] requestID in
          await MainActor.run {
            coordinator?.invalidatePromptGate(requestID: requestID)
          }
        }
      )
      try? await services.promptGateIPC.start()
      if let hookManager = services.hookManager as? HookInstallationManager {
        try? await hookManager.refreshInstalledHelper()
      }
      let completedWelcomeVersion =
        await services.preferences.welcomeCompletedVersion()
      let shouldShowWelcome =
        showWelcomeIfNeeded && !openQuickCheck && !openPromptGate
          && completedWelcomeVersion < WindowCoordinator.currentWelcomeVersion
      await MainActor.run {
        if openQuickCheck {
          coordinator?.showQuickCheck()
        }
        if openPromptGate {
          coordinator?.showPromptGate()
        }
        if shouldShowWelcome {
          coordinator?.showWelcome()
        }
        self?.announceTrayReady()
      }
    }
  }

  private func coordinator() -> WindowCoordinator {
    guard let windowCoordinator else {
      preconditionFailure("Bex services must be composed before opening a window.")
    }
    return windowCoordinator
  }

  @discardableResult
  private func installCoordinator(services: AppServices) -> WindowCoordinator {
    let coordinator = WindowCoordinator(services: services)
    self.services = services
    windowCoordinator = coordinator
    coordinator.applyStoredAppearance()
    return coordinator
  }

  func applicationWillTerminate(_ notification: Notification) {
    BexShortcutBridge.updater = nil
    globalHotKey?.unregisterAll()
    #if DEBUG
      DistributedNotificationCenter.default().removeObserver(self)
    #endif
    if let promptGateIPC = services?.promptGateIPC {
      Task { await promptGateIPC.stop() }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  private func installMainMenu() {
    guard NSApp.mainMenu == nil else { return }
    let mainMenu = Self.makeMainMenu(
      target: self,
      quickCheckChord: shortcutChords[.quickCheck] ?? .defaultQuickCheck,
      fixAndSendChord: shortcutChords[.fixAndSend] ?? .defaultFixAndSend
    )
    NSApp.mainMenu = mainMenu
    NSApp.servicesMenu = mainMenu.item(withTitle: "Bex")?.submenu?
      .item(withTitle: "Services")?.submenu
    NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
    NSApp.helpMenu = mainMenu.item(withTitle: "Help")?.submenu
    trackShortcutItems(in: mainMenu)
  }

  static func makeMainMenu(
    target: AnyObject?,
    quickCheckChord: KeyChord,
    fixAndSendChord: KeyChord
  ) -> NSMenu {
    let mainMenu = NSMenu()

    let appMenu = NSMenu(title: "Bex")
    appMenu.addItem(command("About Bex", "orderFrontStandardAboutPanel:"))
    appMenu.addItem(.separator())
    appMenu.addItem(command("Settings…", "openSettings", ",", target: target))
    appMenu.addItem(.separator())
    let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    servicesItem.submenu = NSMenu(title: "Services")
    appMenu.addItem(servicesItem)
    appMenu.addItem(.separator())
    appMenu.addItem(command("Hide Bex", "hide:", "h"))
    let hideOthers = command("Hide Others", "hideOtherApplications:", "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthers)
    appMenu.addItem(command("Show All", "unhideAllApplications:"))
    appMenu.addItem(.separator())
    appMenu.addItem(command("Quit Bex", "terminate:", "q"))
    mainMenu.addItem(rootItem(title: "Bex", submenu: appMenu))

    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(command("Undo", "undo:", "z"))
    let redo = command("Redo", "redo:", "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redo)
    editMenu.addItem(.separator())
    editMenu.addItem(command("Cut", "cut:", "x"))
    editMenu.addItem(command("Copy", "copy:", "c"))
    editMenu.addItem(command("Paste", "paste:", "v"))
    let pasteAndMatch = command("Paste and Match Style", "pasteAsPlainText:", "v")
    pasteAndMatch.keyEquivalentModifierMask = [.command, .option, .shift]
    editMenu.addItem(pasteAndMatch)
    editMenu.addItem(command("Delete", "delete:"))
    editMenu.addItem(command("Select All", "selectAll:", "a"))
    editMenu.addItem(.separator())

    let findMenu = NSMenu(title: "Find")
    findMenu.addItem(command("Find…", "performFindPanelAction:", "f"))
    findMenu.items.last?.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
    findMenu.addItem(command("Find Next", "performFindPanelAction:", "g"))
    findMenu.items.last?.tag = Int(NSFindPanelAction.next.rawValue)
    let findPrevious = command("Find Previous", "performFindPanelAction:", "g")
    findPrevious.keyEquivalentModifierMask = [.command, .shift]
    findPrevious.tag = Int(NSFindPanelAction.previous.rawValue)
    findMenu.addItem(findPrevious)
    findMenu.addItem(command("Use Selection for Find", "performFindPanelAction:", "e"))
    findMenu.items.last?.tag = Int(NSFindPanelAction.setFindString.rawValue)
    findMenu.addItem(command("Jump to Selection", "centerSelectionInVisibleArea:", "j"))
    editMenu.addItem(rootItem(title: "Find", submenu: findMenu))

    let spellingMenu = NSMenu(title: "Spelling and Grammar")
    spellingMenu.addItem(command("Show Spelling and Grammar", "showGuessPanel:", ":"))
    spellingMenu.addItem(command("Check Document Now", "checkSpelling:", ";"))
    spellingMenu.addItem(.separator())
    spellingMenu.addItem(command("Check Spelling While Typing", "toggleContinuousSpellChecking:"))
    spellingMenu.addItem(command("Check Grammar With Spelling", "toggleGrammarChecking:"))
    spellingMenu.addItem(command("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:"))
    editMenu.addItem(rootItem(title: "Spelling and Grammar", submenu: spellingMenu))

    let substitutionsMenu = NSMenu(title: "Substitutions")
    substitutionsMenu.addItem(command("Show Substitutions", "orderFrontSubstitutionsPanel:"))
    substitutionsMenu.addItem(.separator())
    substitutionsMenu.addItem(command("Smart Copy/Paste", "toggleSmartInsertDelete:"))
    substitutionsMenu.addItem(command("Smart Quotes", "toggleAutomaticQuoteSubstitution:"))
    substitutionsMenu.addItem(command("Smart Dashes", "toggleAutomaticDashSubstitution:"))
    substitutionsMenu.addItem(command("Smart Links", "toggleAutomaticLinkDetection:"))
    substitutionsMenu.addItem(command("Data Detectors", "toggleAutomaticDataDetection:"))
    substitutionsMenu.addItem(command("Text Replacement", "toggleAutomaticTextReplacement:"))
    editMenu.addItem(rootItem(title: "Substitutions", submenu: substitutionsMenu))

    let transformationsMenu = NSMenu(title: "Transformations")
    transformationsMenu.addItem(command("Make Upper Case", "uppercaseWord:"))
    transformationsMenu.addItem(command("Make Lower Case", "lowercaseWord:"))
    transformationsMenu.addItem(command("Capitalize", "capitalizeWord:"))
    editMenu.addItem(rootItem(title: "Transformations", submenu: transformationsMenu))

    let speechMenu = NSMenu(title: "Speech")
    speechMenu.addItem(command("Start Speaking", "startSpeaking:"))
    speechMenu.addItem(command("Stop Speaking", "stopSpeaking:"))
    editMenu.addItem(rootItem(title: "Speech", submenu: speechMenu))
    mainMenu.addItem(rootItem(title: "Edit", submenu: editMenu))

    let toolsMenu = NSMenu(title: "Tools")
    toolsMenu.addItem(
      shortcutCommand(
        "Quick Check",
        "openQuickCheck",
        shortcut: .quickCheck,
        chord: quickCheckChord,
        target: target
      )
    )
    toolsMenu.addItem(
      shortcutCommand(
        "Fix & Send…",
        "openPromptGate",
        shortcut: .fixAndSend,
        chord: fixAndSendChord,
        target: target
      )
    )
    toolsMenu.addItem(.separator())
    toolsMenu.addItem(command("History", "openHistory", target: target))
    toolsMenu.addItem(command("Writing Styles", "openProfiles", target: target))
    mainMenu.addItem(rootItem(title: "Tools", submenu: toolsMenu))

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(command("Close", "performClose:", "w"))
    windowMenu.addItem(command("Minimize", "performMiniaturize:", "m"))
    windowMenu.addItem(command("Zoom", "performZoom:"))
    windowMenu.addItem(.separator())
    windowMenu.addItem(command("Bring All to Front", "arrangeInFront:"))
    mainMenu.addItem(rootItem(title: "Window", submenu: windowMenu))

    let helpMenu = NSMenu(title: "Help")
    helpMenu.addItem(command("Welcome to Bex", "openWelcome", target: target))
    mainMenu.addItem(rootItem(title: "Help", submenu: helpMenu))
    return mainMenu
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    if let button = item.button {
      if let url = Bundle.main.url(
        forResource: "tray-template",
        withExtension: "png"
      ), let image = NSImage(contentsOf: url) {
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        button.image = image
      } else {
        button.image = NSImage(
          systemSymbolName: "text.badge.checkmark",
          accessibilityDescription: "Bex"
        )
      }
      button.toolTip = "Bex"
      button.identifier = NSUserInterfaceItemIdentifier("bex-status-item")
      button.setAccessibilityLabel("Bex")
    }

    let menu = Self.makeStatusMenu(
      target: self,
      quickCheckChord: shortcutChords[.quickCheck] ?? .defaultQuickCheck,
      fixAndSendChord: shortcutChords[.fixAndSend] ?? .defaultFixAndSend
    )
    item.menu = menu
    statusItem = item
    statusMenu = menu
    trackShortcutItems(in: menu)
  }

  static func makeStatusMenu(
    target: AnyObject?,
    quickCheckChord: KeyChord,
    fixAndSendChord: KeyChord
  ) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(
      shortcutCommand(
        "Quick Check",
        "openQuickCheck",
        shortcut: .quickCheck,
        chord: quickCheckChord,
        target: target
      )
    )
    menu.addItem(
      shortcutCommand(
        "Fix & Send…",
        "openPromptGate",
        shortcut: .fixAndSend,
        chord: fixAndSendChord,
        target: target
      )
    )
    menu.addItem(command("History", "openHistory", target: target))
    menu.addItem(command("Writing Styles", "openProfiles", target: target))
    menu.addItem(command("Settings…", "openSettings", target: target))
    menu.addItem(.separator())
    menu.addItem(command("Welcome to Bex", "openWelcome", target: target))
    menu.addItem(command("About Bex", "orderFrontStandardAboutPanel:"))
    menu.addItem(.separator())
    menu.addItem(command("Quit Bex", "quit", "q", target: target))
    return menu
  }

  private static func command(
    _ title: String,
    _ actionName: String,
    _ keyEquivalent: String = "",
    target: AnyObject? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: NSSelectorFromString(actionName),
      keyEquivalent: keyEquivalent
    )
    item.target = target
    return item
  }

  private static func shortcutCommand(
    _ title: String,
    _ actionName: String,
    shortcut: BexShortcut,
    chord: KeyChord,
    target: AnyObject?
  ) -> NSMenuItem {
    let item = command(title, actionName, chord.keyEquivalent, target: target)
    item.keyEquivalentModifierMask = chord.modifierMask
    item.identifier = NSUserInterfaceItemIdentifier("bex-shortcut-\(shortcut.rawValue)")
    return item
  }

  private static func rootItem(title: String, submenu: NSMenu) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    return item
  }

  private func trackShortcutItems(in menu: NSMenu) {
    for item in menu.items {
      if let identifier = item.identifier?.rawValue,
        identifier.hasPrefix("bex-shortcut-"),
        let rawValue = UInt32(identifier.dropFirst("bex-shortcut-".count)),
        let shortcut = BexShortcut(rawValue: rawValue)
      {
        shortcutMenuItems[shortcut, default: []].append(item)
      }
      if let submenu = item.submenu {
        trackShortcutItems(in: submenu)
      }
    }
  }

  private func refreshShortcutMenuItems() {
    for (shortcut, items) in shortcutMenuItems {
      let chord = shortcutChords[shortcut] ?? shortcut.defaultChord
      for item in items {
        item.keyEquivalent = chord.keyEquivalent
        item.keyEquivalentModifierMask = chord.modifierMask
      }
    }
  }

  private func replaceShortcut(_ shortcut: BexShortcut, with chord: KeyChord) throws {
    guard let globalHotKey else {
      throw HotKeyRegistrationError.updaterUnavailable
    }
    try globalHotKey.replace(
      Shortcut(id: shortcut.rawValue, chord: chord),
      action: shortcutAction(for: shortcut)
    )
    shortcutChords[shortcut] = chord
    refreshShortcutMenuItems()
  }

  private func shortcutAction(for shortcut: BexShortcut) -> @MainActor () -> Void {
    { [weak self] in
      switch shortcut {
      case .quickCheck:
        self?.openQuickCheck()
      case .fixAndSend:
        self?.openPromptGate()
      }
    }
  }

  private func showHotKeyConflict(_ title: String) {
    guard let statusMenu else { return }
    let message = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    message.isEnabled = false
    statusMenu.insertItem(message, at: 0)
    statusMenu.insertItem(.separator(), at: 1)
  }

  #if DEBUG
    private func installUITestingCommands() {
      guard ProcessInfo.processInfo.environment["BEX_UI_TESTING"] == "1" else { return }
      let center = DistributedNotificationCenter.default()
      center.addObserver(
        self,
        selector: #selector(openQuickCheckForUITesting(_:)),
        name: Notification.Name("com.bex.desktop.ui-testing.open-quick-check"),
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(openPromptGateForUITesting(_:)),
        name: Notification.Name("com.bex.desktop.ui-testing.open-prompt-gate"),
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(releaseGrammarForUITesting(_:)),
        name: Notification.Name("com.bex.desktop.ui-testing.release-grammar"),
        object: nil
      )
      center.addObserver(
        self,
        selector: #selector(releaseDeliveryForUITesting(_:)),
        name: Notification.Name("com.bex.desktop.ui-testing.release-delivery"),
        object: nil
      )
    }

    @objc private func openQuickCheckForUITesting(_ notification: Notification) {
      openQuickCheck()
    }

    @objc private func openPromptGateForUITesting(_ notification: Notification) {
      openPromptGate()
    }
    @objc private func releaseGrammarForUITesting(_ notification: Notification) {
      guard let grammar = services?.grammar as? UITestingGrammarService else { return }
      Task { await grammar.releaseCheck() }
    }

    @objc private func releaseDeliveryForUITesting(_ notification: Notification) {
      guard let target = services?.promptTarget as? UITestingPromptTargetService else { return }
      Task { await target.releaseDelivery() }
    }

  #endif

  private func announceTrayReady() {
    signposter.emitEvent("TrayReady")
    if let launchInterval {
      signposter.endInterval("ApplicationLaunch", launchInterval)
      self.launchInterval = nil
    }
  }

  @objc private func openQuickCheck() {
    let interval = WindowCoordinator.beginQuickCheckOpenInterval()
    coordinator().showQuickCheck(signpostInterval: interval)
  }

  @objc private func openPromptGate() {
    coordinator().showPromptGate()
  }

  @objc private func openHistory() {
    coordinator().showHistory()
  }

  @objc private func openProfiles() {
    coordinator().showProfiles()
  }

  @objc private func openWelcome() {
    coordinator().showWelcome()
  }

  @objc private func openSettings() {
    coordinator().showSettings()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
