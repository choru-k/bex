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
      return LearningSample(date: date, original: entry.original, explanation: entry.explanation)
    }
  }
}
