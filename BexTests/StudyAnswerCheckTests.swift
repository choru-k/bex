import Foundation
import XCTest

@testable import Bex

final class StudyAnswerCheckTests: XCTestCase {
  // MARK: - normalize

  func testNormalizeCollapsesInternalWhitespaceRuns() {
    XCTAssertEqual(StudyAnswerCheck.normalize("agreed   with"), "agreed with")
  }

  func testNormalizeTrimsLeadingAndTrailingWhitespace() {
    XCTAssertEqual(StudyAnswerCheck.normalize("  agreed with  "), "agreed with")
  }

  func testNormalizeLowercases() {
    XCTAssertEqual(StudyAnswerCheck.normalize("Agreed With"), "agreed with")
  }

  func testNormalizeStripsLeadingAndTrailingPunctuation() {
    XCTAssertEqual(StudyAnswerCheck.normalize("\"again.\""), "again")
    XCTAssertEqual(StudyAnswerCheck.normalize("links?"), "links")
    XCTAssertEqual(StudyAnswerCheck.normalize("'again'"), "again")
  }

  func testNormalizeStripsCurlyQuotes() {
    XCTAssertEqual(StudyAnswerCheck.normalize("“again”"), "again")
    XCTAssertEqual(StudyAnswerCheck.normalize("‘again’"), "again")
  }

  func testNormalizeDoesNotTouchInternalPunctuationOrWhitespace() {
    // THE CRITICAL CASE: a real card where the entire correction is an internal space
    // before a comma. Collapsing internal whitespace or stripping internal punctuation
    // would destroy the distinction and grade the wrong answer as correct.
    XCTAssertEqual(StudyAnswerCheck.normalize("loop 1-2 , 3 times"), "loop 1-2 , 3 times")
    XCTAssertEqual(StudyAnswerCheck.normalize("loop 1-2, 3 times"), "loop 1-2, 3 times")
    XCTAssertNotEqual(
      StudyAnswerCheck.normalize("loop 1-2 , 3 times"),
      StudyAnswerCheck.normalize("loop 1-2, 3 times")
    )
  }

  // MARK: - matches

  func testMatchesIgnoresCaseWhitespaceAndEdgePunctuation() {
    XCTAssertTrue(StudyAnswerCheck.matches(typed: " Agreed With. ", correct: "agreed with"))
  }

  func testMatchesRejectsDifferentWording() {
    XCTAssertFalse(StudyAnswerCheck.matches(typed: "arrive to", correct: "arrive at"))
  }

  func testMatchesRejectsMissingInternalPunctuationDifference() {
    // THE CRITICAL ONE: the internal space-before-comma difference must survive
    // normalization, so this must NOT match.
    XCTAssertFalse(
      StudyAnswerCheck.matches(typed: "loop 1-2 , 3 times", correct: "loop 1-2, 3 times"))
  }
}
