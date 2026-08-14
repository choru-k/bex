import SwiftUI

/// The deck at rest: what is waiting, and one key to start it.
///
/// This is where Esc from a drill lands, and where Learn opens when nothing is due. It
/// shows the pile and what it costs, never a backlog total — see `StudyDueCount.costLabel`.
struct StudyDeckView: View {
  @ObservedObject var viewModel: StudyViewModel
  /// Enters the drill. Owned by `LearnView`, which also has to collapse the window chrome.
  let start: () -> Void
  /// The action that creates cards, offered by the first-run empty state so an empty deck
  /// that only said "come back later" would not be a dead end.
  let openFixAndSend: () -> Void

  var body: some View {
    if viewModel.isLoading {
      ProgressView("Loading Study…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("study-loading")
    } else if let card = viewModel.currentCard {
      atRest(card)
    } else if viewModel.isFinished {
      LearnEmptyState(
        symbol: "party.popper",
        headline: "Done — \(viewModel.completedCount) reviewed",
        detail: "The stack is clear. Anything you missed comes back tomorrow.",
        identifier: "study-done"
      )
    } else if viewModel.deckSize == 0 {
      firstRun
    } else {
      LearnEmptyState(
        symbol: "checkmark.seal",
        headline: "Nothing due right now",
        detail: "Come back tomorrow — or keep writing, and Bex will find the next gap.",
        identifier: "study-empty"
      )
    }
  }

  /// A fresh install's deck: a dashed card that says why empty is the correct state,
  /// and the real action that changes it. No sample cards or fake numbers.
  private var firstRun: some View {
    VStack(spacing: 18) {
      VStack(spacing: 12) {
        Text("No cards yet — and that's correct")
          .font(.headline)
        Text(
          "Cards come from your own prompts. Run a check on the next thing you type at "
            + "Claude or Codex — gaps and picks land here on their own."
        )
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(28)
      .frame(width: 440)
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(
            Color(nsColor: .separatorColor),
            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
          )
      }

      Button("Fix & Send ⇧⌘P", action: openFixAndSend)
        .accessibilityIdentifier("study-empty-fix-and-send")

      Text("Progress stays empty until there is something real to measure.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("study-first-run")
  }

  /// The next card face-up but not answerable, so starting is a deliberate keypress rather
  /// than something that happens to the owner while they are reading the tabs.
  private func atRest(_ card: StudyCard) -> some View {
    VStack(spacing: 22) {
      StudyCardStack(remaining: viewModel.remainingCount) {
        VStack(spacing: 14) {
          Text(card.displayCategory)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.9)
            .foregroundStyle(card.source.tint)
          Text(card.promptWithBlank)
            .font(.system(size: 21, weight: .medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 440)
      }
      .accessibilityIdentifier("study-deck-preview")

      VStack(spacing: 10) {
        Text(StudyDueCount.costLabel(remaining: viewModel.remainingCount))
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("study-deck-cost")

        Button(viewModel.completedCount > 0 ? "Keep going ⏎" : "Start ⏎", action: start)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("study-deck-start")

        StudyPileDots(
          total: viewModel.sessionTotal, completed: viewModel.completedCount, dotWidth: 26,
          dotHeight: 5)
      }
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A drill with the window to itself.
///
/// Design 3a, and the reference it comes from: the card is the whole screen. No sidebar, no
/// tabs, no counters, no stats — the sentence gets the largest type in the app and the only
/// two things left are the dots and the key that gets out. Everything the chrome was doing
/// is still true when the session ends; none of it helps while a card is on screen.
struct StudyTakeoverView: View {
  @ObservedObject var viewModel: StudyViewModel
  @ObservedObject var askThread: AskThreadViewModel
  let card: StudyCard
  /// Leaves the drill. Unanswered cards stay due — `StudyScheduler` only moves on an
  /// answer, so quitting mid-session loses nothing and never needs a confirmation.
  let end: () -> Void
  @State private var isAsking = false

  var body: some View {
    VStack(spacing: 0) {
      topBar
      Spacer()
      VStack(spacing: 22) {
        StudyCardView(viewModel: viewModel, card: card, scale: .takeover)
        askSection
      }
      .frame(maxWidth: 620)
      .padding(.horizontal, 40)
      Spacer()
      StudyPileDots(
        total: viewModel.sessionTotal,
        completed: viewModel.completedCount,
        dotWidth: 26,
        dotHeight: 5
      )
      .padding(.bottom, 26)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("study-takeover")
  }

  private var topBar: some View {
    HStack(spacing: 14) {
      Spacer()
      // The hint *is* the button. It used to be inert text beside a zero-sized,
      // fully-transparent button that carried the ⌘/ shortcut — which is both a thing
      // SwiftUI need not register a shortcut for and a thing the owner cannot click. One
      // visible control that says its own key is shorter and actually works.
      Button {
        isAsking = true
      } label: {
        Text("？ Ask ⌘/")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut("/", modifiers: .command)
      .accessibilityIdentifier("study-ask-shortcut")
      Button(action: end) {
        Text("Esc ends the session")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier("study-end-session")
    }
    .padding(.horizontal, 18)
    .padding(.top, 14)
  }

  /// The ask thread, folded away until ⌘/ opens it.
  ///
  /// Design 3a keeps the takeover empty — the card is the whole screen — so this stays a
  /// single hint until asked for, and the card waits: opening it does not grade, skip or
  /// advance anything.
  @ViewBuilder
  private var askSection: some View {
    if isAsking {
      AskThreadView(viewModel: askThread, prompt: "Ask about this card…")
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .onAppear { askThread.reset(context: askContext) }
    } else if askThread.isEmpty {
      Button("？ Ask about this card") { isAsking = true }
        .buttonStyle(.link)
        .font(.callout)
        .accessibilityIdentifier("study-ask-open")
    }
  }

  /// What a question about this card is about: the sentence and the answer it turns on.
  private var askContext: String {
    let reason = card.reason.isEmpty ? "" : " (\(card.reason))"
    return "\(card.sentence)\nThe blank is “\(card.correct)”, not “\(card.wrong)”\(reason)."
  }
}
