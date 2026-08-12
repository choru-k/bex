import AppKit
import SwiftUI

/// The bits of hub state that belong to the app rather than to Study.
///
/// Shortcut chords live here because the owner can rebind them in Settings and the hub
/// must show what is actually bound, not what shipped. `conflictMessage` is the popover's
/// home for the hot-key registration failure that used to be inserted as a disabled
/// `NSMenuItem` at the top of the status menu — same job, same wording, new surface.
@MainActor
final class MenuBarHubModel: ObservableObject {
  @Published var quickCheckChord: KeyChord = .defaultQuickCheck
  @Published var fixAndSendChord: KeyChord = .defaultFixAndSend
  @Published var conflictMessage: String?
}

/// The menu-bar popover: today's cost, the first due card, and the three commands.
///
/// This replaces a plain `NSMenu`, and the replacement is the point rather than a
/// restyling. The old menu could only *route* to studying — every card cost a click to
/// open a window, and `docs/purpose.md` records that a surface the owner has to go to is a
/// surface that teaches nothing. Here the card is already in the popover with the cursor
/// in the answer field, so opening the popover *is* starting: one keystroke clears a card
/// and no window ever opens.
///
/// There is no "Start drill" button and no due-count banner for the same reason the header
/// reads "2 min today" instead of "5 cards due" — see `StudyDueCount.costLabel`.
struct MenuBarHubView: View {
  @ObservedObject var hub: MenuBarHubModel
  @ObservedObject var study: StudyViewModel

  let openQuickCheck: () -> Void
  let openFixAndSend: () -> Void
  let openMainWindow: () -> Void
  let openSettings: () -> Void
  let openWelcome: () -> Void
  let quit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let conflictMessage = hub.conflictMessage {
        conflictBanner(conflictMessage)
      }
      header
      cardSection
      Divider()
        .padding(.horizontal, 12)
      commands
      footer
    }
    .frame(width: 320)
    .task {
      await study.loadIfNeeded()
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 8) {
      // "Nothing due" must mean it, so the header stays quiet until the deck has actually
      // been read rather than flashing an all-clear on the way to finding five cards.
      Text(study.isLoading ? "Checking…" : StudyDueCount.costLabel(remaining: study.remainingCount))
        .font(.system(size: 13, weight: .semibold))
        .accessibilityIdentifier("hub-cost")

      Spacer(minLength: 8)

      if study.sessionTotal > 0 {
        StudyPileDots(
          total: study.sessionTotal,
          completed: study.completedCount,
          dotWidth: 20
        )
      }

      overflowMenu
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }

  /// Settings, Welcome, About and Quit. Bex runs as an accessory app, so its application
  /// menu only exists while one of its windows has focus — without this the owner could
  /// reach a state with no window open and no way to quit.
  private var overflowMenu: some View {
    Menu {
      Button("Settings…", action: openSettings)
      Divider()
      Button("Welcome to Bex", action: openWelcome)
      Button("About Bex") {
        NSApp.orderFrontStandardAboutPanel(nil)
      }
      Divider()
      Button("Quit Bex", action: quit)
    } label: {
      Image(systemName: "gearshape")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("hub-overflow")
  }

  private func conflictBanner(_ message: String) -> some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .accessibilityIdentifier("hub-shortcut-conflict")
  }

  // MARK: - Card

  @ViewBuilder
  private var cardSection: some View {
    Group {
      if study.isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 18)
      } else if let card = study.currentCard {
        StudyCardView(
          viewModel: study,
          card: card,
          scale: .compact,
          subtitle: "card \(min(study.completedCount + 1, study.sessionTotal)) of \(study.sessionTotal)"
        )
        .padding(14)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
      } else if study.isFinished {
        Text("Done — \(study.completedCount) reviewed")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 16)
          .accessibilityIdentifier("hub-done")
      }
      // Zero due needs no card section at all: the header already says "0 due", which is
      // both correct and the goal (design 4e / non-negotiable 6), and the command rows
      // below stay — the hub is never hidden.
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  // MARK: - Commands

  private var commands: some View {
    VStack(spacing: 0) {
      commandRow(
        "Quick Check",
        shortcut: hub.quickCheckChord.displayString,
        identifier: "hub-quick-check",
        action: openQuickCheck
      )
      commandRow(
        "Fix & Send",
        shortcut: hub.fixAndSendChord.displayString,
        identifier: "hub-fix-and-send",
        action: openFixAndSend
      )
      commandRow(
        "Open Bex",
        shortcut: "Learn · History · Styles",
        identifier: "hub-open-bex",
        action: openMainWindow
      )
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  private func commandRow(
    _ title: String,
    shortcut: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack {
        Text(title)
          .font(.system(size: 13))
        Spacer(minLength: 12)
        Text(shortcut)
          .font(.system(size: 11.5).monospaced())
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }

  /// Says how to answer without touching the mouse, and only when there is something to
  /// answer — a keyboard hint under an empty deck is just noise.
  @ViewBuilder
  private var footer: some View {
    if let card = study.currentCard, !study.answerRevealed {
      Text(
        card.answerMode == .typed
          ? "Focus lands in the answer field the moment this opens."
          : "Press a number to answer without leaving the menu bar."
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
    } else {
      Spacer().frame(height: 6)
    }
  }
}

/// Hosts `MenuBarHubView` in an `NSPopover` anchored to the status item.
///
/// A popover rather than an `NSMenu` because the hub has a text field in it, and `NSMenu`
/// cannot host a first responder — the "type the answer right here" behaviour the whole
/// redesign of this surface rests on is impossible in a menu.
@MainActor
final class MenuBarHubController {
  private let popover = NSPopover()

  init(rootView: AnyView) {
    let hosting = NSHostingController(rootView: rootView)
    // Lets the popover take its height from the SwiftUI content, so a card with three
    // choices and a card with a text field each get exactly the room they need.
    hosting.sizingOptions = [.preferredContentSize]
    popover.contentViewController = hosting
    popover.behavior = .transient
    popover.animates = false
  }

  var isShown: Bool { popover.isShown }

  func toggle(relativeTo button: NSStatusBarButton) {
    if popover.isShown {
      popover.performClose(nil)
    } else {
      show(relativeTo: button)
    }
  }

  func show(relativeTo button: NSStatusBarButton) {
    // An accessory app is not frontmost when its status item is clicked, and a popover
    // whose app is not active never becomes key — which would leave the answer field
    // unfocused and silently break the one thing this surface is for.
    NSApp.activate(ignoringOtherApps: true)
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  func close() {
    popover.performClose(nil)
  }
}
