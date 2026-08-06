import Foundation

/// One learning-log entry reduced to the fields the metrics below need. Callers map
/// `LearningLogStore.Entry` (or any future corpus sharing the same two-section
/// `explanation` format) into this — nothing here touches the actor or its storage, so
/// every function in this file is a pure, plain-input unit test target.
struct LearningSample: Equatable, Sendable {
  let date: Date
  let original: String
  let explanation: String
}

/// One canonical category's recurrence normalized by how much was written, plus the
/// raw count it was derived from. `GrammarCategory` (`LearningAggregator.swift`) must
/// stay in sync with the `[tag]` list in `Bex/Grammar/GrammarPrompts.swift` — this
/// struct just carries whatever tag `LearningAggregator.recurringCounts` found.
struct CategoryRate: Equatable, Sendable {
  let category: String
  let count: Int
  let ratePer100Words: Double

  var displayName: String {
    GrammarCategory(rawValue: category)?.displayName ?? category
  }
}

/// Per-category rates + the complexity floor + word volume for one ISO week.
struct WeeklyRate: Equatable, Sendable {
  let yearForWeekOfYear: Int
  let weekOfYear: Int
  let categoryRates: [CategoryRate]
  let medianSentenceLength: Double
  let totalWords: Int
}

/// Pure metric math over `LearningSample` corpora: rate-per-100-words (normalizes for
/// how much was written — absolute counts reward writing less), the median-sentence-
/// length avoidance guard, and weekly bucketing for the 6-week trend judgment. The app
/// SHOWS these; none of them auto-enforce a kill.
///
/// The goal-2 uptake tripwire used to live here too. It inferred adoption by watching for
/// a suggested phrase to reappear in later writing — a proxy that only made sense while
/// `Consider` offered a single recommendation. v7 made it offer several deliberately
/// unranked alternatives, so at most one can ever be "adopted" and the inferred rate
/// collapses for reasons unrelated to whether the layer works. `ConsiderTapStore` replaces
/// the proxy with the owner's actual pick; see docs/learning-mode-plan.md v7.1 decision 1.
enum LearningMetrics {
  /// Non-empty whitespace/newline-split tokens. `Character.isWhitespace` already
  /// covers newlines, so a single split does the job.
  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  /// Rate per 100 words for each canonical category present in `samples`, sorted
  /// descending by rate (ties broken alphabetically by category, matching
  /// `LearningAggregator.recurringCounts`). Zero total words yields rate 0 for every
  /// category rather than dividing by zero.
  static func categoryRates(samples: [LearningSample]) -> [CategoryRate] {
    let totalWords = samples.reduce(0) { $0 + wordCount($1.original) }
    let counts = LearningAggregator.recurringCounts(explanations: samples.map(\.explanation))
    return counts
      .map { count in
        let rate = totalWords > 0 ? Double(count.count) / Double(totalWords) * 100 : 0
        return CategoryRate(category: count.category, count: count.count, ratePer100Words: rate)
      }
      .sorted {
        $0.ratePer100Words != $1.ratePer100Words
          ? $0.ratePer100Words > $1.ratePer100Words : $0.category < $1.category
      }
  }

  /// Median word count across every sentence in `originals`, naively split on `.`,
  /// `?`, `!` (consecutive punctuation like "?!" collapses to one boundary since the
  /// split omits empty subsequences by default). This is the avoidance guard: a drop
  /// in error rate alongside a drop in sentence length signals writing simpler to
  /// dodge errors, not genuine improvement. 0 when there are no sentences.
  static func medianSentenceLength(originals: [String]) -> Double {
    let lengths = originals.flatMap(sentenceWordCounts).sorted()
    guard !lengths.isEmpty else { return 0 }
    let mid = lengths.count / 2
    if lengths.count.isMultiple(of: 2) {
      return Double(lengths[mid - 1] + lengths[mid]) / 2
    }
    return Double(lengths[mid])
  }

  private static func sentenceWordCounts(in text: String) -> [Int] {
    text.split(whereSeparator: { ".?!".contains($0) })
      .map { wordCount(String($0)) }
      .filter { $0 > 0 }
  }

  /// Buckets `samples` by ISO week (`.iso8601` calendar, `.weekOfYear` +
  /// `.yearForWeekOfYear`) and returns one `WeeklyRate` per week that has data, in
  /// chronological order. Buckets come only from the samples' own dates — never from
  /// `Date()` — so this is fully deterministic on fixed input.
  static func weeklyRates(samples: [LearningSample]) -> [WeeklyRate] {
    let calendar = Calendar(identifier: .iso8601)
    struct WeekKey: Hashable {
      let year: Int
      let week: Int
    }
    var buckets: [WeekKey: [LearningSample]] = [:]
    for sample in samples {
      let components = calendar.dateComponents(
        [.yearForWeekOfYear, .weekOfYear], from: sample.date)
      guard let year = components.yearForWeekOfYear, let week = components.weekOfYear else {
        continue
      }
      buckets[WeekKey(year: year, week: week), default: []].append(sample)
    }
    return buckets.keys
      .sorted { $0.year != $1.year ? $0.year < $1.year : $0.week < $1.week }
      .map { key in
        let bucket = buckets[key]!
        return WeeklyRate(
          yearForWeekOfYear: key.year,
          weekOfYear: key.week,
          categoryRates: categoryRates(samples: bucket),
          medianSentenceLength: medianSentenceLength(originals: bucket.map(\.original)),
          totalWords: bucket.reduce(0) { $0 + wordCount($1.original) }
        )
      }
  }
}
