import AppKit
import SwiftUI

/// One card, offered right after a prompt ships.
///
/// Design 1f. The timing is the whole idea: the owner has just written the English that
/// produced this card and is now waiting on an agent, so it is the one moment in the day
/// when a drill costs them nothing. It shows at most one card, only when something is
/// already due, and it goes away on Esc or the close box.
///
/// Non-negotiable 2 shapes what this is allowed to do. It appears *after* delivery, never
/// before, and its panel does not activate Bex — see `StudyMicroDrillPanelController`. That
/// is a deliberate departure from the mock, which showed "Return to check" as if the field
/// already had focus: giving it focus would mean yanking the caret out of the terminal the
/// owner just sent to, which is precisely the shipping flow this rule protects.
struct StudyMicroDrillView: View {
  @ObservedObject var viewModel: StudyViewModel
  /// The app the prompt went to, e.g. "Codex".
  let targetName: String
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let card = viewModel.currentCard {
        Text("While it ships — one card")
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .kerning(0.9)
          .foregroundStyle(.tint)
        StudyCardView(viewModel: viewModel, card: card, scale: .compact)
        Text("Answer it whenever — this never takes focus from your send.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(18)
    .frame(width: 400)
    .accessibilityIdentifier("micro-drill")
    // The session may have been the last card; closing beats showing an empty panel.
    .onChange(of: viewModel.currentCard?.id) { id in
      if id == nil { dismiss() }
    }
  }

  private var header: some View {
    HStack {
      Label("Sent to \(targetName)", systemImage: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.green)
        .accessibilityIdentifier("micro-drill-sent")
      Spacer()
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("micro-drill-dismiss")
    }
  }
}

/// A HUD for the micro-drill that never steals focus.
///
/// `.nonactivatingPanel` plus `becomesKeyOnlyIfNeeded` is the whole point: the panel shows
/// up in the corner while the owner keeps typing in whatever they were typing in, and only
/// takes the keyboard if they click into it. Anything that activated Bex here would make
/// the drill a interruption of the send rather than something waiting beside it.
@MainActor
final class StudyMicroDrillPanelController: NSWindowController {
  private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
  }

  init(rootView: AnyView) {
    let panel = Panel(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    let hosting = NSHostingController(rootView: rootView)
    hosting.sizingOptions = [.preferredContentSize]
    panel.contentViewController = hosting
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.level = .floating
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.animationBehavior = .utilityWindow
    super.init(window: panel)
  }

  required init?(coder: NSCoder) { nil }

  /// Parks the panel in the top-right of the screen the pointer is on, the way a
  /// notification arrives — off to the side of whatever has focus, not over it.
  func show() {
    guard let panel = window else { return }
    let screen =
      NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
      ?? NSScreen.main
    if let visible = screen?.visibleFrame {
      panel.setFrameOrigin(
        NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - panel.frame.height - 24)
      )
    }
    panel.orderFrontRegardless()
  }

  func close(_: Any? = nil) {
    window?.orderOut(nil)
  }
}
