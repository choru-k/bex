import Foundation
import XCTest

@testable import Bex

final class LearningAggregatorTests: XCTestCase {
  // MARK: - parseFixedTags

  func testParseFixedTagsCollectsMultipleCanonicalTags() {
    let explanation = """
      Fixed:
      [article] "go store" → "go to the store" — missing article.
      [verb-tense] "go" → "went" — past tense.

      Consider:
      "I want tell you" → "I want to tell you" — more natural.
      """

    XCTAssertEqual(
      LearningAggregator.parseFixedTags(from: explanation),
      ["article", "verb-tense"]
    )
  }

  func testParseFixedTagsIgnoresConsiderSection() {
    let explanation = """
      Fixed:
      [spelling] "recieve" → "receive" — spelling fix.

      Consider:
      [not-a-tag] "should not be collected" → "..." — reason.
      """

    XCTAssertEqual(LearningAggregator.parseFixedTags(from: explanation), ["spelling"])
  }

  func testParseFixedTagsHandlesNoChangesNeeded() {
    XCTAssertEqual(LearningAggregator.parseFixedTags(from: "No changes needed."), [])
  }

  func testParseFixedTagsBucketsNonCanonicalTagsAsOther() {
    // Drifted tags (e.g. [punctuation]) must still count toward the gate, not vanish.
    let explanation = """
      Fixed:
      [punctuation] "foo" → "bar" — some reason.
      [other] "baz" → "qux" — reason.
      """

    XCTAssertEqual(LearningAggregator.parseFixedTags(from: explanation), ["other", "other"])
  }

  func testParseFixedTagsStripsBulletAndNumberMarkers() {
    let explanation = """
      Fixed:
      - [article] "a report" → "the report" — reason.
      * [spelling] "recieve" → "receive" — reason.
      1. [plural] "two cat" → "two cats" — reason.
      2) [preposition] "arrive to" → "arrive at" — reason.
      """

    XCTAssertEqual(
      LearningAggregator.parseFixedTags(from: explanation),
      ["article", "spelling", "plural", "preposition"]
    )
  }

  func testParseFixedTagsCollectsMultipleTagsOnOneLine() {
    let explanation = """
      Fixed:
      [article] [verb-tense] "a go" → "the went" — combined fix.
      """

    XCTAssertEqual(
      LearningAggregator.parseFixedTags(from: explanation),
      ["article", "verb-tense"]
    )
  }

  func testParseFixedTagsMatchesHeaderCaseInsensitively() {
    let explanation = """
      FIXED:
      [word-order] "always I go" → "I always go" — reason.
      """

    XCTAssertEqual(LearningAggregator.parseFixedTags(from: explanation), ["word-order"])
  }

  func testParseFixedTagsHandlesMissingFixedSection() {
    let explanation = """
      Consider:
      "original" → "suggested" — reason.
      """

    XCTAssertEqual(LearningAggregator.parseFixedTags(from: explanation), [])
  }

  // MARK: - parseConsiderSuggestions

  func testParseConsiderSuggestionsCollectsLines() {
    let explanation = """
      Fixed:
      [preposition] "arrive to" → "arrive at" — wrong preposition.

      Consider:
      "I am agree" → "I agree" — more natural.
      "very good" → "great" — more conversational.
      """

    XCTAssertEqual(
      LearningAggregator.parseConsiderSuggestions(from: explanation),
      [
        "\"I am agree\" → \"I agree\" — more natural.",
        "\"very good\" → \"great\" — more conversational.",
      ]
    )
  }

  func testParseConsiderSuggestionsEmptyWhenSectionOmitted() {
    let explanation = """
      Fixed:
      [plural] "two cat" → "two cats" — plural fix.
      """

    XCTAssertEqual(LearningAggregator.parseConsiderSuggestions(from: explanation), [])
  }

  // MARK: - explanationWithoutConsider

  func testExplanationWithoutConsiderReturnsJustFixedSection() {
    let explanation = """
      Fixed:
      [preposition] "arrive to" → "arrive at" — wrong preposition.

      Consider:
      "I am agree" → "I agree" — more natural.
      """

    XCTAssertEqual(
      LearningAggregator.explanationWithoutConsider(from: explanation),
      "Fixed:\n[preposition] \"arrive to\" → \"arrive at\" — wrong preposition."
    )
  }

  func testExplanationWithoutConsiderEmptyWhenConsiderOnly() {
    let explanation = """
      Consider:
      "I am agree" → "I agree" — more natural.
      """

    XCTAssertEqual(LearningAggregator.explanationWithoutConsider(from: explanation), "")
  }

  func testExplanationWithoutConsiderReturnsWholeExplanationWhenNoConsiderSection() {
    let explanation = """
      Fixed:
      [plural] "two cat" → "two cats" — plural fix.
      """

    XCTAssertEqual(
      LearningAggregator.explanationWithoutConsider(from: explanation),
      "Fixed:\n[plural] \"two cat\" → \"two cats\" — plural fix."
    )
  }

  func testExplanationWithoutConsiderHandlesNoChangesNeeded() {
    XCTAssertEqual(
      LearningAggregator.explanationWithoutConsider(from: "No changes needed."),
      "No changes needed."
    )
  }

  // MARK: - recurringCounts

  func testRecurringCountsBreaksTiesAlphabetically() {
    let explanations = [
      "Fixed:\n[article] \"a\" → \"the\" — reason.",
      "Fixed:\n[verb-tense] \"go\" → \"went\" — reason.",
      "Fixed:\n[verb-tense] \"go\" → \"went\" — reason.\n[article] \"a\" → \"the\" — reason.",
      "No changes needed.",
    ]

    // Both tags recur twice; ties break alphabetically for stable, deterministic output.
    XCTAssertEqual(
      LearningAggregator.recurringCounts(explanations: explanations),
      [
        GrammarCategoryCount(category: "article", count: 2),
        GrammarCategoryCount(category: "verb-tense", count: 2),
      ]
    )
  }

  func testRecurringCountsOrdersHighestFirstWhenCountsDiffer() {
    let explanations = [
      "Fixed:\n[spelling] \"recieve\" → \"receive\" — reason.",
      "Fixed:\n[spelling] \"teh\" → \"the\" — reason.",
      "Fixed:\n[spelling] \"adn\" → \"and\" — reason.",
      "Fixed:\n[preposition] \"arrive to\" → \"arrive at\" — reason.",
    ]

    let counts = LearningAggregator.recurringCounts(explanations: explanations)
    XCTAssertEqual(counts.map(\.category), ["spelling", "preposition"])
    XCTAssertEqual(counts.map(\.count), [3, 1])
  }

  func testRecurringCountsEmptyForEmptyCorpus() {
    XCTAssertEqual(LearningAggregator.recurringCounts(explanations: []), [])
  }
}
