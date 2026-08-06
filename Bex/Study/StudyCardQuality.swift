import Foundation

/// How much a correction is worth drilling. Ordered, so new-card intake can simply
/// prefer the higher tier (`StudyDailyPlan`).
enum StudyCardPriority: Int, Comparable, Sendable {
  /// Not worth drilling at all — these never become cards. See `StudyCardQuality`.
  case junk = 0
  /// Drillable, but goes last: single-word morphology whose answer is obvious once the
  /// blank is read (`"sub agent"` → `"sub agents"`).
  case low = 1
  /// Phrase-level structure — articles, prepositions, word order, agreement, rephrasing.
  /// The mistakes that actually make speech sound broken.
  case high = 2

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Decides whether a logged correction is worth drilling, and in what order.
///
/// Every rule here was written against the owner's real learning log (152 candidate
/// corrections at the time) because the failure mode was not theoretical: he opened the
/// deck and got `"cluade"` → `"Claude"`, `"yes. but"` → `"Yes, but"`, and `"?"` →
/// `"1063\"`. Those are keystrokes and parse debris, not English, and they crowded out
/// the cards worth his attention.
///
/// Measured on that log (109 entries, 152 parsed corrections): these rules classify 35 as
/// `junk` — 20 typos, 14 punctuation-only, 1 letterless — and the deck that survives every
/// filter is 111 cards, 97 `high` and 14 `low`. The visible effect is the first ten cards
/// of a cold start: prepositions, word order, and subject-verb agreement, where before it
/// was `"cluade"` → `"Claude"`.
///
/// This is the same argument as the `capitalization` exclusion in `LearningAggregator`
/// and `StudyCardBuilder.isUsableCandidate`, applied one level deeper: a terminal-prompt
/// corpus is full of mistakes the owner would never make while speaking.
///
/// Pure — no clock, no RNG, no I/O — so a fixed correction always classifies the same.
enum StudyCardQuality {
  /// Lowercase-letters-only edit distance at or below which a single-word "correction"
  /// may be read as a keyboard slip rather than a spelling gap. 2 covers the whole real
  /// pattern — transpositions (`fisrt`/`first`), dropped letters (`chec`/`check`,
  /// `pressue`/`pressure`), doubled letters (`compoenent`/`component`) — while leaving
  /// genuine word-form errors alone (`techincal` → `technically`, distance 4).
  static let typoEditDistance = 2

  static func priority(wrong: String, correct: String) -> StudyCardPriority {
    guard containsLetter(wrong), containsLetter(correct) else { return .junk }
    // Punctuation-only diffs, including *internal* ones that `StudyAnswerCheck.normalize`
    // deliberately preserves: `"yes. but"` → `"Yes, but"`, `"bug. maybe"` → `"bug? Maybe"`,
    // `"use-case"` → `"use case"`. Comma-vs-period in a terminal prompt is punctuation
    // habit, and nothing about English is learned by retyping it.
    guard punctuationStripped(wrong) != punctuationStripped(correct) else { return .junk }
    // Before the typo rule, because a plural `s` is also a one-character edit: `"PR"` →
    // `"PRs"` is a real (if easy) lesson, not a slip, and belongs in `.low` rather than
    // thrown away.
    if differsOnlyByPlural(wrong: wrong, correct: correct) { return .low }
    if isTypo(wrong: wrong, correct: correct) { return .junk }
    return .high
  }

  // MARK: - Rules

  /// Whether this looks like a keyboard slip rather than an English mistake: one word on
  /// each side, a small edit distance, **and** one word's letters contained in the
  /// other's as a multiset — i.e. the edits are insertions, deletions, or transpositions
  /// of letters the owner already typed.
  ///
  /// That containment condition is what makes the rule safe, and it was added after
  /// distance alone broke real cards. Short function words are the most common genuine
  /// corrections in this corpus and they sit at distance 1–2 from each other: `"on"` →
  /// `"in"`, `"at"` → `"to"`, `"a"` → `"the"`, `"does"` → `"did"`, `"go"` → `"went"`.
  /// None of those hold letters in common the way a misspelling does, so containment
  /// keeps them while still dropping all 20 typos in the real log.
  //
  // ponytail: a letter-shape heuristic, not a dictionary. `NSSpellChecker` would judge
  // "is this a real word" directly, but it is main-thread AppKit state and would make
  // this classifier non-deterministic to test. Two survivors on the real log are
  // mis-parses rather than typos (`"frm"` → `"now"`, `"qe"` → `"do we"` — debris from one
  // mangled prompt); reach for a dictionary only if that class grows.
  private static func isTypo(wrong: String, correct: String) -> Bool {
    guard wrong.split(whereSeparator: \.isWhitespace).count == 1,
      correct.split(whereSeparator: \.isWhitespace).count == 1
    else { return false }
    let wrongLetters = letters(wrong)
    let correctLetters = letters(correct)
    guard editDistance(wrongLetters, correctLetters) <= typoEditDistance else { return false }
    return contains(wrongLetters, correctLetters) || contains(correctLetters, wrongLetters)
  }

  /// Whether every letter of `subset` appears in `superset` at least as many times.
  private static func contains(_ superset: [Character], _ subset: [Character]) -> Bool {
    var available: [Character: Int] = [:]
    for character in superset { available[character, default: 0] += 1 }
    for character in subset {
      guard let remaining = available[character], remaining > 0 else { return false }
      available[character] = remaining - 1
    }
    return true
  }

  /// Whether the two sides differ *only* by adding or removing a plural `s`/`es` on one
  /// or more words — `"3 sonnet sub agent"` → `"3 sonnet sub agents"`, `"PR"` → `"PRs"`,
  /// `"it show"` → `"it shows"`. The owner named this class himself as low priority: the
  /// blank's surrounding words already give the answer away, so the card costs a tap and
  /// teaches nothing new. Kept rather than dropped because Korean does not mark plurals
  /// and these still recur — they just belong behind the structural cards.
  private static func differsOnlyByPlural(wrong: String, correct: String) -> Bool {
    let wrongWords = punctuationStripped(wrong).split(separator: " ")
    let correctWords = punctuationStripped(correct).split(separator: " ")
    guard wrongWords.count == correctWords.count else { return false }
    var sawDifference = false
    for (wrongWord, correctWord) in zip(wrongWords, correctWords) where wrongWord != correctWord {
      sawDifference = true
      guard isPluralOf(wrongWord, correctWord) || isPluralOf(correctWord, wrongWord) else {
        return false
      }
    }
    return sawDifference
  }

  private static func isPluralOf(_ plural: Substring, _ singular: Substring) -> Bool {
    plural == singular + "s" || plural == singular + "es"
  }

  // MARK: - Text helpers

  private static func containsLetter(_ text: String) -> Bool {
    text.contains { $0.isLetter }
  }

  /// Lowercased, with every punctuation or symbol character replaced by a space and
  /// whitespace runs collapsed. Symbols are included so `">"` in `"General Settings >
  /// Tap"` is treated like the punctuation it is.
  private static func punctuationStripped(_ text: String) -> String {
    let spaced = text.map { character in
      character.isPunctuation || character.isSymbol ? " " : Character(character.lowercased())
    }
    return String(spaced).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func letters(_ text: String) -> [Character] {
    text.lowercased().filter(\.isLetter)
  }

  /// Levenshtein distance, two rows rather than a full matrix. Only ever called on
  /// single words here, so the O(n·m) work is a few dozen comparisons.
  private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
    if lhs.isEmpty { return rhs.count }
    if rhs.isEmpty { return lhs.count }
    var previous = Array(0...rhs.count)
    var current = previous
    for (lhsIndex, lhsCharacter) in lhs.enumerated() {
      current[0] = lhsIndex + 1
      for (rhsIndex, rhsCharacter) in rhs.enumerated() {
        let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
        current[rhsIndex + 1] = min(previous[rhsIndex + 1] + 1, current[rhsIndex] + 1, substitution)
      }
      swap(&previous, &current)
    }
    return previous[rhs.count]
  }
}
