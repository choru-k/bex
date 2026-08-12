import AppKit
import SwiftUI

/// One card, offered right after a prompt ships.
///
/// Design 4c. The timing is the whole idea: the owner has just written the English that
/// produced this card and is now waiting on an agent, so it is the one moment in the day
/// when a drill costs them nothing. It shows at most one card, only when something is
/// already due.
///
/// Non-negotiable 2 shapes what this is allowed to do, and the two states are the answer
/// to a panel that cannot take the keyboard uninvited:
/// - **Unarmed**: the panel never activates Bex; the answer slot is drawn dashed and
///   inert, and the copy promises only what a click can deliver. The whole panel is one
///   click target. Ignored for 30 seconds, it fades out — the card stays due, so it is
///   already in today's pile (`StudyScheduler` only moves a card on an answer).
/// - **Armed** (after a click): a real focused answer control. The app that had the
///   keyboard is captured before arming, and Esc hands the caret straight back to it.
struct StudyMicroDrillView: View {
  @ObservedObject var viewModel: StudyViewModel
  /// The app the prompt went to, e.g. "Codex".
  let targetName: String
  /// Activates Bex and makes the drill panel key — only ever called from the arm click,
  /// never on show. Owned by `WindowCoordinator` because the view cannot reach its panel.
  let makeKey: () -> Void
  let dismiss: () -> Void

  @State private var isArmed = false
  /// Whoever had the keyboard when the owner clicked to arm. Esc reactivates it.
  @State private var previousApp: NSRunningApplication?
  @State private var isFadingOut = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if let card = viewModel.currentCard {
        Text("While it ships — one card")
          .font(.system(size: 10, weight: .semibold))
          .textCase(.uppercase)
          .kerning(0.9)
          .foregroundStyle(.tint)
        if isArmed {
          StudyCardView(viewModel: viewModel, card: card, scale: .compact)
          Text("⏎ checks · Esc returns the keyboard exactly where it was")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("micro-drill-armed-hint")
        } else {
          unarmedCard(card)
        }
      }
    }
    .padding(18)
    .frame(width: 400)
    .opacity(isFadingOut ? 0 : 1)
    .accessibilityIdentifier("micro-drill")
    // The session may have been the last card; closing beats showing an empty panel.
    .onChange(of: viewModel.currentCard?.id) { id in
      if id == nil { dismissRestoringFocus() }
    }
    .onExitCommand { dismissRestoringFocus() }
    // Ignored for 30s while unarmed → fade out. The card is not written anywhere on the
    // way out because it does not need to be: only an answer moves a card
    // (`StudyScheduler.advance`), so an ignored card is still due and already sits in
    // today's pile for the hub and the deck. Nothing is lost.
    .task(id: isArmed) {
      guard !isArmed else { return }
      try? await Task.sleep(nanoseconds: 30_000_000_000)
      guard !isArmed, !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.4)) { isFadingOut = true }
      try? await Task.sleep(nanoseconds: 450_000_000)
      dismiss()
    }
  }

  private var header: some View {
    HStack {
      Label("Sent to \(targetName)", systemImage: "checkmark.circle.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.green)
        .accessibilityIdentifier("micro-drill-sent")
      Spacer()
      Button(action: dismissRestoringFocus) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("micro-drill-dismiss")
    }
  }

  /// The card face-up but inert: same category line and sentence as the real template,
  /// with a dashed slot where the answer control will be. One big click target.
  private func unarmedCard(_ card: StudyCard) -> some View {
    Button(action: arm) {
      VStack(spacing: StudyCardScale.compact.spacing) {
        Text(card.displayCategory)
          .font(.system(size: StudyCardScale.compact.categorySize, weight: .semibold))
          .textCase(.uppercase)
          .kerning(0.9)
          .foregroundStyle(card.source.tint)
        Text(card.promptWithBlank)
          .font(.system(size: StudyCardScale.compact.promptSize, weight: .medium))
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)

        Text("Click to answer — your keyboard stays in the terminal")
          .font(.system(size: StudyCardScale.compact.answerSize))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .frame(maxWidth: .infinity)
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .strokeBorder(
                Color(nsColor: .separatorColor),
                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
              )
          }

        Text("Ignored? It slides into today's pile after 30s. Nothing is lost.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Click to answer — your keyboard stays in the terminal")
    .accessibilityIdentifier("micro-drill-arm")
  }

  /// The one moment this panel is allowed to take the keyboard: the owner asked for it.
  /// The frontmost app is captured first, while it is still frontmost, so Esc has a
  /// truthful place to send the caret back to.
  private func arm() {
    previousApp = NSWorkspace.shared.frontmostApplication
    isArmed = true
    makeKey()
  }

  /// Close, handing the keyboard back to whoever had it before arming. A dismissal that
  /// never armed has nothing to restore and restores nothing.
  private func dismissRestoringFocus() {
    previousApp?.activate()
    dismiss()
  }
}

/// A HUD for the micro-drill that never steals focus.
///
/// `.nonactivatingPanel` plus `becomesKeyOnlyIfNeeded` is the whole point: the panel shows
/// up in the corner while the owner keeps typing in whatever they were typing in, and only
/// takes the keyboard when they click to arm it. Anything that activated Bex here would
/// make the drill an interruption of the send rather than something waiting beside it.
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

  /// The arm click's other half: Bex activates and the panel becomes key so the answer
  /// field can actually hold the caret. Never called on show.
  func activateForAnswering() {
    guard let panel = window else { return }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  func close(_: Any? = nil) {
    window?.orderOut(nil)
  }
}
