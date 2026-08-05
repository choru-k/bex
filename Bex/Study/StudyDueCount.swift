import Foundation

/// Pure ambient-cue logic for Study Mode's contribution to the menu-bar badge —
/// the *push* half of Study Mode (docs/learning-mode-plan.md). Mirrors
/// `LearningBadge.swift` exactly: no `Date()` anywhere in this file, callers
/// (`AppDelegate`) supply "now" and the loaded `[StudyCard]`/state map, so every path
/// here is a deterministic function of its arguments and unit-testable without mocking
/// the clock or touching disk.
enum StudyDueCount {
  /// How many of `cards` are currently due, given `states` and `now`. A thin
  /// pass-through to `StudyScheduler.dueCards` — kept as its own entry point (rather
  /// than calling the scheduler directly from `AppDelegate`) so the badge-precedence
  /// decision below and the due-count computation live in one file with one doc
  /// comment about determinism.
  static func count(
    cards: [StudyCard],
    states: [String: StudyReviewState],
    now: Date
  ) -> Int {
    StudyScheduler.dueCards(ids: cards.map(\.id), states: states, now: now).count
  }

  /// What the single menu-bar status-item title should show. `AppDelegate` has exactly
  /// one slot (the status item's title/badge) but two things that want it: Study's due
  /// count and `LearningBadge`'s "new corrections" count. This struct is the answer;
  /// `AppDelegate` just applies it verbatim to the button.
  struct MenuBarBadge: Equatable, Sendable {
    /// The literal title to put on the status item button (e.g. "3"), or `""` when
    /// nothing should show.
    let text: String
    /// Full sentence for VoiceOver — the button's title alone ("3") is meaningless
    /// without context.
    let accessibilityLabel: String
    /// Whether the badge should render at all. When `false`, `AppDelegate` restores the
    /// icon-only button exactly as `LearningBadge`'s `shouldShow == false` case did.
    let isVisible: Bool
  }

  /// Decides which of the two competing signals wins the one badge slot.
  ///
  /// PRECEDENCE: Study's due count wins whenever it is `> 0`; the existing Learning
  /// "new corrections" status is shown only as a fallback when nothing is due. This is
  /// deliberate, not arbitrary: a due Study card is an actionable call-to-action with a
  /// decay curve attached to it — the whole point of spaced repetition (see
  /// `StudyScheduler`) is that a card left un-reviewed keeps getting easier to forget,
  /// so "cards are due" is the more urgent thing to put in front of the owner right
  /// now. The Learning count, by contrast, is just "material exists to review
  /// whenever" — it has no due date and does not get worse by being ignored for a day.
  /// When both are zero/hidden, the badge disappears entirely, exactly as
  /// `LearningBadge.Status(shouldShow: false, ...)` already did on its own.
  static func badge(studyDue: Int, learning: LearningBadge.Status) -> MenuBarBadge {
    if studyDue > 0 {
      return MenuBarBadge(
        text: "\(studyDue)",
        accessibilityLabel:
          "Bex — \(studyDue) card\(studyDue == 1 ? "" : "s") due for review",
        isVisible: true
      )
    }
    if learning.shouldShow {
      return MenuBarBadge(
        text: "\(learning.count)",
        accessibilityLabel:
          "Bex — \(learning.count) new correction\(learning.count == 1 ? "" : "s") to review",
        isVisible: true
      )
    }
    return MenuBarBadge(text: "", accessibilityLabel: "Bex", isVisible: false)
  }
}
