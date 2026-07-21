import AppKit
import SwiftUI

final class QuickCheckPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

enum QuickCheckPanelCommand: Equatable, Sendable {
  case cancel
  case primaryAction
  case back
  case copy
}

@MainActor
final class QuickCheckPanelController: NSWindowController, NSWindowDelegate {
  static let frameAutosaveName = "Bex.QuickCheckPanel"
  private let hostingController: NSHostingController<AnyView>
  private let dismissalAction: @MainActor (QuickCheckDismissalReason) -> Void
  private let showAction: @MainActor () -> Void
  private let focusAction: @MainActor () -> Void
  private let primaryAction: @MainActor () -> Void
  private let backAction: @MainActor () -> Void
  private let copyAction: @MainActor () -> Void
  nonisolated(unsafe) private var keyMonitor: Any?
  private var isClosing = false

  init(
    rootView: AnyView,
    dismissalAction: @escaping @MainActor (QuickCheckDismissalReason) -> Void,
    showAction: @escaping @MainActor () -> Void,
    focusAction: @escaping @MainActor () -> Void,
    primaryAction: @escaping @MainActor () -> Void,
    backAction: @escaping @MainActor () -> Void,
    copyAction: @escaping @MainActor () -> Void,
    autoDismissOnDeactivate: Bool = true
  ) {
    hostingController = NSHostingController(rootView: rootView)
    self.dismissalAction = dismissalAction
    self.showAction = showAction
    self.focusAction = focusAction
    self.primaryAction = primaryAction
    self.backAction = backAction
    self.copyAction = copyAction

    let panel = QuickCheckPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Quick Check"
    panel.contentViewController = hostingController
    panel.setContentSize(NSSize(width: 620, height: 620))
    panel.minSize = NSSize(width: 460, height: 360)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = autoDismissOnDeactivate
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
    let restoredSavedFrame = panel.setFrameUsingName(Self.frameAutosaveName)
    panel.setFrameAutosaveName(Self.frameAutosaveName)

    super.init(window: panel)
    if !restoredSavedFrame {
      center(panel, on: activeScreen())
    }
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
    showAction()
    panel.setFrame(
      panel.constrainFrameRect(panel.frame, to: panel.screen),
      display: false
    )
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let self, let panel else { return }
      self.focusInput(in: panel, remainingAttempts: 20)
    }
  }

  func closePanel(reason: QuickCheckDismissalReason) {
    guard !isClosing else { return }
    isClosing = true
    dismissalAction(reason)
    window?.orderOut(nil)
    isClosing = false
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    closePanel(reason: .windowClose)
    return false
  }

  @objc private func applicationDidResignActive() {
    guard window?.isVisible == true else { return }
    closePanel(reason: .applicationDeactivated)
  }

  private func handleShortcut(_ event: NSEvent) -> Bool {
    guard
      let command = Self.command(
        keyCode: event.keyCode,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        modifierFlags: event.modifierFlags
      )
    else { return false }

    switch command {
    case .cancel:
      closePanel(reason: .explicitCancel)
    case .primaryAction:
      primaryAction()
    case .back:
      backAction()
    case .copy:
      copyAction()
    }
    return true
  }

  nonisolated static func command(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags
  ) -> QuickCheckPanelCommand? {
    let modifiers = modifierFlags.intersection([.command, .shift, .option, .control])
    if modifiers.isEmpty, keyCode == 53 {
      return .cancel
    }
    if modifiers == [.command] {
      if keyCode == 36 || keyCode == 76 {
        return .primaryAction
      }
      if charactersIgnoringModifiers == "[" {
        return .back
      }
    }
    if modifiers == [.command, .shift], charactersIgnoringModifiers?.lowercased() == "c" {
      return .copy
    }
    return nil
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
