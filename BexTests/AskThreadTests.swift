import Foundation
import XCTest

@testable import Bex

/// Covers the ask thread (design 2a): the answer contract, and the guard that stops a
/// malformed card from entering the deck.
final class AskThreadTests: XCTestCase {
  func testParseTakesTheAnswerAndAnOptionalCard() throws {
    let parsed = try AskAnswer.parse(
      """
      {"answer": "“Check” reads as an instruction; “take a look” reads as an invitation.",
       "card": {"sentence": "Can you check the failing test?", "weaker": "check",
                "better": "take a look at", "note": "softer, less like an order"}}
      """
    )

    XCTAssertTrue(parsed.answer.hasPrefix("“Check” reads as an instruction"))
    XCTAssertEqual(parsed.card?.weaker, "check")
    XCTAssertEqual(parsed.card?.better, "take a look at")
    XCTAssertEqual(parsed.card?.note, "softer, less like an order")
  }

  /// Most questions are not about choosing between two wordings, and the design is explicit
  /// that a wrong card is worse than none — so an answer with no card is the normal case, not
  /// a failure.
  func testAnswerWithoutACardIsValid() throws {
    let parsed = try AskAnswer.parse("{\"answer\": \"Depend always takes 'on'.\"}")
    XCTAssertEqual(parsed.answer, "Depend always takes 'on'.")
    XCTAssertNil(parsed.card)
  }

  /// The card is dropped, not thrown, whenever it could not be drilled. Losing a card the
  /// owner never saw beats failing a question they did ask — and a card whose sentence does
  /// not contain the phrase cannot be clozed at all, so it would be a drill with no blank.
  func testUndrillableCardsAreDroppedWithoutLosingTheAnswer() throws {
    let cases = [
      // sentence does not contain "weaker"
      """
      {"answer": "a", "card": {"sentence": "Nothing relevant here.", "weaker": "check",
       "better": "take a look", "note": ""}}
      """,
      // weaker and better are the same decision
      """
      {"answer": "a", "card": {"sentence": "Can you check it?", "weaker": "check",
       "better": "Check", "note": ""}}
      """,
      // missing fields
      "{\"answer\": \"a\", \"card\": {\"sentence\": \"Can you check it?\"}}",
      // wrong shape entirely
      "{\"answer\": \"a\", \"card\": \"take a look\"}",
    ]

    for raw in cases {
      let parsed = try AskAnswer.parse(raw)
      XCTAssertEqual(parsed.answer, "a")
      XCTAssertNil(parsed.card, "should not have produced a card from: \(raw)")
    }
  }

  /// A substring match would accept "checkout" as containing "check" and produce a card whose
  /// blank lands mid-word.
  func testCardRequiresAWholeWordMatch() throws {
    let parsed = try AskAnswer.parse(
      """
      {"answer": "a", "card": {"sentence": "Run the checkout step first.", "weaker": "check",
       "better": "verify", "note": ""}}
      """
    )
    XCTAssertNil(parsed.card)
  }

  func testParseRejectsAMissingAnswer() {
    XCTAssertThrowsError(try AskAnswer.parse("{\"card\": {}}"))
    XCTAssertThrowsError(try AskAnswer.parse("{\"answer\": \"   \"}"))
    XCTAssertThrowsError(try AskAnswer.parse("not json at all"))
  }

  /// The saved card has to land in exactly the format `StudyCardBuilder` already reads, or it
  /// enters the log and never becomes a drill.
  func testSavedCardIsShapedForTheExistingCardPipeline() {
    let card = AskAnswer.Card(
      sentence: "Can you check the failing test before the release?",
      weaker: "check",
      better: "take a look at",
      note: "softer, less like an order"
    )

    let samples = LearningLogSamples.parse([
      LearningLogStore.Entry(
        timestamp: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000)),
        client: "bex-ask",
        original: card.sentence,
        corrected: card.sentence,
        explanation: card.learningLogExplanation,
        provider: "bex",
        model: "ask"
      )
    ])
    let cards = StudyCardBuilder.cards(from: samples)

    XCTAssertEqual(cards.count, 1)
    XCTAssertEqual(cards.first?.wrong, "check")
    XCTAssertEqual(cards.first?.correct, "take a look at")
    XCTAssertEqual(cards.first?.category, GrammarCategory.expression.rawValue)
    // The cloze must actually have a blank in it, which is the whole reason for the
    // whole-word guard above.
    XCTAssertTrue(cards.first?.promptWithBlank.contains("_____") == true)
  }
}
