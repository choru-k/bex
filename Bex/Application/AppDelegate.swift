import AppKit
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
        Task { [weak self] in
          let services = await AppServices.uiTesting(
            seedCredential: !missingCredential
          )
          self?.finishLaunching(with: services, openQuickCheck: openQuickCheck)
        }
        return
      }
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        return
      }
    #endif

    WindowCoordinator.applyAppearance(PreferencesStore.standardAppearance())
    finishLaunching()
  }

  private func finishLaunching(with services: AppServices? = nil, openQuickCheck: Bool = false) {
    if let services {
      installCoordinator(services: services)
    }
    if services != nil {
      installMainMenu()
    }
    installStatusItem()
    let globalHotKey = GlobalHotKey { [weak self] in
      self?.openQuickCheck()
    }
    self.globalHotKey = globalHotKey
    do {
      try globalHotKey.register()
    } catch {
      showHotKeyConflict()
    }
    if openQuickCheck {
      windowCoordinator?.showQuickCheck()
    }
    signposter.emitEvent("TrayReady")
    if let launchInterval {
      signposter.endInterval("ApplicationLaunch", launchInterval)
      self.launchInterval = nil
    }
  }

  private func coordinator() -> WindowCoordinator {
    installMainMenu()
    if let windowCoordinator {
      return windowCoordinator
    }
    return installCoordinator(services: AppServices.production())
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
    globalHotKey?.unregister()
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

  private func showHotKeyConflict() {
    guard let statusMenu else { return }
    let message = NSMenuItem(
      title: "⌘⇧G is already in use. Open Quick Check from the Bex menu.",
      action: nil,
      keyEquivalent: ""
    )
    message.isEnabled = false
    statusMenu.insertItem(message, at: 0)
    statusMenu.insertItem(.separator(), at: 1)
  }

  @objc private func openQuickCheck() {
    let interval = WindowCoordinator.beginQuickCheckOpenInterval()
    coordinator().showQuickCheck(signpostInterval: interval)
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
