import AppKit
import SwiftUI

enum PromptGatePanelLayout {
  static let preferredContentSize = NSSize(width: 640, height: 500)
  static let minimumContentSize = NSSize(width: 460, height: 420)

  static func requiredContentSize(for phase: PromptGatePhase) -> NSSize {
    switch phase {
    case .closed, .onboarding, .invalidated:
      NSSize(width: 460, height: 500)
    case .composing, .checking:
      NSSize(width: 460, height: 600)
    case .reviewing, .delivering:
      NSSize(width: 460, height: 680)
    }
  }
}

final class PromptGatePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

struct PromptGateFrameMemory: Equatable {
  private(set) var rememberedFrame: NSRect?

  init(restoredFrame: NSRect? = nil) {
    rememberedFrame = restoredFrame
  }

  mutating func resolvedFrame(
    defaultSize: NSSize,
    visibleFrame: NSRect
  ) -> NSRect {
    if let rememberedFrame {
      let restored = Self.fitted(rememberedFrame, inside: visibleFrame)
      self.rememberedFrame = restored
      return restored
    }

    let size = NSSize(
      width: min(defaultSize.width, visibleFrame.width),
      height: min(defaultSize.height, visibleFrame.height)
    )
    let initial = NSRect(
      x: visibleFrame.midX - size.width / 2,
      y: visibleFrame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
    rememberedFrame = initial
    return initial
  }

  mutating func rememberUserFrame(_ frame: NSRect, visibleFrame: NSRect) {
    rememberedFrame = Self.fitted(frame, inside: visibleFrame)
  }

  mutating func frameGrowing(
    to requiredSize: NSSize,
    defaultSize: NSSize,
    visibleFrame: NSRect
  ) -> NSRect {
    let current = resolvedFrame(defaultSize: defaultSize, visibleFrame: visibleFrame)
    let width = min(max(current.width, requiredSize.width), visibleFrame.width)
    let height = min(max(current.height, requiredSize.height), visibleFrame.height)
    let grown = NSRect(
      x: current.minX,
      y: current.maxY - height,
      width: width,
      height: height
    )
    let fitted = Self.fitted(grown, inside: visibleFrame)
    rememberedFrame = fitted
    return fitted
  }

  private static func fitted(_ frame: NSRect, inside visibleFrame: NSRect) -> NSRect {
    let width = min(frame.width, visibleFrame.width)
    let height = min(frame.height, visibleFrame.height)
    let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
    let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }
}

@MainActor
final class PromptGatePanelController: NSWindowController, NSWindowDelegate {
  static let frameAutosaveName = NSWindow.FrameAutosaveName("Bex.PromptGate")

  private let hostingController: NSHostingController<AnyView>
  private let cancelAction: @MainActor () -> Void
  nonisolated(unsafe) private var keyMonitor: Any?
  private var frameMemory = PromptGateFrameMemory()
  private var isApplyingRememberedFrame = false

  init(
    rootView: AnyView,
    cancelAction: @escaping @MainActor () -> Void,
    frameAutosaveName: NSWindow.FrameAutosaveName = PromptGatePanelController.frameAutosaveName
  ) {
    hostingController = NSHostingController(rootView: rootView)
    self.cancelAction = cancelAction

    let panel = PromptGatePanel(
      contentRect: NSRect(origin: .zero, size: PromptGatePanelLayout.preferredContentSize),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = "Fix & Send"
    panel.contentViewController = hostingController
    panel.setContentSize(PromptGatePanelLayout.preferredContentSize)
    panel.contentMinSize = PromptGatePanelLayout.minimumContentSize
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
    super.init(window: panel)
    let restoredSavedFrame = panel.setFrameUsingName(frameAutosaveName)
    _ = panel.setFrameAutosaveName(frameAutosaveName)
    if restoredSavedFrame {
      frameMemory = PromptGateFrameMemory(restoredFrame: panel.frame)
    }
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
    let screen = restorationScreen(for: panel)
    applyFrame(frameMemory.resolvedFrame(
      defaultSize: panel.frame.size,
      visibleFrame: screen.visibleFrame
    ), to: panel)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  func orderOut() {
    rememberCurrentFrame()
    window?.orderOut(nil)
  }

  func accommodate(_ phase: PromptGatePhase) {
    ensureMinimumContentSize(PromptGatePanelLayout.requiredContentSize(for: phase))
  }

  private func ensureMinimumContentSize(_ requiredContentSize: NSSize) {
    guard let panel = window as? PromptGatePanel else { return }
    let requiredFrame = panel.frameRect(
      forContentRect: NSRect(origin: .zero, size: requiredContentSize)
    )
    let screen = restorationScreen(for: panel)
    let frame = frameMemory.frameGrowing(
      to: requiredFrame.size,
      defaultSize: panel.frame.size,
      visibleFrame: screen.visibleFrame
    )
    applyFrame(frame, to: panel)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    cancelAction()
    return false
  }

  func windowDidMove(_ notification: Notification) {
    rememberCurrentFrame()
  }

  func windowDidResize(_ notification: Notification) {
    rememberCurrentFrame()
  }

  private func rememberCurrentFrame() {
    guard !isApplyingRememberedFrame,
      let panel = window as? PromptGatePanel,
      let screen = panel.screen ?? NSScreen.main
    else { return }
    frameMemory.rememberUserFrame(panel.frame, visibleFrame: screen.visibleFrame)
  }

  private func applyFrame(_ frame: NSRect, to panel: NSPanel) {
    isApplyingRememberedFrame = true
    panel.setFrame(frame, display: panel.isVisible, animate: false)
    isApplyingRememberedFrame = false
  }

  private func restorationScreen(for panel: NSPanel) -> NSScreen {
    if let rememberedFrame = frameMemory.rememberedFrame {
      let intersectingScreen = NSScreen.screens.max { lhs, rhs in
        let lhsIntersection = NSIntersectionRect(lhs.visibleFrame, rememberedFrame)
        let rhsIntersection = NSIntersectionRect(rhs.visibleFrame, rememberedFrame)
        return lhsIntersection.width * lhsIntersection.height
          < rhsIntersection.width * rhsIntersection.height
      }
      if let intersectingScreen {
        let intersection = NSIntersectionRect(
          intersectingScreen.visibleFrame,
          rememberedFrame
        )
        if intersection.width * intersection.height > 0 {
          return intersectingScreen
        }
      }
    }
    if let screen = panel.screen, panel.isVisible {
      return screen
    }
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens[0]
  }
}
