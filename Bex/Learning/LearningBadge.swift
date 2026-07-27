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

  /// `count` is the number of `samples` strictly newer than `lastViewedAt` (all of them
  /// when `lastViewedAt` is `nil`, i.e. never viewed). `shouldShow` is `false` until the
  /// corpus reaches the activation threshold, and stays `false` even past threshold when
  /// there is nothing new (`count == 0`) — an ambient cue with nothing to say stays
  /// silent rather than showing a "0".
  static func status(samples: [LearningSample], lastViewedAt: Date?) -> Status {
    let recurringCounts = LearningAggregator.recurringCounts(
      explanations: samples.map(\.explanation))
    let recurringCategoryCount = recurringCounts
      .filter { $0.count >= activationRecurrenceThreshold }
      .count
    // Volume gate counts only substantive entries — those with a grammar fix or an
    // expression suggestion. Pure "No changes needed." no-ops carry no learning material,
    // so they must not inflate the "≥20 reviewed corrections" bar (docs/learning-mode-plan.md).
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

    let count: Int
    if let lastViewedAt {
      count = samples.filter { $0.date > lastViewedAt }.count
    } else {
      count = samples.count
    }
    return Status(shouldShow: count > 0, count: count)
  }
}
