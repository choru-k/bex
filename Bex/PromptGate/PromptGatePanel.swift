import AppKit
import SwiftUI

final class PromptGatePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@MainActor
final class PromptGatePanelController: NSWindowController, NSWindowDelegate {
  private let hostingController: NSHostingController<AnyView>
  private let cancelAction: @MainActor () -> Void
  nonisolated(unsafe) private var keyMonitor: Any?

  init(
    rootView: AnyView,
    cancelAction: @escaping @MainActor () -> Void
  ) {
    hostingController = NSHostingController(rootView: rootView)
    self.cancelAction = cancelAction

    let panel = PromptGatePanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Fix & Send"
    panel.contentViewController = hostingController
    panel.setContentSize(NSSize(width: 760, height: 680))
    panel.minSize = NSSize(width: 620, height: 500)
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow

    super.init(window: panel)
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, self.window?.isKeyWindow == true else { return event }
      let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
      if modifiers.isEmpty, event.keyCode == 53 {
        self.cancelAction()
        return nil
      }
      return event
    }
    panel.delegate = self
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
  }

  func show() {
    guard let panel = window as? PromptGatePanel else { return }
    center(panel, on: activeScreen())
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak self, weak panel] in
      guard let self, let panel else { return }
      self.focusInput(in: panel, remainingAttempts: 20)
    }
  }

  func orderOut() {
    window?.orderOut(nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cancelAction()
    return false
  }

  private func focusInput(in panel: NSPanel, remainingAttempts: Int) {
    guard panel.isVisible else { return }
    if let contentView = panel.contentView,
      let textView = firstTextView(in: contentView),
      panel.makeFirstResponder(textView)
    {
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
    panel.setFrameOrigin(
      NSPoint(
        x: visible.midX - panel.frame.width / 2,
        y: visible.midY - panel.frame.height / 2
      )
    )
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
