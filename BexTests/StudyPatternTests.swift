import Foundation
import XCTest

@testable import Bex

final class StudyPatternTests: XCTestCase {
  private func card(_ id: String, wrong: String, correct: String, category: String = "other")
    -> StudyCard
  {
    StudyCard(
      id: id, category: category, wrong: wrong, correct: correct, reason: "",
      sentence: "\(wrong) here.", promptWithBlank: "_____ here.", choices: [wrong, correct],
      answerMode: .typed, priority: .high)
  }

  // MARK: - Category fallback

  /// Until the classifier has run, the tag stands in. Tags that describe no lesson —
  /// `other` and `spelling` — must fall to `unclassified`, or the whole untagged remainder
  /// of the deck would group as one lesson.
  func testCategoryFallbackMapsLessonTagsAndDropsTheRest() {
    XCTAssertEqual(StudyPattern.fromCategory("article"), .determiner)
    XCTAssertEqual(StudyPattern.fromCategory("plural"), .countability)
    XCTAssertEqual(StudyPattern.fromCategory("preposition"), .preposition)
    XCTAssertEqual(StudyPattern.fromCategory("vocabulary"), .vocabulary)
    XCTAssertEqual(StudyPattern.fromCategory("other"), .unclassified)
    XCTAssertEqual(StudyPattern.fromCategory("spelling"), .unclassified)
    XCTAssertEqual(StudyPattern.fromCategory("capitalization"), .unclassified)
    XCTAssertEqual(StudyPattern.fromCategory("nonsense-tag"), .unclassified)
  }

  func testOnlyUnclassifiedIsExemptFromGrouping() {
    for pattern in StudyPattern.allCases where pattern != .unclassified {
      XCTAssertTrue(pattern.groupsCards, "\(pattern.rawValue) should group")
    }
    XCTAssertFalse(StudyPattern.unclassified.groupsCards)
  }

  // MARK: - Request shape

  /// Only the correction pair is sent — never the surrounding sentence, which is the
  /// owner's own prompt text.
  func testClassificationMessageIsANumberedListOfPairsOnly() {
    let cards = [
      card("1", wrong: "has bad format", correct: "has a bad format"),
      card("2", wrong: "I am prefering", correct: "I prefer"),
    ]

    let message = StudyPattern.classificationMessage(for: cards)

    XCTAssertEqual(
      message,
      """
      1. has bad format -> has a bad format
      2. I am prefering -> I prefer
      """)
    XCTAssertFalse(message.contains("here."))
  }

  // MARK: - Response parsing

  func testParseMapsNumbersBackOntoCardIDs() throws {
    let cards = [
      card("card-a", wrong: "has bad format", correct: "has a bad format"),
      card("card-b", wrong: "I am prefering", correct: "I prefer"),
    ]

    let parsed = try StudyPattern.parseClassification(
      #"{"1": "determiner", "2": "stative-progressive"}"#, for: cards)

    XCTAssertEqual(parsed, ["card-a": .determiner, "card-b": .stativeProgressive])
  }

  /// A wrong label silently regroups a card, so anything the vocabulary does not contain
  /// becomes `unclassified` rather than being coerced to the nearest name.
  func testUnknownMissingAndBlankLabelsBecomeUnclassified() throws {
    let cards = [
      card("known", wrong: "has bad format", correct: "has a bad format"),
      card("invented", wrong: "a", correct: "b"),
      card("absent", wrong: "c", correct: "d"),
    ]

    let parsed = try StudyPattern.parseClassification(
      #"{"1": "DETERMINER", "2": "article-omission"}"#, for: cards)

    XCTAssertEqual(parsed["known"], .determiner, "labels are matched case-insensitively")
    XCTAssertEqual(parsed["invented"], .unclassified)
    XCTAssertEqual(parsed["absent"], .unclassified)
  }

  func testNonJSONResponseThrows() {
    let cards = [card("card-a", wrong: "a", correct: "b")]

    XCTAssertThrowsError(try StudyPattern.parseClassification("sorry, I can't", for: cards))
  }
}
