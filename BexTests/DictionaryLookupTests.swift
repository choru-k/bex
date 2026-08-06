import Foundation
import XCTest

@testable import Bex

final class DictionaryLookupTests: XCTestCase {
  private let sample = DictionaryLookup(
    english: "postpone",
    korean: "미루다",
    simple: "To move something to a later time.",
    example: "Let's postpone the review until Friday."
  )

  func testParseAcceptsFencedJSONAndTrimsFields() throws {
    let raw = """
      ```json
      {"english": "  postpone ", "korean": "미루다", "simple": "To move something to a later time.", "example": "Let's postpone the review until Friday."}
      ```
      """
    XCTAssertEqual(try DictionaryLookup.parse(raw), sample)
  }

  func testParseRejectsAMissingOrBlankField() {
    let missing = #"{"english": "postpone", "korean": "미루다", "simple": "Later."}"#
    let blank =
      #"{"english": "postpone", "korean": "  ", "simple": "Later.", "example": "Postpone it."}"#
    for raw in [missing, blank, "not json at all"] {
      XCTAssertThrowsError(try DictionaryLookup.parse(raw)) { error in
        XCTAssertEqual(error as? BexError, .invalidResponse)
      }
    }
  }

  /// The whole point of the feature: a saved lookup has to survive the learning-log
  /// round trip and come out the other side as a drillable card. This asserts the log
  /// shape against the real `StudyCardBuilder` rather than against a hand-copied format
  /// string, so a change to either side fails here instead of silently producing zero
  /// vocabulary cards.
  func testSavedLookupBecomesATypedStudyCard() throws {
    let samples = [
      LearningSample(
        date: Date(timeIntervalSince1970: 1_700_000_000),
        original: sample.learningLogOriginal,
        explanation: sample.learningLogExplanation
      )
    ]

    let cards = StudyCardBuilder.cards(from: samples)
    let card = try XCTUnwrap(cards.first)
    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(card.category, GrammarCategory.vocabulary.rawValue)
    XCTAssertEqual(card.wrong, sample.korean)
    XCTAssertEqual(card.correct, sample.english)
    // Typed recall, not a two-button pick — a one-word answer is worth actually typing.
    XCTAssertEqual(card.answerMode, .typed)
    // The Korean term is blanked and the plain-English meaning is the prompt, so the
    // drill asks you to produce the English word.
    XCTAssertFalse(card.promptWithBlank.contains(sample.korean))
    XCTAssertTrue(card.promptWithBlank.contains("_____"))
    XCTAssertTrue(card.promptWithBlank.contains("later time"))
    XCTAssertTrue(card.reason.contains(sample.example))
  }

  /// Vocabulary is a word the owner chose to learn, not a mistake he made — counting it
  /// would inflate the per-100-words error rates the learning gate reads.
  func testVocabularyIsExcludedFromGrammarStatistics() {
    let counts = LearningAggregator.recurringCounts(explanations: [
      sample.learningLogExplanation,
      "Fixed:\n[preposition] \"on\" → \"in\" — this is the right preposition here.",
    ])
    XCTAssertEqual(counts.map(\.category), ["preposition"])
  }
}
