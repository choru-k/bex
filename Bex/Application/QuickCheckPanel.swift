import AppKit
import SwiftUI

final class QuickCheckPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor
final class QuickCheckPanelController: NSWindowController, NSWindowDelegate {
  private let hostingController: NSHostingController<AnyView>
  private let closeAction: @MainActor () -> Void
  private let focusAction: @MainActor () -> Void
  private let copyAction: @MainActor () -> Void
  private let copyAndCloseAction: @MainActor () -> Void
  nonisolated(unsafe) private var keyMonitor: Any?
  private var isClosing = false

  init(
    rootView: AnyView,
    closeAction: @escaping @MainActor () -> Void,
    focusAction: @escaping @MainActor () -> Void,
    copyAction: @escaping @MainActor () -> Void,
    copyAndCloseAction: @escaping @MainActor () -> Void,
    autoDismissOnDeactivate: Bool = true
  ) {
    hostingController = NSHostingController(rootView: rootView)
    self.closeAction = closeAction
    self.focusAction = focusAction
    self.copyAction = copyAction
    self.copyAndCloseAction = copyAndCloseAction

    let panel = QuickCheckPanel(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Quick Check"
    panel.contentViewController = hostingController
    panel.setContentSize(NSSize(width: 560, height: 520))
    panel.minSize = NSSize(width: 460, height: 360)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = autoDismissOnDeactivate
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow

    super.init(window: panel)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      return self.handleShortcut(event) ? nil : event
    }
    panel.delegate = self
    if autoDismissOnDeactivate {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(applicationDidResignActive),
        name: NSApplication.didResignActiveNotification,
        object: nil
      )
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
  }

  func setRootView(_ rootView: AnyView) {
    hostingController.rootView = rootView
  }

  func show() {
    guard let panel = window as? QuickCheckPanel else { return }
    center(panel, on: activeScreen())
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let self, let panel else { return }
      self.focusInput(in: panel, remainingAttempts: 20)
    }
  }

  func closePanel() {
    guard !isClosing else { return }
    isClosing = true
    closeAction()
    window?.orderOut(nil)
    isClosing = false
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    closePanel()
    return false
  }

  @objc private func applicationDidResignActive() {
    guard window?.isVisible == true else { return }
    closePanel()
  }

  private func handleShortcut(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if modifiers.isEmpty, event.keyCode == 53 {
      closePanel()
      return true
    }
    guard modifiers == [.command, .shift] else { return false }
    if event.charactersIgnoringModifiers?.lowercased() == "c" {
      copyAction()
      return true
    }
    if event.keyCode == 36 || event.keyCode == 76 {
      copyAndCloseAction()
      return true
    }
    return false
  }

  private func focusInput(in panel: NSPanel, remainingAttempts: Int) {
    guard panel.isVisible else { return }
    if let contentView = panel.contentView,
      let textView = firstTextView(in: contentView),
      panel.makeFirstResponder(textView)
    {
      focusAction()
      return
    }
    guard remainingAttempts > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak panel] in
      guard let self, let panel else { return }
      self.focusInput(in: panel, remainingAttempts: remainingAttempts - 1)
    }
  }

  private func activeScreen() -> NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
  }

  private func center(_ panel: NSPanel, on screen: NSScreen?) {
    guard let screen else {
      panel.center()
      return
    }
    let visible = screen.visibleFrame
    let origin = NSPoint(
      x: visible.midX - panel.frame.width / 2,
      y: visible.midY - panel.frame.height / 2
    )
    panel.setFrameOrigin(origin)
  }

  private func firstTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView, textView.isEditable {
      return textView
    }
    for child in view.subviews {
      if let textView = firstTextView(in: child) {
        return textView
      }
    }
    return nil
  }
}
