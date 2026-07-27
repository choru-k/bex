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

/// Whether one "Consider" suggestion later showed up, unprompted, in the owner's own
/// writing — goal 2's only falsifiability signal (docs/learning-mode-plan.md, Phase 1).
struct UptakeDetail: Equatable, Sendable {
  let phrase: String
  let adopted: Bool
}

/// Pure metric math over `LearningSample` corpora: rate-per-100-words (normalizes for
/// how much was written — absolute counts reward writing less), the median-sentence-
/// length avoidance guard, weekly bucketing for the 6-week trend judgment, and the
/// goal-2 uptake tripwire. The app SHOWS these; none of them auto-enforce a kill.
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

  /// The suggested phrase from one "Consider" line (format `"original" → "suggested"
  /// — reason`, `->` tolerated too): the quoted text immediately following the arrow.
  /// `nil` if the line has no arrow or no quoted text after it.
  static func suggestedPhrase(fromConsiderLine line: String) -> String? {
    let arrowRange = line.range(of: "→") ?? line.range(of: "->")
    guard let arrowRange else { return nil }
    let afterArrow = line[arrowRange.upperBound...]
    guard let openQuote = afterArrow.firstIndex(of: "\"") else { return nil }
    let afterOpenQuote = afterArrow[afterArrow.index(after: openQuote)...]
    guard let closeQuote = afterOpenQuote.firstIndex(of: "\"") else { return nil }
    let phrase = afterOpenQuote[..<closeQuote].trimmingCharacters(in: .whitespaces)
    return phrase.isEmpty ? nil : phrase
  }

  /// Goal-2 uptake: for every "Consider" suggestion in `samples`, checks whether its
  /// suggested phrase (case-insensitive, trimmed) later appears as a substring of the
  /// `original` in some STRICTLY later sample (by date — reappearing earlier, or only
  /// in the same sample, does not count). Near-zero `adopted` out of `suggested` means
  /// the expression layer is feel-good input rather than learning.
  static func uptake(samples: [LearningSample]) -> (
    adopted: Int, suggested: Int, details: [UptakeDetail]
  ) {
    let chronological = samples.sorted { $0.date < $1.date }
    var details: [UptakeDetail] = []
    for (index, sample) in chronological.enumerated() {
      let considerLines = LearningAggregator.parseConsiderSuggestions(from: sample.explanation)
      for line in considerLines {
        guard let phrase = suggestedPhrase(fromConsiderLine: line) else { continue }
        let adopted = chronological[(index + 1)...].contains {
          $0.date > sample.date && containsWholeWord($0.original, phrase: phrase)
        }
        details.append(UptakeDetail(phrase: phrase, adopted: adopted))
      }
    }
    return (adopted: details.filter(\.adopted).count, suggested: details.count, details: details)
  }

  /// Word-boundary, case-insensitive containment. Uptake must not count a short suggested
  /// phrase matching *inside* an unrelated word (e.g. "many" inside "Germany"), which would
  /// inflate the expression layer's only falsifiability signal. Falls back to substring only
  /// if the phrase cannot form a valid pattern.
  private static func containsWholeWord(_ haystack: String, phrase: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: phrase)
    guard
      let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive])
    else {
      return haystack.range(of: phrase, options: .caseInsensitive) != nil
    }
    let range = NSRange(haystack.startIndex..., in: haystack)
    return regex.firstMatch(in: haystack, options: [], range: range) != nil
  }
}
