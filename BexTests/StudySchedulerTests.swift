import Foundation
import XCTest

@testable import Bex

final class StudySchedulerTests: XCTestCase {
  private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
  private let dayInSeconds: TimeInterval = 86_400

  /// `XCTAssertEqual(_:_:accuracy:)` requires `FloatingPoint`, which `Date` isn't —
  /// compare via `timeIntervalSince1970` instead, with enough slack for floating-point
  /// drift across the additions in `StudyScheduler`.
  private func assertDates(
    _ lhs: Date, _ rhs: Date, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      lhs.timeIntervalSince1970, rhs.timeIntervalSince1970, accuracy: 0.001, file: file, line: line)
  }

  // MARK: - isDue

  func testCardWithNoStateIsAlwaysDue() {
    XCTAssertTrue(StudyScheduler.isDue(nil, now: fixedNow))
  }

  func testIsDueBoundaryDueAtExactlyNowCountsAsDue() {
    let state = StudyReviewState(box: 0, dueAt: fixedNow, timesSeen: 1, timesCorrect: 1)
    XCTAssertTrue(StudyScheduler.isDue(state, now: fixedNow))
  }

  func testIsDueFalseWhenDueAtInFuture() {
    let state = StudyReviewState(
      box: 0, dueAt: fixedNow.addingTimeInterval(1), timesSeen: 1, timesCorrect: 1)
    XCTAssertFalse(StudyScheduler.isDue(state, now: fixedNow))
  }

  func testIsDueTrueWhenDueAtInPast() {
    let state = StudyReviewState(
      box: 0, dueAt: fixedNow.addingTimeInterval(-1), timesSeen: 1, timesCorrect: 1)
    XCTAssertTrue(StudyScheduler.isDue(state, now: fixedNow))
  }

  // MARK: - advance: new card

  func testAdvanceFromNilCorrectCreatesBoxOneWithOneSeen() {
    let result = StudyScheduler.advance(nil, correct: true, now: fixedNow)
    XCTAssertEqual(result.box, 1)
    XCTAssertEqual(result.timesSeen, 1)
    XCTAssertEqual(result.timesCorrect, 1)
    assertDates(result.dueAt, fixedNow.addingTimeInterval(3 * dayInSeconds))
  }

  func testAdvanceFromNilWrongStaysBoxZeroWithOneSeenZeroCorrect() {
    let result = StudyScheduler.advance(nil, correct: false, now: fixedNow)
    XCTAssertEqual(result.box, 0)
    XCTAssertEqual(result.timesSeen, 1)
    XCTAssertEqual(result.timesCorrect, 0)
    assertDates(result.dueAt, fixedNow.addingTimeInterval(dayInSeconds))
  }

  // MARK: - advance: correct promotes through every interval

  func testCorrectAnswerPromotesThroughEachIntervalInOrder() {
    // A brand-new card starts at box 0. Each successive correct answer promotes it
    // one box, so the Nth correct answer (1-indexed) lands it in box N with
    // `intervalDays[N]`'s due date — box 0 itself is never revisited once a card has
    // been answered correctly at least once.
    var state: StudyReviewState?

    for expectedBox in 1..<StudyScheduler.intervalDays.count {
      state = StudyScheduler.advance(state, correct: true, now: fixedNow)
      XCTAssertEqual(state?.box, expectedBox)
      assertDates(
        state!.dueAt,
        fixedNow.addingTimeInterval(Double(StudyScheduler.intervalDays[expectedBox]) * dayInSeconds)
      )
    }
  }

  func testCorrectAnswerAtTopBoxClampsAndDoesNotCrash() {
    let topBoxState = StudyReviewState(
      box: StudyScheduler.intervalDays.count - 1,
      dueAt: fixedNow,
      timesSeen: 10,
      timesCorrect: 9
    )
    let result = StudyScheduler.advance(topBoxState, correct: true, now: fixedNow)
    XCTAssertEqual(result.box, StudyScheduler.intervalDays.count - 1)
    assertDates(
      result.dueAt,
      fixedNow.addingTimeInterval(Double(StudyScheduler.intervalDays.last!) * dayInSeconds)
    )
    XCTAssertEqual(result.timesSeen, 11)
    XCTAssertEqual(result.timesCorrect, 10)
  }

  // MARK: - advance: wrong resets

  func testWrongAnswerResetsBoxToZeroAndOneDayDueRegardlessOfPriorBox() {
    let highBoxState = StudyReviewState(
      box: StudyScheduler.intervalDays.count - 1,
      dueAt: fixedNow,
      timesSeen: 5,
      timesCorrect: 5
    )
    let result = StudyScheduler.advance(highBoxState, correct: false, now: fixedNow)
    XCTAssertEqual(result.box, 0)
    assertDates(result.dueAt, fixedNow.addingTimeInterval(dayInSeconds))
    XCTAssertEqual(result.timesSeen, 6)
    XCTAssertEqual(result.timesCorrect, 5)
  }

  func testWrongAnswerAlwaysIncrementsTimesSeenNeverTimesCorrect() {
    let state = StudyReviewState(box: 2, dueAt: fixedNow, timesSeen: 3, timesCorrect: 2)
    let result = StudyScheduler.advance(state, correct: false, now: fixedNow)
    XCTAssertEqual(result.timesSeen, 4)
    XCTAssertEqual(result.timesCorrect, 2)
  }

  // MARK: - dueCards

  func testDueCardsPreservesInputOrderAndFiltersNonDue() {
    let due = StudyReviewState(
      box: 0, dueAt: fixedNow.addingTimeInterval(-1), timesSeen: 1, timesCorrect: 0)
    let notDue = StudyReviewState(
      box: 0, dueAt: fixedNow.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1)
    let states: [String: StudyReviewState] = [
      "b": due,
      "c": notDue,
    ]
    // "a" has no state at all, so it must always be due.
    let result = StudyScheduler.dueCards(ids: ["c", "a", "b"], states: states, now: fixedNow)
    XCTAssertEqual(result, ["a", "b"])
  }

  func testDueCardsReturnsEmptyWhenNothingIsDue() {
    let notDue = StudyReviewState(
      box: 0, dueAt: fixedNow.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1)
    let result = StudyScheduler.dueCards(
      ids: ["x"], states: ["x": notDue], now: fixedNow)
    XCTAssertEqual(result, [])
  }
}
