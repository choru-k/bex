import AppKit
import Carbon.HIToolbox
import OSLog
import UserNotifications

@MainActor
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var services: AppServices?
  private var windowCoordinator: WindowCoordinator?
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var learningMenuItem: NSMenuItem?
  private var learningLogChangeTask: Task<Void, Never>?
  private var studyStateChangeTask: Task<Void, Never>?
  private var studyNotificationScheduler: StudyNotificationScheduler?
  /// Coarse recompute so the badge/notification don't go stale if the app is left
  /// running for days without any correction or Study answer to trigger a refresh —
  /// see `startMenuBarRefreshTimer()` for why hourly is the right grain.
  private var menuBarRefreshTimer: Timer?
  private var globalHotKey: GlobalHotKey?
  /// The outcome of the most recent `bex://answer` click, published in the next status
  /// file write so the bar can show "Correct" / "Wrong, it was X" alongside the new
  /// card. Lives here (not passed as a one-shot argument) because
  /// `.bexStudyStateDidChange` triggers its own `refreshMenuBarBadge()` call right
  /// after the answer handler's — that second call must still see this result rather
  /// than silently dropping it. Replaced by the next answer; otherwise persists.
  private var lastStudyResult: StudyStatusFile.LastResult?
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
    // Set early, before anything else touches windows: this is the delegate that
    // handles a tap on the daily Study reminder, and it must be in place before macOS
    // can hand us a notification response.
    UNUserNotificationCenter.current().delegate = self

    let coordinator = installCoordinator(services: services)
    installMainMenu()
    installStatusItem()
    startObservingMenuBarBadgeSources()
    startMenuBarRefreshTimer()
    Task { [weak self] in
      // Badge first (fast, no system UI) so the menu bar reflects reality immediately;
      // the one-time authorization prompt (which can sit unanswered indefinitely) must
      // never gate that.
      await self?.refreshMenuBarBadge()
      await self?.studyNotificationScheduler?.requestAuthorizationIfNeeded()
      // Last: this one makes a network call. Everything the user can see is already
      // correct without it, and it republishes the badge itself once it finishes.
      await self?.classifyStudyPatternsIfNeeded()
      await self?.refreshMenuBarBadge()
    }
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
    studyNotificationScheduler = StudyNotificationScheduler()
    coordinator.applyStoredAppearance()
    coordinator.onLearningViewed = { [weak self] in
      Task { [weak self] in
        await self?.refreshMenuBarBadge()
      }
    }
    return coordinator
  }

  func applicationWillTerminate(_ notification: Notification) {
    BexShortcutBridge.updater = nil
    globalHotKey?.unregisterAll()
    learningLogChangeTask?.cancel()
    studyStateChangeTask?.cancel()
    menuBarRefreshTimer?.invalidate()
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
    toolsMenu.addItem(command("Learning", "openLearning", target: target))
    toolsMenu.addItem(command("Study", "openStudy", target: target))
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
    learningMenuItem = menu.items.first {
      $0.identifier?.rawValue == "bex-learning-status-item"
    }
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
    let learningItem = command("Learning", "openLearning", target: target)
    learningItem.identifier = NSUserInterfaceItemIdentifier("bex-learning-status-item")
    menu.addItem(learningItem)
    menu.addItem(command("Study", "openStudy", target: target))
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

  @objc private func openLearning() {
    coordinator().showLearning()
  }

  @objc private func openStudy() {
    coordinator().showStudy()
  }

  /// Handles `bex://study`, `bex://learning`, and `bex://answer?index=N` — the URLs an
  /// external status bar opens from a click. A menu-bar app has no other way to be
  /// told "open this window" (or "here's an answer") from a shell script, and
  /// `open -a Bex` alone can only launch the app — it cannot say which window to show
  /// or carry a payload. Unrecognized hosts are ignored rather than treated as an
  /// error, so a future `bex://something` never crashes an old build.
  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls where url.scheme?.lowercased() == "bex" {
      switch url.host?.lowercased() {
      case "study":
        coordinator().showStudy()
      case "learning":
        coordinator().showLearning()
      case "answer":
        guard
          let indexString = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "index" })?.value,
          let index = Int(indexString)
        else { continue }
        Task { [weak self] in
          await self?.handleAnswer(index: index)
        }
      default:
        continue
      }
    }
  }

  /// Resolves the card the bar is CURRENTLY showing and records an answer against it.
  ///
  /// The index refers to a position in that card's `choices`, not the card itself —
  /// deliberately, the URL carries no card id. `StudyCard.id` is
  /// `"\(category)|\(wrong)|\(correct)"` (see `StudyCard.id`'s doc comment), and a
  /// `|`-containing id would need percent-encoding through a shell script's URL
  /// construction to round-trip safely; recomputing "what's next" server-side sidesteps
  /// that entirely, at the cost of redoing the plan computation once per click, which is
  /// cheap next to a human clicking a menu bar.
  private func handleAnswer(index: Int) async {
    guard let services else { return }
    let now = Date()
    let (cards, plan, _) = await studyCardsAndPlan(services: services, now: now)
    guard
      let cardID = plan.cardIDs.first,
      let card = cards.first(where: { $0.id == cardID }),
      card.choices.indices.contains(index)
    else { return }
    let wasCorrect = card.choices[index] == card.correct
    await services.studyState.record(cardID: card.id, correct: wasCorrect, now: now)
    // `.bexStudyStateDidChange` (posted by `record` above) will also trigger a
    // `refreshMenuBarBadge()` via `startObservingMenuBarBadgeSources()` — storing the
    // result on `self` rather than passing it through means that second, redundant
    // refresh still republishes it instead of overwriting it with `nil`.
    lastStudyResult = StudyStatusFile.LastResult(
      wasCorrect: wasCorrect, correctAnswer: card.correct, reason: card.reason)
    await refreshMenuBarBadge()
  }

  /// Observes both `.bexLearningLogDidChange` (posted by `LearningLogStore.append`) and
  /// `.bexStudyStateDidChange` (posted by `StudyStateStore.record`/`reset`) for the
  /// lifetime of the app and recomputes the combined badge whenever either source
  /// changes. Mirrors `HistoryViewModel.startObservingIfNeeded`'s `for await` pattern;
  /// `AppDelegate` is `@MainActor`, so each loop body runs on the main actor.
  private func startObservingMenuBarBadgeSources() {
    learningLogChangeTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .bexLearningLogDidChange) {
        guard !Task.isCancelled, let self else { return }
        await self.refreshMenuBarBadge()
      }
    }
    studyStateChangeTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .bexStudyStateDidChange) {
        guard !Task.isCancelled, let self else { return }
        await self.refreshMenuBarBadge()
      }
    }
  }

  /// Coarse periodic recompute so the badge/notification don't go stale purely from the
  /// passage of time — e.g. a card silently becoming due, or a day rolling over — while
  /// the app sits open for days with no correction or Study answer to trigger the
  /// notification-based refresh above.
  //
  // ponytail: a plain repeating `Timer`, not a scheduler that wakes exactly at local
  // midnight or exactly when the next card becomes due. Study's due-ness is computed
  // in whole days (`StudyScheduler.intervalDays`), so "check roughly once an hour" is
  // already far finer-grained than the thing it's checking; a precise wake-at-midnight
  // scheduler would add real complexity for zero user-visible improvement. Ceiling: if
  // Study ever needs sub-day due granularity, replace this with a `Calendar`-driven
  // one-shot timer that reschedules itself for the next relevant boundary.
  private func startMenuBarRefreshTimer() {
    menuBarRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        await self?.classifyStudyPatternsIfNeeded()
        await self?.refreshMenuBarBadge()
      }
    }
  }

  /// Reloads the learning log and Study review state, recomputes both
  /// `LearningBadge.status` and today's `StudyDailyPlan`, applies whichever wins the
  /// single menu-bar badge slot (`StudyDueCount.badge`), and reschedules the daily
  /// reminder notification to match. Safe to call anytime after `installStatusItem`; a
  /// nil `services` (shouldn't happen post-launch) is a no-op.
  ///
  /// The plan is computed exactly once and its `cardIDs.count`/`maxOverdueDays` feed
  /// every downstream consumer (badge, notification, status file) — computing it twice
  /// would risk two calls straddling a moment where "now" ticks into a new day and
  /// disagreeing about today's new-card intake.
  private func refreshMenuBarBadge() async {
    guard let services else { return }
    let now = Date()
    let (cards, plan, samples) = await studyCardsAndPlan(services: services, now: now)

    let lastViewedAt = await services.preferences.lastLearningViewedAt()
    let learningStatus = LearningBadge.status(samples: samples, lastViewedAt: lastViewedAt)

    let studyDue = plan.cardIDs.count
    let severity = StudyDueCount.severity(maxOverdueDays: plan.maxOverdueDays)

    applyMenuBarBadge(StudyDueCount.badge(studyDue: studyDue, learning: learningStatus))
    learningMenuItem?.title = learningStatus.count > 0 ? "Learning (\(learningStatus.count))" : "Learning"
    await studyNotificationScheduler?.reschedule(dueCount: studyDue)

    let nextCard = plan.cardIDs.first
      .flatMap { cardID in cards.first(where: { $0.id == cardID }) }
      .map { card in
        StudyStatusFile.NextCard(id: card.id, prompt: card.promptWithBlank, choices: card.choices)
      }
    // Republish for external status bars (SketchyBar), which is where this count is
    // actually visible — see `StudyStatusFile`. `lastStudyResult` is read (not
    // consumed) here so the second, notification-triggered refresh right after an
    // answer still republishes the same result instead of losing it.
    StudyStatusFile.write(
      dueCount: studyDue, severity: severity, nextCard: nextCard, lastResult: lastStudyResult,
      now: now)
  }

  /// Builds today's `[StudyCard]` and `StudyDailyPlan.Plan` from the learning log and
  /// Study review state — the one place this computation happens, so
  /// `refreshMenuBarBadge()` and the `bex://answer` handler can never disagree about
  /// which card is "next". Also returns the parsed `[LearningSample]`s, since
  /// `refreshMenuBarBadge` needs them again for `LearningBadge.status` and re-reading
  /// the log a second time would risk that second read straddling a day boundary the
  /// first one didn't.
  private func studyCardsAndPlan(services: AppServices, now: Date) async -> (
    cards: [StudyCard], plan: StudyDailyPlan.Plan, samples: [LearningSample]
  ) {
    let entries = await services.learningLog.readAll()
    let samples = LearningLogSamples.parse(entries)
    let cards = StudyCardBuilder.cards(from: samples)
    let states = await services.studyState.states()
    let verdicts = await services.studyPatterns.verdicts()
    let plan = StudyDailyPlan.plan(
      cards: cards, states: states, now: now, verdicts: verdicts)
    return (cards, plan, samples)
  }

  /// Labels any newly-built cards with the English rule they exemplify, so
  /// `StudyDailyPlan` can spread one batch across ten different lessons instead of six
  /// examples of two.
  ///
  /// Runs off the interactive path, on purpose. A Quick Check has to answer in about two
  /// seconds, so this is never folded into the correction prompt; it happens afterwards on
  /// launch and hourly, where a slow call costs nothing. Only cards never classified
  /// before are sent, so the steady-state cost is zero calls.
  ///
  /// Gated on the outbound disclosure the user has already accepted for their current
  /// destination. The learning log is owner-only by design, and this would ship 139 of
  /// their own mistakes to a provider — so if they have not already agreed to send text to
  /// that destination, this silently does nothing rather than asking in the background.
  /// Grouping then falls back to `GrammarCategory` tags, which is worse but never
  /// surprising.
  //
  // ponytail: failures are swallowed and simply retried on the next hourly tick. No
  // backoff, no retry counter, no error surfaced — grouping quality degrades to the tag
  // fallback, which is exactly where it started. Ceiling: if a persistently failing
  // provider ever needs to be visible, surface it in the Study window rather than here.
  private func classifyStudyPatternsIfNeeded() async {
    guard let services else { return }
    guard let destination = try? await services.preferences.outboundDestination(),
      await services.preferences.hasAcceptedCurrentOutboundDisclosure(for: destination)
    else { return }

    let entries = await services.learningLog.readAll()
    let cards = StudyCardBuilder.cards(from: LearningLogSamples.parse(entries))
    let pendingIDs = Set(await services.studyPatterns.unclassifiedIDs(among: cards))
    guard !pendingIDs.isEmpty else { return }

    let pending = cards.filter { pendingIDs.contains($0.id) }
    guard
      let assignments = try? await services.grammar.classifyStudyPatterns(
        cards: pending, destination: destination)
    else { return }
    await services.studyPatterns.assign(assignments)
  }

  private func applyMenuBarBadge(_ badge: StudyDueCount.MenuBarBadge) {
    if badge.isVisible {
      statusItem?.button?.title = badge.text
      statusItem?.button?.imagePosition = .imageLeft
    } else {
      statusItem?.button?.title = ""
      statusItem?.button?.imagePosition = .imageOnly
    }
    statusItem?.button?.setAccessibilityLabel(badge.accessibilityLabel)
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

/// Handles a tap on the daily Study reminder notification. `UNUserNotificationCenter`
/// invokes delegate methods off the main actor, so these are `nonisolated` and hop back
/// via `Task { @MainActor in ... }` for the one thing that needs it — opening the Study
/// window through the existing coordinator, exactly like the "Study" menu command does.
extension AppDelegate: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    guard
      response.notification.request.content.categoryIdentifier
        == StudyNotificationPlan.categoryIdentifier
    else { return }
    Task { @MainActor [weak self] in
      self?.coordinator().showStudy()
    }
  }

  /// Without this, macOS suppresses the reminder's banner whenever Bex is the active
  /// app (e.g. the Study or Settings window has focus) — exactly the moments a
  /// menu-bar app is most likely to be "foreground". Explicitly opting into
  /// `.banner`/`.sound` keeps the reminder visible regardless of what's focused.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }
}
