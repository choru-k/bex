import Foundation
import XCTest

@testable import Bex

final class StudyDueCountTests: XCTestCase {
  private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
  private let dayInSeconds: TimeInterval = 86_400

  private func card(_ id: String) -> StudyCard {
    StudyCard(
      id: id,
      category: "other",
      wrong: "a",
      correct: "the",
      reason: "reason",
      sentence: "I saw a dog.",
      promptWithBlank: "I saw _____ dog.",
      choices: ["a", "the"],
      answerMode: .typed,
      priority: .high
    )
  }

  // MARK: - count

  func testCountMixesNewOverdueAndFutureScheduledCards() {
    let cards = [card("new"), card("overdue"), card("future")]
    let states: [String: StudyReviewState] = [
      "overdue": StudyReviewState(
        box: 0, dueAt: fixedNow.addingTimeInterval(-dayInSeconds), timesSeen: 1, timesCorrect: 0),
      "future": StudyReviewState(
        box: 1, dueAt: fixedNow.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1),
      // "new" has no entry at all, matching `StudyScheduler.isDue`'s "never studied is
      // always due" rule.
    ]

    let count = StudyDueCount.count(cards: cards, states: states, now: fixedNow)

    // "new" and "overdue" are due; "future" is not.
    XCTAssertEqual(count, 2)
  }

  func testCountIsZeroWhenNothingIsDue() {
    let cards = [card("a")]
    let states: [String: StudyReviewState] = [
      "a": StudyReviewState(
        box: 1, dueAt: fixedNow.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1)
    ]

    XCTAssertEqual(StudyDueCount.count(cards: cards, states: states, now: fixedNow), 0)
  }

  // MARK: - badge precedence

  func testStudyDueWinsOverLearningStatus() {
    let badge = StudyDueCount.badge(
      studyDue: 3,
      learning: LearningBadge.Status(shouldShow: true, count: 20)
    )

    XCTAssertTrue(badge.isVisible)
    XCTAssertEqual(badge.text, "3")
    XCTAssertEqual(badge.accessibilityLabel, "Bex — 3 cards due for review")
  }

  func testStudyDueSingularWording() {
    let badge = StudyDueCount.badge(
      studyDue: 1,
      learning: LearningBadge.Status(shouldShow: true, count: 20)
    )

    XCTAssertEqual(badge.text, "1")
    XCTAssertEqual(badge.accessibilityLabel, "Bex — 1 card due for review")
  }

  func testZeroStudyDueFallsBackToLearningStatus() {
    let badge = StudyDueCount.badge(
      studyDue: 0,
      learning: LearningBadge.Status(shouldShow: true, count: 5)
    )

    XCTAssertTrue(badge.isVisible)
    XCTAssertEqual(badge.text, "5")
    XCTAssertEqual(badge.accessibilityLabel, "Bex — 5 new corrections to review")
  }

  func testBothZeroHidesTheBadge() {
    let badge = StudyDueCount.badge(
      studyDue: 0,
      learning: LearningBadge.Status(shouldShow: false, count: 0)
    )

    XCTAssertFalse(badge.isVisible)
    XCTAssertEqual(badge.text, "")
  }

  // MARK: - severity

  /// 0 overdue days is the ordinary case — including a perfectly normal, non-empty
  /// daily batch — and must read as `.normal`, not escalate just because there's
  /// something to do today.
  func testSeverityNormalWhenNothingOverdue() {
    XCTAssertEqual(StudyDueCount.severity(maxOverdueDays: 0), .normal)
  }

  func testSeverityBehindAtOneOverdueDay() {
    XCTAssertEqual(StudyDueCount.severity(maxOverdueDays: 1), .behind)
  }

  func testSeverityLateAtTwoOverdueDays() {
    XCTAssertEqual(StudyDueCount.severity(maxOverdueDays: 2), .late)
  }

  func testSeverityLateAtFiveOverdueDays() {
    XCTAssertEqual(StudyDueCount.severity(maxOverdueDays: 5), .late)
  }
}
