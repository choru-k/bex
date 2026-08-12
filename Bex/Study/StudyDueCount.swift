import Foundation

/// Pure ambient-cue logic for Study Mode's contribution to the menu-bar badge —
/// the *push* half of Study Mode (docs/learning-mode-plan.md). Mirrors
/// `LearningBadge.swift` exactly: no `Date()` anywhere in this file, callers
/// (`AppDelegate`) supply "now" and the loaded `[StudyCard]`/state map, so every path
/// here is a deterministic function of its arguments and unit-testable without mocking
/// the clock or touching disk.
enum StudyDueCount {
  /// Today's actionable Study workload — NOT the total backlog. A thin pass-through to
  /// `StudyDailyPlan.plan`, which is what actually decides "reviews always, new cards
  /// capped at `StudyDailyPlan.newCardBatchSize` at a time" (see that file for why).
  /// This used to report the raw `StudyScheduler.dueCards` count, which for a
  /// never-studied deck means "every card" — a number that never shrinks day to day
  /// and reads as a permanent, unclearable backlog. Reporting today's small, capped
  /// plan instead is what makes the menu-bar badge and daily notification a number
  /// worth looking at rather than a source of dread.
  static func count(
    cards: [StudyCard],
    states: [String: StudyReviewState],
    now: Date
  ) -> Int {
    StudyDailyPlan.plan(cards: cards, states: states, now: now).cardIDs.count
  }

  /// How urgently the badge's color should escalate, driven by `maxOverdueDays` from
  /// `StudyDailyPlan.Plan` (0 for a plan with no reviews, or reviews that are all still
  /// on schedule). Deliberately NOT "any overdue card → red": if the badge turns red
  /// every single day (which it would, the moment even one review lands a day late),
  /// red stops meaning anything and becomes wallpaper the owner learns to ignore —
  /// exactly the "unclearable pressure" this whole feature exists to avoid. Reserving
  /// the strongest color for genuinely-behind (2+ days overdue) keeps it a real signal;
  /// today's ordinary on-time batch reads as `.normal` even though it's non-empty.
  enum StudySeverity: String, Codable, Equatable, Sendable {
    case normal
    case behind
    case late
  }

  static func severity(maxOverdueDays: Int) -> StudySeverity {
    switch maxOverdueDays {
    case 0: return .normal
    case 1: return .behind
    default: return .late
    }
  }

  /// Rough seconds one drill card costs, used only to phrase the workload as a price.
  //
  // ponytail: a flat per-card constant, not a rolling average of the owner's real answer
  // times. Ceiling: if the estimate ever reads as wrong, time the drill and average the
  // last few answers here instead.
  private static let secondsPerCard: Double = 24

  /// The menu-bar hub's header line: what today's remaining stack *costs*, not how many
  /// cards it is.
  ///
  /// A count is the wrong unit for the thing non-negotiable 6 asks for. "5 cards" reads
  /// as a queue with a number attached; "2 min today" reads as a price the owner can
  /// decide to pay right now, and it shrinks visibly with every card cleared. Zero is
  /// stated as the count it is — "0 due" (design 4e) — because reaching it is the whole
  /// point of a clearable number, and "0 min" would be a price for nothing.
  static func costLabel(remaining: Int) -> String {
    guard remaining > 0 else { return "0 due" }
    let minutes = max(1, Int((Double(remaining) * secondsPerCard / 60).rounded()))
    return "\(minutes) min today"
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
