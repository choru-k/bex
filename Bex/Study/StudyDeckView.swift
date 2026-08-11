import SwiftUI

/// The deck at rest: what is waiting, and one key to start it.
///
/// This is where Esc from a drill lands, and where Learn opens when nothing is due. It
/// shows the pile and what it costs, never a backlog total — see `StudyDueCount.costLabel`.
struct StudyDeckView: View {
  @ObservedObject var viewModel: StudyViewModel
  /// Enters the drill. Owned by `LearnView`, which also has to collapse the window chrome.
  let start: () -> Void

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
    } else {
      LearnEmptyState(
        symbol: "checkmark.seal",
        headline: "Nothing due right now",
        detail: "Come back tomorrow — or keep writing, and Bex will find the next gap.",
        identifier: "study-empty"
      )
    }
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
            .foregroundStyle(.tint)
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

        StudyPileDots(total: viewModel.sessionTotal, completed: viewModel.completedCount, dotWidth: 26, dotHeight: 5)
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
  let card: StudyCard
  /// Leaves the drill. Unanswered cards stay due — `StudyScheduler` only moves on an
  /// answer, so quitting mid-session loses nothing and never needs a confirmation.
  let end: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      topBar
      Spacer()
      StudyCardView(viewModel: viewModel, card: card, scale: .takeover)
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
    HStack {
      Spacer()
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
}
