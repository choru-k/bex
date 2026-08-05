import Foundation

/// Persisted spaced-repetition state for one study card, keyed elsewhere by card id
/// (see `StudyStateStore`). `box` is the Leitner box index into
/// `StudyScheduler.intervalDays`; `dueAt` is when the card next becomes eligible for
/// review. `timesSeen`/`timesCorrect` are lifetime counters kept for a future stats
/// view — they never affect scheduling.
struct StudyReviewState: Codable, Equatable, Sendable {
  var box: Int
  var dueAt: Date
  var timesSeen: Int
  var timesCorrect: Int
}

/// Pure Leitner-box scheduling for Study Mode drills built from the user's own logged
/// English mistakes (docs/learning-mode-plan.md). Deliberately NOT SM-2/FSRS: those
/// exist to model per-item forgetting curves across large decks and many users. This
/// app has one user and a deck that grows a few cards a day, so four fixed boxes with
/// fixed intervals give "wrong answers come back tomorrow, right answers come back
/// less often" without the complexity of an ease-factor model.
///
/// Every function here takes `now` as a parameter and never calls `Date()` — matching
/// the rule in `LearningBadge.swift`: scheduling must be a pure, deterministic function
/// of its inputs so it is trivially unit-testable and never flaky under test timing.
enum StudyScheduler {
  /// Box `i` is due `intervalDays[i]` days after being answered correctly into that
  /// box. Index 0 is also the "wrong answer" box (1-day retry). Four boxes is enough
  /// runway for a single-user deck; add entries here (and bump the clamp ceiling that
  /// falls out of `intervalDays.count`) if a longer "graduated" tail is ever wanted.
  static let intervalDays = [1, 3, 7, 21]

  /// Seconds in a day, as a plain constant rather than `Calendar` arithmetic.
  //
  // ponytail: this ignores DST transitions and leap seconds — a card "due in 3 days"
  // might land a few minutes off around a DST boundary. That precision is meaningless
  // for a spaced-repetition study app (nobody notices "due at 8:57am" vs "9:00am").
  // Ceiling: if Study Mode ever needs calendar-exact due dates (e.g. "due at local
  // midnight"), swap this for `Calendar.date(byAdding:to:)` day arithmetic.
  private static let secondsPerDay: TimeInterval = 86_400

  /// The due date for landing in `box`, measured from `now`. Clamps `box` into
  /// `intervalDays`'s bounds first so an out-of-range index (which should never
  /// happen, but must never crash) falls back to the nearest valid interval.
  private static func interval(forBox box: Int) -> TimeInterval {
    let clamped = min(max(box, 0), intervalDays.count - 1)
    return Double(intervalDays[clamped]) * secondsPerDay
  }

  /// Advances one card's review state after it was answered. `state` is `nil` for a
  /// card that has never been reviewed before, which is treated as starting at box 0
  /// (so a first-ever correct answer promotes it to box 1, same as any other card
  /// already sitting in box 0).
  ///
  /// - Correct: box increases by one, clamped at the last index (mastered cards stay
  ///   in the top box rather than growing an ever-larger index).
  /// - Wrong: box resets to 0 and the card is due again tomorrow, regardless of how
  ///   high it had climbed — a fresh mistake means the spacing claim was wrong.
  static func advance(_ state: StudyReviewState?, correct: Bool, now: Date) -> StudyReviewState {
    let currentBox = state?.box ?? 0
    let timesSeen = (state?.timesSeen ?? 0) + 1
    let timesCorrect = (state?.timesCorrect ?? 0) + (correct ? 1 : 0)

    let newBox = correct ? min(currentBox + 1, intervalDays.count - 1) : 0
    let dueAt = now.addingTimeInterval(interval(forBox: newBox))

    return StudyReviewState(
      box: newBox,
      dueAt: dueAt,
      timesSeen: timesSeen,
      timesCorrect: timesCorrect
    )
  }

  /// A card with no recorded state has never been studied, so it is always due — there
  /// is nothing to wait on. Otherwise it's due once its `dueAt` has arrived; `<=` so a
  /// due date that lands exactly on `now` counts as due rather than requiring the
  /// caller to wait for the next tick.
  static func isDue(_ state: StudyReviewState?, now: Date) -> Bool {
    guard let state else { return true }
    return state.dueAt <= now
  }

  /// Filters `ids` down to the ones currently due, preserving the caller's ordering
  /// (e.g. however the deck orders new-vs-review cards) rather than re-sorting by due
  /// date — this is a filter, not a priority queue.
  static func dueCards(
    ids: [String],
    states: [String: StudyReviewState],
    now: Date
  ) -> [String] {
    ids.filter { isDue(states[$0], now: now) }
  }
}
