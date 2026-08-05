import Foundation
import XCTest

@testable import Bex

final class StudyCardTests: XCTestCase {
  // Fixed ISO8601-calendar dates, built from components — never `Date()`.
  private static func isoDate(
    _ year: Int, _ month: Int, _ day: Int, hour: Int = 12
  ) -> Date {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(year: year, month: month, day: day, hour: hour)
    return calendar.date(from: components)!
  }

  // MARK: - Basic construction

  func testBasicCardBuiltFromRealisticFixedLine() {
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "Update the plan based on review before end of day",
      explanation: """
        Fixed:
        [article] "Update the plan based on review" → "Update the plan based on the review" — missing article.
        """
    )

    let cards = StudyCardBuilder.cards(from: [sample])

    XCTAssertEqual(cards.count, 1)
    let card = cards[0]
    XCTAssertEqual(card.category, "article")
    XCTAssertEqual(card.wrong, "Update the plan based on review")
    XCTAssertEqual(card.correct, "Update the plan based on the review")
    XCTAssertEqual(card.sentence, "Update the plan based on review before end of day")
    XCTAssertEqual(card.promptWithBlank, "_____ before end of day")
    XCTAssertEqual(card.displayCategory, "Articles (a, an, the)")
  }

  func testAsciiArrowAndLeadingListMarkerAreParsed() {
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "I agreed on the terms yesterday",
      explanation: """
        Fixed:
        - [preposition] "agreed on" -> "agreed with" — reason.
        """
    )

    let cards = StudyCardBuilder.cards(from: [sample])

    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards[0].category, "preposition")
    XCTAssertEqual(cards[0].wrong, "agreed on")
    XCTAssertEqual(cards[0].correct, "agreed with")
  }

  // MARK: - Stable id

  func testStableIdIsPlainComposedString() {
    // Guards against someone swapping this out for hashValue/UUID: the store that
    // will persist review state keys off this exact string across app launches.
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "the backend team are handling this",
      explanation: """
        Fixed:
        [subject-verb-agreement] "the backend team are" → "the backend team is" — reason.
        """
    )

    let cards = StudyCardBuilder.cards(from: [sample])

    XCTAssertEqual(
      cards.map(\.id),
      ["subject-verb-agreement|the backend team are|the backend team is"]
    )
  }

  // MARK: - Filtering

  func testCaseOnlyDifferenceIsFilteredRegardlessOfTag() {
    // Real example from the log: mis-tagged [other] rather than [capitalization], so
    // this proves the filter is tag-independent.
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "is it possible to finish today",
      explanation: """
        Fixed:
        [other] "is it possible" → "Is it possible" — start with a capital letter.
        """
    )

    XCTAssertEqual(StudyCardBuilder.cards(from: [sample]), [])
  }

  func testNoOpCorrectionIsFiltered() {
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "the meeting starts at noon",
      explanation: """
        Fixed:
        [other] "the meeting starts at noon" → "the meeting starts at noon" — no actual change.
        """
    )

    XCTAssertEqual(StudyCardBuilder.cards(from: [sample]), [])
  }

  func testCapitalizationCategoryIsAlwaysSkippedEvenWithNonCaseChanges() {
    // Differs by more than case (added comma), so the case-insensitive-equality
    // filter alone would not catch this — the explicit category check must.
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "hello world how are you",
      explanation: """
        Fixed:
        [capitalization] "hello world" → "Hello, World" — start with a capital letter.
        """
    )

    XCTAssertEqual(StudyCardBuilder.cards(from: [sample]), [])
  }

  func testPunctuationOnlyDifferenceIsFiltered() {
    // Real example from the log: adding a trailing period teaches nothing about
    // English, and a forgiving typed-mode comparison couldn't grade it anyway (see
    // `StudyCardBuilder.isUsableCandidate`).
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "let's talk about this again",
      explanation: """
        Fixed:
        [other] "again" → "again." — end with a period.
        """
    )

    XCTAssertEqual(StudyCardBuilder.cards(from: [sample]), [])
  }

  func testPunctuationAndCapitalizationComboDifferenceIsFiltered() {
    // "i mean" → "I mean," differs by both case and trailing punctuation — neither
    // alone would necessarily be caught by a naive check, but the normalized
    // comparison catches both at once.
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "i mean it should be fine",
      explanation: """
        Fixed:
        [other] "i mean" → "I mean," — start with a capital letter and add a comma.
        """
    )

    XCTAssertEqual(StudyCardBuilder.cards(from: [sample]), [])
  }

  func testConsiderSectionIgnoredAndNoChangesNeededYieldsNoCards() {
    let noChanges = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "This is fine.",
      explanation: "No changes needed."
    )
    let mixed = LearningSample(
      date: Self.isoDate(2024, 1, 2),
      original: "I go to the store and want tell you something",
      explanation: """
        Fixed:
        [verb-tense] "go" → "went" — reason.

        Consider:
        [other] "want tell" → "want to tell" — should not become a card.
        """
    )

    let cards = StudyCardBuilder.cards(from: [noChanges, mixed])

    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards[0].wrong, "go")
  }

  func testWrongSpanAbsentFromOriginalYieldsNoCard() {
    let sample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "completely unrelated text here",
      explanation: """
        Fixed:
        [preposition] "agreed on" → "agreed with" — reason.
        """
    )

    XCTAssertEqual(StudyCardBuilder.cards(from: [sample]), [])
  }

  // MARK: - Cloze construction

  func testClozeReplacesOnlyFirstOccurrence() {
    let result = StudyCardBuilder.cloze(
      wrong: "agreed on", in: "I agreed on the plan then we agreed on the schedule")

    XCTAssertEqual(
      result?.promptWithBlank,
      "I _____ the plan then we agreed on the schedule"
    )
  }

  func testLongSentenceTrimmingKeepsBlankVisible() {
    let original =
      "In the quarterly review meeting yesterday afternoon the entire backend team are "
      + "handling this particular migration task very carefully together"

    let result = StudyCardBuilder.cloze(wrong: "team are", in: original)

    guard let result else {
      return XCTFail("expected a cloze to be built")
    }
    XCTAssertTrue(result.promptWithBlank.contains("_____"))
    XCTAssertLessThan(result.promptWithBlank.count, result.sentence.count)
    XCTAssertTrue(result.promptWithBlank.contains("…"))
  }

  // MARK: - Choices

  func testChoicesContainCorrectAndWrongDedupedAndDeterministicallyOrdered() {
    let samples = [
      LearningSample(
        date: Self.isoDate(2024, 1, 1),
        original: "I agreed on the terms",
        explanation: "Fixed:\n[preposition] \"agreed on\" → \"agreed with\" — reason."
      ),
      LearningSample(
        date: Self.isoDate(2024, 1, 2),
        original: "we arrived to the venue",
        explanation: "Fixed:\n[preposition] \"arrived to\" → \"arrived at\" — reason."
      ),
      LearningSample(
        date: Self.isoDate(2024, 1, 3),
        original: "she waited on the bus",
        explanation: "Fixed:\n[preposition] \"waited on\" → \"waited for\" — reason."
      ),
    ]

    let cards = StudyCardBuilder.cards(from: samples)

    XCTAssertEqual(cards.count, 3)
    let first = cards[0]
    XCTAssertTrue(first.choices.contains(first.wrong))
    XCTAssertTrue(first.choices.contains(first.correct))
    XCTAssertEqual(Set(first.choices).count, first.choices.count, "choices must be deduped")
    // Exactly the real contrast — what was written vs the correction — in deterministic
    // alphabetical order. Text from other cards must never leak in as a distractor:
    // against the real log those were always from unrelated sentences and therefore
    // trivially eliminable (see `StudyCardBuilder.choices`).
    XCTAssertEqual(first.choices, ["agreed on", "agreed with"])
  }

  func testChoicesNeverBorrowFromOtherCards() {
    let samples = [
      LearningSample(
        date: Self.isoDate(2024, 1, 1),
        original: "I agreed on the terms",
        explanation: "Fixed:\n[preposition] \"agreed on\" → \"agreed with\" — reason."
      ),
      LearningSample(
        date: Self.isoDate(2024, 1, 2),
        original: "she waited on the bus",
        explanation: "Fixed:\n[preposition] \"waited on\" → \"waited for\" — reason."
      ),
    ]

    let cards = StudyCardBuilder.cards(from: samples)
    let first = cards.first { $0.wrong == "agreed on" }!

    XCTAssertEqual(first.choices, ["agreed on", "agreed with"])
    XCTAssertFalse(first.choices.contains("waited for"))
    XCTAssertFalse(first.choices.contains("waited on"))
  }

  // MARK: - Answer mode

  func testShortCorrectAnswerIsTypedMode() {
    XCTAssertEqual(StudyCardBuilder.answerMode(for: "agreed with"), .typed)
  }

  func testSevenWordCorrectAnswerIsChoicesMode() {
    XCTAssertEqual(
      StudyCardBuilder.answerMode(for: "one two three four five six seven"), .choices)
  }

  func testExactlyFourWordsIsStillTypedMode() {
    XCTAssertEqual(StudyCardBuilder.answerMode(for: "one two three four"), .typed)
  }

  func testFourWordsButOverCharacterBudgetIsChoicesMode() {
    // 4 words, 43 characters — over `typedMaxCharacters` (40), so this must fall back
    // to choices despite satisfying the word-count threshold alone.
    let correct = "aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd"
    XCTAssertEqual(correct.count, 43)
    XCTAssertEqual(StudyCardBuilder.answerMode(for: correct), .choices)
  }

  func testCardBuiltEndToEndCarriesAnswerMode() {
    let typedSample = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "I agreed on the terms yesterday",
      explanation: """
        Fixed:
        [preposition] "agreed on" → "agreed with" — reason.
        """
    )
    let choicesSample = LearningSample(
      date: Self.isoDate(2024, 1, 2),
      original: "please update the plan document sometime soon so we can proceed",
      explanation: """
        Fixed:
        [other] "update the plan document sometime soon" → "please update the plan document at your earliest convenience" — too casual.
        """
    )

    let typedCards = StudyCardBuilder.cards(from: [typedSample])
    let choicesCards = StudyCardBuilder.cards(from: [choicesSample])

    XCTAssertEqual(typedCards.first?.answerMode, .typed)
    XCTAssertEqual(choicesCards.first?.answerMode, .choices)
  }

  // MARK: - Dedup by id

  func testDedupByIdKeepsFirstOccurrence() {
    let first = LearningSample(
      date: Self.isoDate(2024, 1, 1),
      original: "the backend team are handling this today",
      explanation: """
        Fixed:
        [subject-verb-agreement] "the backend team are" → "the backend team is" — reason.
        """
    )
    let duplicate = LearningSample(
      date: Self.isoDate(2024, 1, 2),
      original: "the backend team are working hard again",
      explanation: """
        Fixed:
        [subject-verb-agreement] "the backend team are" → "the backend team is" — reason.
        """
    )

    let cards = StudyCardBuilder.cards(from: [first, duplicate])

    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards[0].sentence, "the backend team are handling this today")
  }
}
