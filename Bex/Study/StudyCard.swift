import Foundation

/// How a drill card is answered. Decided once, at build time, from the shape of the
/// correct answer (see `StudyCardBuilder.answerMode(for:)`) — never re-derived in the
/// UI, so the view and the view model agree on it for free.
enum StudyAnswerMode: String, Codable, Equatable, Sendable {
  /// Free-text entry, graded by `StudyAnswerCheck`. Real recall instead of a 50/50 pick.
  case typed
  /// Today's two-button pick, kept for corrections too long to type comfortably.
  case choices
}

/// One spaced-repetition drill built from a single past "Fixed:" correction in the
/// learning log. Pure data — no scheduling, no persistence, no UI; `StudyCardBuilder`
/// below is the only thing that constructs these, and it never touches the clock, RNG,
/// or a database, so a fixed `[LearningSample]` input always yields the exact same
/// cards in the exact same order.
struct StudyCard: Equatable, Sendable {
  /// `"\(category)|\(wrong)|\(correct)"`. This is a plain composed string, not a hash:
  /// a future review-state store will persist per-card scheduling state keyed by `id`
  /// in JSON, and that has to survive across app launches. Swift's `Hasher` is seeded
  /// randomly per process — using `hashValue` here would silently reset every saved
  /// review streak on the next launch. A `UUID()` would be even worse: it isn't even
  /// reproducible from the same log entry twice, so re-running the builder (e.g. after
  /// re-importing the log) would mint a brand-new card for a correction the user
  /// already drilled. `category` is included because the same wrong/correct pair
  /// showing up under two different tags is still worth tracking as two cards — the
  /// grammar lesson differs even though the surface text collides.
  ///
  /// Deliberately excludes `reason`: the id keys persisted per-card review state
  /// (box, due date, streak), and a model rewording the same explanation on a later
  /// log pass must not orphan progress the owner already has on this card.
  let id: String
  /// The canonical `GrammarCategory` raw value (or `"other"` — see `GrammarCategory`
  /// canonicalization), never the raw bracket text from the log line.
  let category: String
  let wrong: String
  let correct: String
  /// The free-text explanation that followed the `"wrong" → "correct"` pair on the
  /// "Fixed:" line, e.g. "this is the correct preposition for this meaning" — see
  /// `StudyCardBuilder.reason(after:)` for the exact separator-stripping rule. Empty
  /// string (never `nil`) when the line carried no reason, so a reasonless line still
  /// produces a usable card instead of being dropped.
  let reason: String
  /// The original text the mistake came from, newlines collapsed to single spaces.
  /// Kept alongside `promptWithBlank` (which may be trimmed) so a UI that wants full
  /// context — e.g. "show me the whole thing" — still has it.
  let sentence: String
  /// `sentence` with the first case-insensitive, word-boundary occurrence of `wrong`
  /// replaced by `"_____"`, trimmed to a readable window when `sentence` is long. This
  /// is what the drill UI actually shows.
  let promptWithBlank: String
  /// Always contains `correct` and `wrong`, plus up to two same-category distractors.
  /// Sorted alphabetically (case-insensitive) for a deterministic order — see
  /// `StudyCardBuilder.choices(for:among:)` for why shuffling does not belong here.
  /// Populated regardless of `answerMode`: a `.typed` card still needs `wrong`/
  /// `correct` available for feedback, and a future "reveal the options after a failed
  /// attempt" needs no data change to build on top of this.
  let choices: [String]
  /// Whether this card is a typed free-response drill or today's two-choice pick — see
  /// `StudyCardBuilder.answerMode(for:)` for the thresholds that decide it.
  let answerMode: StudyAnswerMode
  /// How much this correction is worth drilling, from `StudyCardQuality.priority`. Never
  /// `.junk` — those are rejected in `StudyCardBuilder.isUsableCandidate` and never
  /// become cards. `StudyDailyPlan` uses this to order new-card intake.
  let priority: StudyCardPriority

  /// Friendly label for the drill UI, reusing `GrammarCategory`'s mapping so this
  /// stays in sync with the Learning window's category names for free.
  var displayCategory: String {
    GrammarCategory(rawValue: category)?.displayName ?? category
  }
}

/// Turns raw `LearningSample`s into `StudyCard`s. Every function here is a pure
/// transform over its arguments — no `Date()`, no RNG, no I/O — so the whole pipeline
/// is unit-testable on fixed input and reproducible across runs (required for `id`
/// stability, see `StudyCard.id`).
enum StudyCardBuilder {
  /// One parsed "Fixed:" line before cloze/choice construction, and before the
  /// cross-sample dedup pass in `cards(from:)` decides which survive.
  private struct BaseCard {
    let id: String
    let category: String
    let wrong: String
    let correct: String
    let reason: String
    let sentence: String
    let promptWithBlank: String
  }

  /// Builds one card per usable "Fixed:" correction across `samples`, in order,
  /// deduplicated by `StudyCard.id` (first occurrence wins — matching
  /// `LearningLogStore.readAll`'s oldest-first ordering, so the earliest-logged
  /// occurrence of a recurring mistake is the one that becomes the card).
  static func cards(from samples: [LearningSample]) -> [StudyCard] {
    var seenIDs = Set<String>()
    var bases: [BaseCard] = []
    for sample in samples {
      for base in baseCards(from: sample) {
        guard !seenIDs.contains(base.id) else { continue }
        seenIDs.insert(base.id)
        bases.append(base)
      }
    }
    return bases.map { base in
      StudyCard(
        id: base.id,
        category: base.category,
        wrong: base.wrong,
        correct: base.correct,
        reason: base.reason,
        sentence: base.sentence,
        promptWithBlank: base.promptWithBlank,
        choices: choices(for: base),
        answerMode: answerMode(for: base.correct),
        priority: StudyCardQuality.priority(wrong: base.wrong, correct: base.correct)
      )
    }
  }

  /// A correct answer short enough to type is worth typing — real recall beats a
  /// 50/50 pick. Measured on the owner's real 136-card deck: an answer of at most
  /// `typedMaxWords` words covers 104 of 136 cards (76%), so most drills exercise
  /// actual recall, while the long tail (up to 17 words) stays a 2-choice pick rather
  /// than a tedious transcription exercise. `typedMaxCharacters` guards against a
  /// short-word-count answer that's still long to type (e.g. dense compound phrasing).
  /// Both thresholds are named constants so they're tunable in one place.
  static let typedMaxWords = 4
  static let typedMaxCharacters = 40

  static func answerMode(for correct: String) -> StudyAnswerMode {
    let wordCount = correct.split(whereSeparator: \.isWhitespace).count
    guard wordCount <= typedMaxWords, correct.count <= typedMaxCharacters else { return .choices }
    return .typed
  }

  // MARK: - Per-sample candidate extraction

  private static func baseCards(from sample: LearningSample) -> [BaseCard] {
    fixedLines(in: sample.explanation).compactMap { line in
      guard let parsed = parseFixedLine(line) else { return nil }
      guard
        isUsableCandidate(
          wrong: parsed.wrong, correct: parsed.correct, category: parsed.category)
      else { return nil }
      guard let built = cloze(wrong: parsed.wrong, in: sample.original) else { return nil }
      return BaseCard(
        id: "\(parsed.category)|\(parsed.wrong)|\(parsed.correct)",
        category: parsed.category,
        wrong: parsed.wrong,
        correct: parsed.correct,
        reason: parsed.reason,
        sentence: built.sentence,
        promptWithBlank: built.promptWithBlank
      )
    }
  }

  /// Whether a parsed `(wrong, correct, category)` triple is worth turning into a
  /// drill. Exposed (not `private`) so this — the whole point of the feature — is
  /// directly unit-testable without going through log-line parsing.
  ///
  /// The capitalization filters are the important ones: in the real 214-line corpus,
  /// 105 "Fixed:" lines are sentence-start capitalization ("fix" → "Fix"), a terminal
  /// typing habit rather than an English mistake, and roughly a third of those are
  /// mis-tagged `[other]` rather than `[capitalization]`. Filtering by tag alone
  /// (`category != capitalization`) would miss those, so the case-insensitive string
  /// comparison runs regardless of what tag the line carries.
  ///
  /// The `StudyAnswerCheck.normalize` filter below catches a different, broader class:
  /// punctuation/format-only diffs. On the same real 136-card deck, 10 cards differ
  /// ONLY by trailing punctuation (`"again"` → `"again."`, `"status"` → `"status."`,
  /// `"links"` → `"links?"`, `"i mean"` → `"I mean,"`). These are dropped for two
  /// independent reasons: (a) they teach nothing about English — the same noise class
  /// as the sentence-start capitalization filtered above; (b) typed mode cannot grade
  /// them at all, because a forgiving comparison (trim/collapse-whitespace/lowercase/
  /// strip-edge-punctuation) would accept the wrong answer as correct by construction —
  /// there'd be nothing left to distinguish them. The explicit case-only check above
  /// stays even though this normalized check subsumes it, for clarity about exactly
  /// which real-world case it exists to catch.
  static func isUsableCandidate(wrong: String, correct: String, category: String) -> Bool {
    guard !wrong.isEmpty, !correct.isEmpty else { return false }
    guard wrong != correct else { return false }
    guard wrong.lowercased() != correct.lowercased() else { return false }
    guard category != GrammarCategory.capitalization.rawValue else { return false }
    guard StudyAnswerCheck.normalize(wrong) != StudyAnswerCheck.normalize(correct) else {
      return false
    }
    // The quality gate: keyboard typos, punctuation-only diffs, and parse debris are not
    // English mistakes. See `StudyCardQuality` for each rule and what it dropped from the
    // real log.
    guard StudyCardQuality.priority(wrong: wrong, correct: correct) != .junk else {
      return false
    }
    return true
  }

  // MARK: - "Fixed:" line parsing
  //
  // `LearningAggregator`'s section/list-marker/tag helpers that this mirrors are all
  // `private` to that file, so they can't be called from here — these are deliberate,
  // narrow copies of that same behavior (list-marker stripping, section-bounded line
  // collection, tag canonicalization), not a reimplementation from scratch. Keep them
  // in sync with `LearningAggregator.swift` if that parsing ever changes.

  /// Non-empty, trimmed lines under "Fixed:" only — mirrors
  /// `LearningAggregator.linesInSection(named: "Fixed:", of:)`.
  private static func fixedLines(in explanation: String) -> [String] {
    let lines = explanation.components(separatedBy: .newlines)
    guard
      let headerIndex = lines.firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces).lowercased() == "fixed:"
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

  /// Drops one leading list marker — mirrors
  /// `LearningAggregator.stripLeadingListMarker` exactly.
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

  /// Consumes every leading `[tag]` group (mirroring
  /// `LearningAggregator.leadingBracketTags`'s loop and its "unknown tag → other"
  /// canonicalization) but keeps only the first as this card's category.
  //
  // ponytail: a line tagged `[article] [verb-tense] "a go" → "the went"` becomes one
  // `article` card rather than two cards sharing the same wrong/correct text under
  // different categories. Fanning out would double-count that single correction in
  // review stats for a case that's rare in the real log. Revisit by returning one
  // BaseCard per tag if multi-tag Fixed lines turn out to be common.
  private static func leadingTag(in line: Substring) -> (tag: String, rest: Substring) {
    var rest = stripLeadingListMarker(line)
    var tag: String?
    while rest.first == "[", let close = rest.firstIndex(of: "]") {
      let raw = String(rest[rest.index(after: rest.startIndex)..<close])
      let canonical = GrammarCategory(rawValue: raw) != nil ? raw : GrammarCategory.other.rawValue
      if tag == nil { tag = canonical }
      rest = rest[rest.index(after: close)...].drop { $0 == " " }
    }
    return (tag ?? GrammarCategory.other.rawValue, rest)
  }

  /// The `"wrong" → "correct"` pair following a (possibly absent) tag prefix.
  /// Mirrors `LearningMetrics.suggestedPhrase`'s arrow/quote handling — same
  /// `→`-then-`->`-fallback arrow lookup, same "quoted text right after" extraction —
  /// but pulls both sides of the arrow instead of only the suggestion. Also returns
  /// everything after the closing quote of `correct`, unparsed, so the caller can pull
  /// a trailing reason out of it without this function needing to know that syntax.
  private static func quotedPair(in text: Substring) -> (
    wrong: String, correct: String, trailing: Substring
  )? {
    guard let wrongOpen = text.firstIndex(of: "\"") else { return nil }
    let afterWrongOpen = text[text.index(after: wrongOpen)...]
    guard let wrongClose = afterWrongOpen.firstIndex(of: "\"") else { return nil }
    let wrong = String(afterWrongOpen[..<wrongClose])

    let afterWrong = afterWrongOpen[afterWrongOpen.index(after: wrongClose)...]
    guard let arrowRange = afterWrong.range(of: "→") ?? afterWrong.range(of: "->") else {
      return nil
    }
    let afterArrow = afterWrong[arrowRange.upperBound...]
    guard let correctOpen = afterArrow.firstIndex(of: "\"") else { return nil }
    let afterCorrectOpen = afterArrow[afterArrow.index(after: correctOpen)...]
    guard let correctClose = afterCorrectOpen.firstIndex(of: "\"") else { return nil }
    let correct = String(afterCorrectOpen[..<correctClose])
    let trailing = afterCorrectOpen[afterCorrectOpen.index(after: correctClose)...]

    return (wrong, correct, trailing)
  }

  /// Strips exactly one leading separator (an em dash `—`, `--`, or a plain `-`) and
  /// surrounding whitespace from the text after the `correct` quote, e.g.
  /// ` — this is the correct preposition for this meaning.` becomes
  /// `"this is the correct preposition for this meaning."`. When `text` carries no
  /// reason at all (nothing but whitespace, or text with no separator), the trimmed
  /// text is returned as-is rather than treated as a parse failure — a line with no
  /// reason must still produce a card, just with `reason == ""`.
  private static func reason(after text: Substring) -> String {
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

  private static func parseFixedLine(_ line: String) -> (
    category: String, wrong: String, correct: String, reason: String
  )? {
    let (tag, rest) = leadingTag(in: Substring(line))
    guard let pair = quotedPair(in: rest) else { return nil }
    return (
      category: tag, wrong: pair.wrong, correct: pair.correct, reason: reason(after: pair.trailing)
    )
  }

  // MARK: - Cloze construction

  /// Locates `wrong` in `original` (newlines collapsed to spaces) case-insensitively
  /// on a word boundary and blanks out its first occurrence. Returns `nil` when
  /// `wrong` can't be found this way — without it, there is no context to build a
  /// cloze from, so the candidate is dropped rather than shown with no blank.
  static func cloze(wrong: String, in original: String) -> (
    sentence: String, promptWithBlank: String
  )? {
    let sentence = collapseWhitespace(original)
    guard let range = firstWholeWordRange(of: wrong, in: sentence) else { return nil }
    var blanked = sentence
    blanked.replaceSubrange(range, with: "_____")
    return (sentence: sentence, promptWithBlank: trimmedAroundBlank(blanked))
  }

  /// Collapses any run of whitespace (including newlines) to a single space and
  /// trims the ends. The learning log's `original` field is a terminal prompt, not a
  /// multi-paragraph essay, so this — rather than real sentence-boundary detection —
  /// is enough to make it readable on one line in a drill.
  private static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// Case-insensitive, word-boundary match range for `phrase` in `text`. Same
  /// `\b...\b` + escaped-pattern approach as `LearningMetrics.containsWholeWord`
  /// (so "on" doesn't match inside "on-call"), including its safe fallback to a plain
  /// substring search when `phrase` can't form a valid regex pattern.
  private static func firstWholeWordRange(of phrase: String, in text: String) -> Range<
    String.Index
  >? {
    let escaped = NSRegularExpression.escapedPattern(for: phrase)
    guard
      let regex = try? NSRegularExpression(
        pattern: "\\b\(escaped)\\b", options: [.caseInsensitive])
    else {
      return text.range(of: phrase, options: .caseInsensitive)
    }
    let nsRange = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else { return nil }
    return Range(match.range, in: text)
  }

  /// Trims `text` to a whole-word window around its `"_____"` blank, aiming for
  /// roughly `maxLength` characters, so a long prompt doesn't push the blank off
  /// screen. Grows outward from the blank one word at a time, alternating sides, and
  /// stops as soon as neither side can grow without busting the budget — keeping the
  /// blank roughly centered without needing anything fancier than string length.
  //
  // ponytail: character-count budget + greedy word growth, not real line-wrapping or
  // clause-boundary awareness. Good enough for a single-line drill prompt; revisit
  // only if trimmed cards start looking awkward in practice.
  static func trimmedAroundBlank(_ text: String, maxLength: Int = 120) -> String {
    guard text.count > maxLength else { return text }
    let words = text.split(separator: " ").map(String.init)
    guard let blankIndex = words.firstIndex(where: { $0.contains("_____") }) else { return text }

    var lo = blankIndex
    var hi = blankIndex
    var window = [words[blankIndex]]
    while true {
      var grew = false
      if lo > 0 {
        let candidate = [words[lo - 1]] + window
        if candidate.joined(separator: " ").count <= maxLength {
          lo -= 1
          window = candidate
          grew = true
        }
      }
      if hi < words.count - 1 {
        let candidate = window + [words[hi + 1]]
        if candidate.joined(separator: " ").count <= maxLength {
          hi += 1
          window = candidate
          grew = true
        }
      }
      if !grew { break }
    }

    let prefix = lo > 0 ? "… " : ""
    let suffix = hi < words.count - 1 ? " …" : ""
    return prefix + window.joined(separator: " ") + suffix
  }

  // MARK: - Choices

  /// Exactly two choices: what the owner actually wrote, and the correction — sorted
  /// alphabetically (case-insensitive) for determinism.
  ///
  /// An earlier version padded this to four by borrowing other same-category cards'
  /// `correct` values as distractors. Run against the real log that produced visibly
  /// broken cards: a blank reading "… such as _____?" was offered "If you have any
  /// questions" and "Update the plan based on the review", both lifted from unrelated
  /// sentences. Because `other` is by far the largest category and is a grab-bag,
  /// "same category" carried no contextual meaning, so the extra options were always
  /// trivially eliminable — the card silently degraded to a two-way pick anyway, just
  /// with noise attached. Presenting the real contrast honestly is both simpler and a
  /// better drill: the skill being trained is noticing your own error next to the
  /// correct form.
  //
  // ponytail: two choices means a 50% blind-guess rate on any single card. The Leitner
  // ladder absorbs that — reaching the top box takes three consecutive correct answers
  // (12.5% by chance), and a wrong answer resets to box 0. Ceiling: if guessing ever
  // looks like it's inflating progress, the upgrade is genuinely plausible distractors
  // (same sentence position, similar length/shape), not more random ones.
  private static func choices(for base: BaseCard) -> [String] {
    [base.wrong, base.correct]
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }
}
