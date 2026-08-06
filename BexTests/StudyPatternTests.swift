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

  /// The rendered card is sent, blank included: whether the blank is answerable is most of
  /// what the model is asked to judge, and it cannot see that from the pair alone.
  func testClassificationMessageCarriesTheRenderedCard() {
    let cards = [
      card("1", wrong: "has bad format", correct: "has a bad format"),
      card("2", wrong: "I am prefering", correct: "I prefer"),
    ]

    let message = StudyPattern.classificationMessage(for: cards)

    XCTAssertEqual(
      message,
      """
      1. CARD: _____ here.
         ANSWER: has a bad format
         HE WROTE: has bad format
      2. CARD: _____ here.
         ANSWER: I prefer
         HE WROTE: I am prefering
      """)
  }

  // MARK: - Response parsing

  func testParseMapsNumbersBackOntoCardIDs() throws {
    let cards = [
      card("card-a", wrong: "has bad format", correct: "has a bad format"),
      card("card-b", wrong: "I am prefering", correct: "I prefer"),
    ]

    let parsed = try StudyPattern.parseClassification(
      #"{"1": {"drill": false, "pattern": "determiner"}, "2": {"drill": true, "pattern": "stative-progressive"}}"#, for: cards)

    XCTAssertEqual(parsed["card-a"]?.pattern, .determiner)
    XCTAssertEqual(parsed["card-b"]?.pattern, .stativeProgressive)
    XCTAssertEqual(parsed["card-a"]?.isDrillable, false, "articles are not drillable")
    XCTAssertEqual(parsed["card-b"]?.isDrillable, true)
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
      #"{"1": {"drill": true, "pattern": "DETERMINER"}, "2": {"drill": true, "pattern": "article-omission"}}"#, for: cards)

    XCTAssertEqual(parsed["known"]?.pattern, .determiner, "labels are matched case-insensitively")
    XCTAssertEqual(parsed["invented"]?.pattern, .unclassified)
    XCTAssertEqual(parsed["absent"]?.pattern, .unclassified)
    XCTAssertEqual(
      parsed["absent"]?.isDrillable, true,
      "a missing verdict must not silently delete a card")
  }

  func testNonJSONResponseThrows() {
    let cards = [card("card-a", wrong: "a", correct: "b")]

    XCTAssertThrowsError(try StudyPattern.parseClassification("sorry, I can't", for: cards))
  }
}
