import Foundation

/// Pure ambient-cue logic for the menu-bar "Learning" badge (docs/learning-mode-plan.md
/// Phase 1). Operates on already-parsed `LearningSample`s and a `lastViewedAt` cutoff —
/// no `Date()` anywhere in this file, so every path is deterministic and unit-testable;
/// callers (`AppDelegate`) supply "now" only indirectly, via the `lastViewedAt` value
/// they read from `PreferencesStore` and via which samples they pass in.
enum LearningBadge {
  struct Status: Equatable, Sendable {
    let shouldShow: Bool
    let count: Int
  }

  /// The same threshold that gates the Phase-1 by-hand gate (docs/learning-mode-plan.md):
  /// at least this many corrections total, with at least `activationCategoryThreshold`
  /// grammar categories each recurring at least `activationRecurrenceThreshold` times.
  static let activationEntryThreshold = 20
  static let activationCategoryThreshold = 2
  static let activationRecurrenceThreshold = 3

  /// `count` is how many DISTINCT, still-untapped expression alternatives appeared in
  /// samples strictly newer than `lastViewedAt` (all samples when `lastViewedAt` is `nil`,
  /// i.e. never viewed). `shouldShow` is `false` until the corpus reaches the activation
  /// threshold, and stays `false` even past threshold when there is nothing new
  /// (`count == 0`) — an ambient cue with nothing to say stays silent rather than show "0".
  ///
  /// This counted whole entries until v7. That worked while a `Consider` section was rare,
  /// but v7 makes one appear on every single correction, which turned the badge into a
  /// count of prompts sent — always lit, therefore carrying no information. Three changes
  /// restore its meaning, all pointed at the same lesson v0.6's daily plan already learned:
  /// a pressure signal that cannot reach zero reads as hopeless rather than motivating.
  ///
  /// - Count alternatives, not entries, so the badge measures material to review.
  /// - Deduplicate by `phrase|alternative`: the same rephrasing suggested across twenty
  ///   corrections is one decision, not twenty.
  /// - Drop anything already in `tappedIDs` — a decision made is not a backlog item.
  ///
  /// Opening the Learning window still clears it via `lastViewedAt`, so a batch the owner
  /// looks at and wants none of does not nag forever.
  static func status(
    samples: [LearningSample], tappedIDs: Set<String>, lastViewedAt: Date?
  ) -> Status {
    let recurringCounts = LearningAggregator.recurringCounts(
      explanations: samples.map(\.explanation))
    let recurringCategoryCount = recurringCounts
      .filter { $0.count >= activationRecurrenceThreshold }
      .count
    // Volume gate counts only substantive entries — those with a grammar fix or an
    // expression suggestion. Pure "No changes needed." no-ops carry no learning material,
    // so they must not inflate the "≥20 reviewed corrections" bar (docs/learning-mode-plan.md).
    //
    // Weaker since v7 than it looks: nearly every entry now carries a `Consider` section,
    // so in practice this is close to "≥20 prompts sent". Left alone deliberately — the
    // recurrence gate below is the load-bearing half, and retuning a threshold the owner
    // baselined on the pre-v7 corpus is a decision for the re-baselining pass, not a side
    // effect of a badge fix. See docs/learning-mode-plan.md "v7 costs".
    let substantiveCount = samples.filter {
      !LearningAggregator.parseFixedTags(from: $0.explanation).isEmpty
        || !LearningAggregator.parseConsiderSuggestions(from: $0.explanation).isEmpty
    }.count
    guard
      substantiveCount >= activationEntryThreshold,
      recurringCategoryCount >= activationCategoryThreshold
    else {
      return Status(shouldShow: false, count: 0)
    }

    let unseen = lastViewedAt.map { cutoff in samples.filter { $0.date > cutoff } } ?? samples
    let pending = Set(
      unseen.flatMap { sample in
        LearningAggregator.parseConsiderSuggestions(from: sample.explanation)
          .compactMap { LearningAggregator.parseSuggestionLine($0) }
          .map { "\($0.phrase)|\($0.alternative)" }
      }
    ).subtracting(tappedIDs)
    return Status(shouldShow: !pending.isEmpty, count: pending.count)
  }
}
