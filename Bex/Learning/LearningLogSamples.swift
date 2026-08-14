import Foundation

/// Parses raw `LearningLogStore.Entry` records into pure `LearningSample`s for
/// `LearningMetrics`/`LearningBadge`. Kept separate from the actor so the ISO8601
/// parsing step is a plain, unit-testable function — entries whose `timestamp` isn't
/// valid ISO8601 are skipped rather than failing the whole read (the learning log is
/// best-effort, see `LearningLogStore.readAll`).
enum LearningLogSamples {
  static func parse(_ entries: [LearningLogStore.Entry]) -> [LearningSample] {
    let formatter = ISO8601DateFormatter()
    return entries.compactMap { entry in
      guard let date = formatter.date(from: entry.timestamp) else { return nil }
      return LearningSample(
        date: date,
        original: entry.original,
        explanation: entry.explanation,
        // The ask thread is the one log client whose entries are answers the owner asked
        // for rather than corrections of what they wrote; the card tint says so.
        source: entry.client == "bex-ask" ? .ask : .correction
      )
    }
  }

  /// Log entries plus tapped "Consider" alternatives, oldest first — the card-building
  /// corpus.
  ///
  /// Only `StudyCardBuilder` callers use this. `LearningMetrics` deliberately keeps reading
  /// `parse` alone, because a tap is a choice made while reviewing, not text the owner
  /// wrote, and counting its words would dilute the per-100-words error rates.
  ///
  /// The sort is required, not tidiness: `cards(from:)` dedups first-occurrence-wins and
  /// `StudyDailyPlan` takes new cards in list order, so appending taps after the log would
  /// park every chosen expression permanently behind the entire backlog.
  static func merged(
    _ entries: [LearningLogStore.Entry], taps: [ConsiderTap]
  ) -> [LearningSample] {
    let formatter = ISO8601DateFormatter()
    let tapSamples = taps.compactMap { tap -> LearningSample? in
      guard let date = formatter.date(from: tap.timestamp) else { return nil }
      return LearningSample(
        date: date, original: tap.sourceOriginal, explanation: tap.learningLogExplanation,
        source: .pick)
    }
    return (parse(entries) + tapSamples).sorted { $0.date < $1.date }
  }
}
