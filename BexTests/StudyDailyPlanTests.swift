import Foundation
import XCTest

@testable import Bex

final class StudyDailyPlanTests: XCTestCase {
  private let dayInSeconds: TimeInterval = 86_400

  /// A fixed `Calendar` with an explicit `TimeZone`, per the "next calendar day" tests'
  /// requirement to not depend on the machine's local time zone.
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }()

  /// 9am and 9am-the-next-day in the fixed time zone above — unambiguously different
  /// calendar days, and far enough from midnight to be robust to any DST edge case.
  private func day(_ dayOffset: Int) -> Date {
    var components = DateComponents()
    components.year = 2024
    components.month = 1
    components.day = 15 + dayOffset
    components.hour = 9
    return calendar.date(from: components)!
  }

  private func card(_ id: String, priority: StudyCardPriority = .high) -> StudyCard {
    StudyCard(
      id: id,
      category: "article",
      wrong: "a",
      correct: "the",
      reason: "reason",
      sentence: "I saw a dog.",
      promptWithBlank: "I saw _____ dog.",
      choices: ["a", "the"],
      answerMode: .typed,
      priority: priority
    )
  }

  private func cards(_ count: Int) -> [StudyCard] {
    (0..<count).map { card("card\($0)") }
  }

  // MARK: - Cold start

  /// THE headline behaviour: a 120-card deck with zero review history must not present
  /// all 120 at once — only `dailyNewCardLimit` enter rotation today.
  func testColdStartCapsAtDailyNewCardLimitNotTheWholeDeck() {
    let plan = StudyDailyPlan.plan(
      cards: cards(120), states: [:], now: day(0), calendar: calendar)

    XCTAssertEqual(plan.cardIDs.count, StudyDailyPlan.dailyNewCardLimit)
    XCTAssertEqual(plan.cardIDs.count, 10)
    XCTAssertEqual(plan.newCount, 10)
    XCTAssertEqual(plan.reviewCount, 0)
  }

  /// Oldest mistakes come first: `cards` is oldest-log-entry-first, so the first
  /// `dailyNewCardLimit` ids taken must be exactly the first `dailyNewCardLimit` cards
  /// in that order.
  func testColdStartTakesTheOldestCardsFirst() {
    let deck = cards(120)
    let plan = StudyDailyPlan.plan(cards: deck, states: [:], now: day(0), calendar: calendar)

    XCTAssertEqual(plan.cardIDs, deck.prefix(10).map(\.id))
  }

  // MARK: - Same-day re-plan does not add more

  func testRePlanningSameDayAfterIntroducingLimitAddsNoMoreNewCards() {
    let deck = cards(120)
    let now = day(0)
    // Simulate: the first 10 cards were already introduced earlier today.
    var states: [String: StudyReviewState] = [:]
    for card in deck.prefix(10) {
      states[card.id] = StudyReviewState(
        box: 0, dueAt: now.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: now)
    }

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)

    XCTAssertEqual(plan.newCount, 0)
    // Those 10 aren't due yet either (dueAt is tomorrow), so nothing at all is planned.
    XCTAssertEqual(plan.cardIDs.count, 0)
  }

  // MARK: - Next calendar day resets intake

  func testNextCalendarDayResetsIntakeAndAllowsMoreNewCards() {
    let deck = cards(120)
    let today = day(0)
    let tomorrow = day(1)
    var states: [String: StudyReviewState] = [:]
    for card in deck.prefix(10) {
      states[card.id] = StudyReviewState(
        box: 0, dueAt: today.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: today)
    }

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: tomorrow, calendar: calendar)

    // The 10 introduced "today" (yesterday, relative to `tomorrow`) are now due (their
    // dueAt is exactly `tomorrow`), so they show up as reviews, and 10 fresh new cards
    // become available on top of them.
    XCTAssertEqual(plan.reviewCount, 10)
    XCTAssertEqual(plan.newCount, 10)
    XCTAssertEqual(plan.cardIDs.count, 20)
  }

  // MARK: - Reviews always included

  func testDueReviewsAreAlwaysIncludedEvenWhenNewIntakeIsExhausted() {
    let deck = cards(130)
    let now = day(0)
    var states: [String: StudyReviewState] = [:]
    // 10 cards already introduced today (exhausts today's new intake)...
    for card in deck.prefix(10) {
      states[card.id] = StudyReviewState(
        box: 0, dueAt: now.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: now)
    }
    // ...plus 5 older in-rotation cards that are due right now.
    let dueReviewCards = Array(deck[10..<15])
    for card in dueReviewCards {
      states[card.id] = StudyReviewState(
        box: 1, dueAt: now.addingTimeInterval(-dayInSeconds), timesSeen: 2, timesCorrect: 1,
        firstSeenAt: now.addingTimeInterval(-10 * dayInSeconds))
    }

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)

    XCTAssertEqual(plan.reviewCount, 5)
    XCTAssertEqual(plan.newCount, 0)
    XCTAssertEqual(Set(plan.cardIDs), Set(dueReviewCards.map(\.id)))
  }

  // MARK: - Legacy nil firstSeenAt

  func testLegacyStateWithNilFirstSeenAtDoesNotConsumeTodaysIntake() {
    let deck = cards(120)
    let now = day(0)
    var states: [String: StudyReviewState] = [:]
    // 10 cards already in rotation, not due, with no recorded firstSeenAt — as if
    // written before this field existed.
    for card in deck.prefix(10) {
      states[card.id] = StudyReviewState(
        box: 0, dueAt: now.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: nil)
    }

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)

    // None of those legacy cards count toward today's intake, so the full daily limit
    // of NEW cards is still available (from the remaining 110 never-touched cards).
    XCTAssertEqual(plan.newCount, StudyDailyPlan.dailyNewCardLimit)
  }

  // MARK: - Ordering

  func testOrderingReviewsBeforeNewAndNewFollowsCardsOrder() {
    let deck = cards(20)
    let now = day(0)
    // Make the LAST card in `deck` a due review, so a naive "cards order" pass-through
    // (rather than reviews-first) would misplace it.
    let reviewCard = deck.last!
    let states: [String: StudyReviewState] = [
      reviewCard.id: StudyReviewState(
        box: 1, dueAt: now.addingTimeInterval(-dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: now.addingTimeInterval(-dayInSeconds))
    ]

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)

    XCTAssertEqual(plan.cardIDs.first, reviewCard.id)
    // The remaining new cards follow `cards` order (excluding the review card).
    let expectedNew = deck.filter { $0.id != reviewCard.id }.prefix(StudyDailyPlan.dailyNewCardLimit)
    XCTAssertEqual(Array(plan.cardIDs.dropFirst()), expectedNew.map(\.id))
  }

  // MARK: - maxOverdueDays

  func testMaxOverdueDaysIsZeroWhenNothingOverdue() {
    let deck = cards(1)
    let now = day(0)
    let states: [String: StudyReviewState] = [
      deck[0].id: StudyReviewState(box: 0, dueAt: now, timesSeen: 1, timesCorrect: 1, firstSeenAt: now)
    ]

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)
    XCTAssertEqual(plan.maxOverdueDays, 0)
  }

  func testMaxOverdueDaysReflectsWorstLateReview() {
    let deck = cards(2)
    let now = day(3)
    let states: [String: StudyReviewState] = [
      deck[0].id: StudyReviewState(
        box: 0, dueAt: day(0), timesSeen: 1, timesCorrect: 1, firstSeenAt: day(0)),
      deck[1].id: StudyReviewState(
        box: 0, dueAt: day(2), timesSeen: 1, timesCorrect: 1, firstSeenAt: day(2)),
    ]

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)
    XCTAssertEqual(plan.maxOverdueDays, 3)
  }

  /// New cards never contribute to `maxOverdueDays` — a plan with only new intake and
  /// no reviews reads as perfectly on schedule.
  func testMaxOverdueDaysIsZeroForNewOnlyPlan() {
    let plan = StudyDailyPlan.plan(cards: cards(5), states: [:], now: day(0), calendar: calendar)
    XCTAssertEqual(plan.maxOverdueDays, 0)
  }

  // MARK: - Empty inputs

  func testEmptyCardsAndStatesYieldsEmptyPlan() {
    let plan = StudyDailyPlan.plan(cards: [], states: [:], now: day(0), calendar: calendar)
    XCTAssertEqual(plan.cardIDs, [])
    XCTAssertEqual(plan.reviewCount, 0)
    XCTAssertEqual(plan.newCount, 0)
    XCTAssertEqual(plan.maxOverdueDays, 0)
  }
}
