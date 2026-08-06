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
      category: "other",
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
  /// all 120 at once — only `newCardBatchSize` enter rotation today.
  func testColdStartCapsAtDailyNewCardLimitNotTheWholeDeck() {
    let plan = StudyDailyPlan.plan(
      cards: cards(120), states: [:], now: day(0), calendar: calendar)

    XCTAssertEqual(plan.cardIDs.count, StudyDailyPlan.newCardBatchSize)
    XCTAssertEqual(plan.cardIDs.count, 10)
    XCTAssertEqual(plan.newCount, 10)
    XCTAssertEqual(plan.reviewCount, 0)
  }

  /// Oldest mistakes come first: `cards` is oldest-log-entry-first, so the first
  /// `newCardBatchSize` ids taken must be exactly the first `newCardBatchSize` cards
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

  // MARK: - Hourly refill

  /// The behaviour the owner asked for after clearing his first batch: finishing ten
  /// should not lock the door until tomorrow.
  func testFinishingABatchRefillsAfterTheRefillInterval() {
    let deck = cards(120)
    let finishedAt = day(0)
    var states: [String: StudyReviewState] = [:]
    for card in deck.prefix(10) {
      states[card.id] = StudyReviewState(
        box: 1, dueAt: finishedAt.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: finishedAt)
    }

    // Immediately after: nothing new, the batch is spent (and none of the ten are due).
    let rightAfter = StudyDailyPlan.plan(
      cards: deck, states: states, now: finishedAt.addingTimeInterval(60), calendar: calendar)
    XCTAssertEqual(rightAfter.newCount, 0)
    XCTAssertEqual(rightAfter.cardIDs, [])

    // One minute before the interval elapses: still spent.
    let justBefore = StudyDailyPlan.plan(
      cards: deck, states: states,
      now: finishedAt.addingTimeInterval(StudyDailyPlan.newCardRefillInterval - 60),
      calendar: calendar)
    XCTAssertEqual(justBefore.newCount, 0)

    // Once the interval has passed, a fresh full batch is on offer — and it is a batch,
    // not the rest of the deck.
    let afterRefill = StudyDailyPlan.plan(
      cards: deck, states: states,
      now: finishedAt.addingTimeInterval(StudyDailyPlan.newCardRefillInterval + 1),
      calendar: calendar)
    XCTAssertEqual(afterRefill.newCount, StudyDailyPlan.newCardBatchSize)
    XCTAssertEqual(afterRefill.reviewCount, 0)
    XCTAssertFalse(afterRefill.cardIDs.contains(where: { states[$0] != nil }))
  }

  /// A partly-finished batch does not refill early: three cards in, seven are on offer,
  /// and that stays seven until the first three age out.
  func testPartialBatchOffersOnlyTheRemainingSlots() {
    let deck = cards(120)
    let now = day(0)
    var states: [String: StudyReviewState] = [:]
    for card in deck.prefix(3) {
      states[card.id] = StudyReviewState(
        box: 1, dueAt: now.addingTimeInterval(dayInSeconds), timesSeen: 1, timesCorrect: 1,
        firstSeenAt: now.addingTimeInterval(-60))
    }

    let plan = StudyDailyPlan.plan(cards: deck, states: states, now: now, calendar: calendar)

    XCTAssertEqual(plan.newCount, StudyDailyPlan.newCardBatchSize - 3)
  }

  // MARK: - One card per pattern

  private func card(_ id: String, category: String) -> StudyCard {
    StudyCard(
      id: id, category: category, wrong: "a", correct: "the", reason: "reason",
      sentence: "I saw a dog.", promptWithBlank: "I saw _____ dog.", choices: ["a", "the"],
      answerMode: .typed, priority: .high)
  }

  /// The real complaint this solves: 34 of the owner's cards are the same determiner rule,
  /// so an unfiltered batch spent six of ten slots re-teaching one lesson.
  func testBatchTakesOnlyOneCardPerPattern() {
    let deck = (0..<20).map { card("determiner\($0)", category: "article") }

    let plan = StudyDailyPlan.plan(cards: deck, states: [:], now: day(0), calendar: calendar)

    XCTAssertEqual(plan.cardIDs, ["determiner0"])
  }

  /// ...but a batch of distinct lessons still fills up. Every card here is groupable, so
  /// this also pins that grouping never withholds a card whose pattern is unused.
  func testBatchFillsWithDistinctPatterns() {
    let categories = [
      "article", "preposition", "word-order", "plural", "subject-verb-agreement", "verb-tense",
    ]
    let deck = categories.enumerated().map { index, category in
      card("card\(index)", category: category)
    }

    let plan = StudyDailyPlan.plan(cards: deck, states: [:], now: day(0), calendar: calendar)

    XCTAssertEqual(plan.cardIDs.count, categories.count)
  }

  /// A model-assigned pattern overrides the `GrammarCategory` fallback. These two cards
  /// carry different tags — so the tag fallback would let both through — but the
  /// classifier found they teach the same rule, and only one may appear.
  func testAssignedPatternsOverrideTheCategoryFallback() {
    let deck = [
      card("tagged-other", category: "other"),
      card("tagged-spelling", category: "spelling"),
    ]
    let patterns: [String: StudyPattern] = [
      "tagged-other": .phrasing,
      "tagged-spelling": .phrasing,
    ]

    let plan = StudyDailyPlan.plan(
      cards: deck, states: [:], now: day(0), calendar: calendar, patterns: patterns)

    XCTAssertEqual(plan.cardIDs, ["tagged-other"])
  }

  /// A card the classifier examined and found no rule for goes behind every real lesson.
  /// Without this, those cards (12 on the real deck, mostly fragments of mangled prompts)
  /// filled 6 of 10 slots, because being exempt from grouping means nothing limits how
  /// many can appear.
  func testCardsTheClassifierFoundNoRuleForAreDrilledLast() {
    let deck = [
      card("no-rule", category: "other"),
      card("real-lesson", category: "other"),
    ]
    let patterns: [String: StudyPattern] = [
      "no-rule": .unclassified,
      "real-lesson": .phrasing,
    ]

    let plan = StudyDailyPlan.plan(
      cards: deck, states: [:], now: day(0), calendar: calendar, patterns: patterns)

    XCTAssertEqual(plan.cardIDs, ["real-lesson", "no-rule"])
  }

  /// ...but "not classified yet" is not the same claim as "no rule applies". An absent
  /// assignment must not be penalized, or the entire deck sits at the back until the
  /// background pass has run.
  func testUnclassifiedCardsAreNotPenalizedBeforeTheClassifierRuns() {
    let deck = [
      card("not-yet-classified", category: "other"),
      card("known-lesson", category: "article"),
    ]

    let plan = StudyDailyPlan.plan(
      cards: deck, states: [:], now: day(0), calendar: calendar, patterns: [:])

    XCTAssertEqual(plan.cardIDs, ["not-yet-classified", "known-lesson"])
  }

  /// Unclassified cards are never held back — otherwise the whole untagged remainder of
  /// the deck (43 of 139 cards before the classifier runs) would count as one lesson and
  /// starve the batch to a single card.
  func testUnclassifiedCardsAreNotGrouped() {
    let deck = (0..<20).map { card("unknown\($0)", category: "other") }

    let plan = StudyDailyPlan.plan(cards: deck, states: [:], now: day(0), calendar: calendar)

    XCTAssertEqual(plan.cardIDs.count, StudyDailyPlan.newCardBatchSize)
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

    // None of those legacy cards count against the current batch, so the full batch
    // of NEW cards is still available (from the remaining 110 never-touched cards).
    XCTAssertEqual(plan.newCount, StudyDailyPlan.newCardBatchSize)
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
    let expectedNew = deck.filter { $0.id != reviewCard.id }.prefix(StudyDailyPlan.newCardBatchSize)
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
