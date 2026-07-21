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
        let openQuickCheck =
          arguments.contains("--open-quick-check")
          || environment["BEX_UI_TEST_OPEN_QUICK_CHECK"] == "1"
        let openPromptGate =
          arguments.contains("--open-prompt-gate")
          || environment["BEX_UI_TEST_OPEN_PROMPT_GATE"] == "1"
        Task { [weak self] in
          let services = await AppServices.uiTesting(
            seedCredential: !missingCredential
          )
          self?.finishLaunching(
            with: services,
            openQuickCheck: openQuickCheck,
            openPromptGate: openPromptGate
          )
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
    openPromptGate: Bool = false
  ) {
    let coordinator = installCoordinator(services: services)
    installMainMenu()
    installStatusItem()
    #if DEBUG
      installUITestingCommands()
    #endif

    let globalHotKey = GlobalHotKey()
    self.globalHotKey = globalHotKey
    do {
      try globalHotKey.register(
        Shortcut(id: 1, keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey))
      ) { [weak self] in
        self?.openQuickCheck()
      }
    } catch {
      showHotKeyConflict(
        "⌘⇧G is already in use. Open Quick Check from the Bex menu."
      )
    }
    do {
      try globalHotKey.register(
        Shortcut(id: 2, keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey))
      ) { [weak self] in
        self?.openPromptGate()
      }
    } catch {
      showHotKeyConflict(
        "⌘⇧P is already in use. The Fix & Send shortcut is unavailable."
      )
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
      await MainActor.run {
        if openQuickCheck {
          coordinator?.showQuickCheck()
        }
        if openPromptGate {
          coordinator?.showPromptGate()
        }
        self?.announceTrayReady()
      }
    }
  }

  private func coordinator() -> WindowCoordinator {
    installMainMenu()
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
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "Bex")
    appMenu.addItem(
      withTitle: "Quit Bex",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)

    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(
      withTitle: "Undo",
      action: NSSelectorFromString("undo:"),
      keyEquivalent: "z"
    )
    let redo = editMenu.addItem(
      withTitle: "Redo",
      action: NSSelectorFromString("redo:"),
      keyEquivalent: "Z"
    )
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(
      withTitle: "Cut",
      action: #selector(NSText.cut(_:)),
      keyEquivalent: "x"
    )
    editMenu.addItem(
      withTitle: "Copy",
      action: #selector(NSText.copy(_:)),
      keyEquivalent: "c"
    )
    editMenu.addItem(
      withTitle: "Paste",
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    editMenu.addItem(.separator())
    editMenu.addItem(
      withTitle: "Select All",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    editItem.submenu = editMenu
    mainMenu.addItem(editItem)

    NSApp.mainMenu = mainMenu
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

    let menu = NSMenu()
    let quickCheck = NSMenuItem(
      title: "Quick Check",
      action: #selector(openQuickCheck),
      keyEquivalent: "g"
    )
    quickCheck.keyEquivalentModifierMask = [.command, .shift]
    quickCheck.target = self
    menu.addItem(quickCheck)
    menu.addItem(menuItem(title: "History", action: #selector(openHistory)))
    menu.addItem(menuItem(title: "Profiles", action: #selector(openProfiles)))
    menu.addItem(menuItem(title: "Settings", action: #selector(openSettings)))
    menu.addItem(.separator())
    menu.addItem(menuItem(title: "Quit Bex", action: #selector(quit), keyEquivalent: "q"))

    item.menu = menu
    statusItem = item
    statusMenu = menu
  }

  private func menuItem(
    title: String,
    action: Selector,
    keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    return item
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
    }

    @objc private func openQuickCheckForUITesting(_ notification: Notification) {
      openQuickCheck()
    }

    @objc private func openPromptGateForUITesting(_ notification: Notification) {
      openPromptGate()
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

  @objc private func openSettings() {
    coordinator().showSettings()
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}
