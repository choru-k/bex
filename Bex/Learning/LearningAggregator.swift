import Foundation

/// Canonical grammar-mistake tags. This list MUST stay in sync with the `[tag]` list
/// embedded in the prompt strings in `Bex/Grammar/GrammarPrompts.swift` (`system` and
/// `promptSafeSystem`): `[article] [verb-tense] [subject-verb-agreement] [preposition]
/// [word-order] [plural] [spelling] [capitalization] [other]`.
enum GrammarCategory: String, CaseIterable, Sendable {
  case article
  case verbTense = "verb-tense"
  case subjectVerbAgreement = "subject-verb-agreement"
  case preposition
  case wordOrder = "word-order"
  case plural
  case spelling
  case capitalization
  /// Dictionary lookups saved from Quick Check, not grammar corrections. `GrammarPrompts`
  /// never emits this tag — only `DictionaryLookup.learningLogExplanation` does — so it
  /// exists to keep vocabulary out of the grammar stats (see `recurringCounts`) while
  /// still letting `StudyCardBuilder` drill it like any other card.
  case vocabulary
  /// A "Consider" alternative the owner tapped in the Learning window, not a mistake he
  /// made. `GrammarPrompts` never emits this tag either — only
  /// `ConsiderTap.learningLogExplanation` does — so like `vocabulary` it exists to keep a
  /// deliberate choice out of the grammar stats while still letting `StudyCardBuilder`
  /// drill it. See docs/learning-mode-plan.md v7.1 decision 1.
  case expression
  case other

  /// Friendly label for the Learning window.
  var displayName: String {
    switch self {
    case .article: return "Articles (a, an, the)"
    case .verbTense: return "Verb tense"
    case .subjectVerbAgreement: return "Subject-verb agreement"
    case .preposition: return "Prepositions"
    case .wordOrder: return "Word order"
    case .plural: return "Plurals"
    case .spelling: return "Spelling"
    case .capitalization: return "Capitalization"
    case .vocabulary: return "Vocabulary"
    case .expression: return "Expression"
    case .other: return "Other"
    }
  }
}

/// One canonical category and how many times it recurred across a corpus of explanations.
struct GrammarCategoryCount: Equatable, Sendable {
  let category: String
  let count: Int

  var displayName: String {
    GrammarCategory(rawValue: category)?.displayName ?? category
  }
}

/// Source-agnostic aggregation over the two-section `explanation` text produced by
/// `GrammarPrompts` ("Fixed:" grammar corrections, "Consider:" expression suggestions).
/// Operates on plain `[String]` so it is trivially unit-testable and reusable across any
/// corpus that shares this explanation format (learning log today, possibly Quick Check
/// history later — see docs/learning-mode-plan.md v6.2).
enum LearningAggregator {
  /// Canonical `[tag]` values found under the "Fixed:" section of one explanation.
  /// Non-canonical bracketed text is ignored. Stops before "Consider:". Tolerates
  /// "No changes needed." and a missing "Fixed:" section (both yield `[]`).
  static func parseFixedTags(from explanation: String) -> [String] {
    linesInSection(named: "Fixed:", of: explanation).flatMap(leadingBracketTags)
  }

  /// Canonical tags from the consecutive `[...]` groups at the start of a Fixed line, after
  /// skipping any list marker ("- ", "* ", "1. ", "2) "). A bracketed token that is not one
  /// of the 9 canonical tags is bucketed as `other` rather than dropped, so a drifted tag
  /// (e.g. `[punctuation]`) still counts toward the gate instead of vanishing silently.
  private static func leadingBracketTags(in line: String) -> [String] {
    var rest = stripLeadingListMarker(Substring(line))
    var tags: [String] = []
    while rest.first == "[", let close = rest.firstIndex(of: "]") {
      let raw = String(rest[rest.index(after: rest.startIndex)..<close])
      tags.append(GrammarCategory(rawValue: raw) != nil ? raw : GrammarCategory.other.rawValue)
      rest = rest[rest.index(after: close)...].drop { $0 == " " }
    }
    return tags
  }

  /// Drops one leading list marker ("- ", "* ", "• ", "1. ", "2) ") if present, so a bulleted
  /// or numbered Fixed line still exposes its `[tag]` prefix.
  private static func stripLeadingListMarker(_ line: Substring) -> Substring {
    let rest = line.drop { $0 == " " }
    if let first = rest.first, first == "-" || first == "*" || first == "•" {
      return rest.dropFirst().drop { $0 == " " }
    }
    let digits = rest.prefix { $0.isNumber }
    if !digits.isEmpty {
      let afterDigits = rest[digits.endIndex...]
      if let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" {
        return afterDigits.dropFirst().drop { $0 == " " }
      }
    }
    return rest
  }

  /// Raw lines under the "Consider:" section of one explanation (expression suggestions).
  static func parseConsiderSuggestions(from explanation: String) -> [String] {
    linesInSection(named: "Consider:", of: explanation)
  }

  /// Splits one "Consider" line — `"original" → "alternative" — reason` — into its parts.
  /// `->` is tolerated in place of `→` because models produce both.
  ///
  /// Returns `nil` for any line that is not an alternative, which is load-bearing rather
  /// than defensive: since v7 the section ends with a plain `Which fits? …` prose line, and
  /// that line having no arrow is exactly what keeps it out of the tappable list without
  /// the caller needing to recognize it. Prose in, nothing out.
  static func parseSuggestionLine(_ line: String) -> (
    phrase: String, alternative: String, reason: String
  )? {
    let text = stripLeadingListMarker(Substring(line))
    guard let phraseOpen = text.firstIndex(of: "\"") else { return nil }
    let afterPhraseOpen = text[text.index(after: phraseOpen)...]
    guard let phraseClose = afterPhraseOpen.firstIndex(of: "\"") else { return nil }
    let phrase = String(afterPhraseOpen[..<phraseClose])

    let afterPhrase = afterPhraseOpen[afterPhraseOpen.index(after: phraseClose)...]
    guard let arrow = afterPhrase.range(of: "→") ?? afterPhrase.range(of: "->") else { return nil }
    let afterArrow = afterPhrase[arrow.upperBound...]
    guard let altOpen = afterArrow.firstIndex(of: "\"") else { return nil }
    let afterAltOpen = afterArrow[afterArrow.index(after: altOpen)...]
    guard let altClose = afterAltOpen.firstIndex(of: "\"") else { return nil }
    let alternative = String(afterAltOpen[..<altClose])

    guard !phrase.isEmpty, !alternative.isEmpty else { return nil }
    let trailing = afterAltOpen[afterAltOpen.index(after: altClose)...]
    return (phrase, alternative, strippedReason(trailing))
  }

  /// Drops one leading separator (`—`, `--`, `-`) and surrounding whitespace from the text
  /// after the alternative's closing quote. Mirrors `StudyCardBuilder.reason(after:)`.
  private static func strippedReason(_ text: Substring) -> String {
    var rest = Substring(String(text).trimmingCharacters(in: .whitespaces))
    if rest.hasPrefix("—") {
      rest = rest.dropFirst()
    } else if rest.hasPrefix("--") {
      rest = rest.dropFirst(2)
    } else if rest.hasPrefix("-") {
      rest = rest.dropFirst()
    }
    return String(rest).trimmingCharacters(in: .whitespaces)
  }

  /// The explanation text with the "Consider:" section (and its header) removed — i.e. the
  /// "Fixed:" grammar notes only. Mirrors the case-insensitive header matching used by
  /// `linesInSection`. Returns the whole explanation, trimmed, when there is no "Consider:"
  /// header (including "No changes needed.").
  static func explanationWithoutConsider(from explanation: String) -> String {
    let lines = explanation.components(separatedBy: .newlines)
    guard
      let headerIndex = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased() == "consider:"
      })
    else {
      return explanation.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return lines[..<headerIndex].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Counts of each canonical grammar tag across many explanations, sorted by count
  /// descending (ties broken alphabetically by category for stable output).
  ///
  /// `capitalization` is excluded: in a terminal-prompt corpus it is almost entirely
  /// sentence-start lowercasing ("fix" → "Fix"), a typing habit rather than an English
  /// weakness, and at ~60% of all tags it drowns the signal (articles, prepositions,
  /// word order) the Learning window exists to surface. The raw tag stays in the log and
  /// in `parseFixedTags`; only these aggregate stats drop it.
  /// ponytail: whole-category exclusion; add sentence-start-vs-proper-noun detection only if real capitalization errors ever matter here.
  ///
  /// `vocabulary` and `expression` are excluded for a different reason: a saved dictionary
  /// lookup is a word the owner chose to learn, and a tapped "Consider" alternative is a
  /// rephrasing he chose to adopt — neither is a mistake he made. Counting them would
  /// inflate the per-100-words error rates in `LearningMetrics` — which read straight from
  /// this function — every time he looks something up or picks an alternative, making the
  /// gate he already passed depend on how curious he was that week.
  static let statisticsExcludedCategories: Set<String> = [
    GrammarCategory.capitalization.rawValue,
    GrammarCategory.vocabulary.rawValue,
    GrammarCategory.expression.rawValue,
  ]

  static func recurringCounts(explanations: [String]) -> [GrammarCategoryCount] {
    var counts: [String: Int] = [:]
    for explanation in explanations {
      for tag in parseFixedTags(from: explanation)
      where !statisticsExcludedCategories.contains(tag) {
        counts[tag, default: 0] += 1
      }
    }
    return counts
      .map { GrammarCategoryCount(category: $0.key, count: $0.value) }
      .sorted {
        $0.count != $1.count ? $0.count > $1.count : $0.category < $1.category
      }
  }

  /// Non-empty, trimmed lines between a section header (`"Fixed:"` or `"Consider:"`) and
  /// the next recognized section header or end of text.
  private static func linesInSection(named header: String, of explanation: String) -> [String] {
    let lines = explanation.components(separatedBy: .newlines)
    let target = header.lowercased()
    guard
      let headerIndex = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased() == target
      })
    else {
      return []
    }
    var result: [String] = []
    for line in lines[(headerIndex + 1)...] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { continue }
      let lowered = trimmed.lowercased()
      if lowered == "fixed:" || lowered == "consider:" { break }
      result.append(trimmed)
    }
    return result
  }
}
