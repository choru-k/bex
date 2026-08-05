import Foundation
import XCTest

@testable import Bex

/// Covers only `StudyNotificationPlan`, the pure decision half of
/// `StudyNotificationScheduler.swift`. The impure half talks to
/// `UNUserNotificationCenter` and is deliberately not unit-tested here — see that
/// file's doc comment for the pure/impure split this repo requires.
final class StudyNotificationSchedulerTests: XCTestCase {
  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private static func isoDate(
    _ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0
  ) -> Date {
    let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    return utcCalendar.date(from: components)!
  }

  // MARK: - content

  func testContentIsNilWhenNothingIsDue() {
    XCTAssertNil(StudyNotificationPlan.content(forDueCount: 0))
  }

  func testContentUsesSingularWordingForOneCard() {
    let content = StudyNotificationPlan.content(forDueCount: 1)
    XCTAssertEqual(content?.body, "1 card due for review")
  }

  func testContentUsesPluralWordingForMultipleCards() {
    let content = StudyNotificationPlan.content(forDueCount: 5)
    XCTAssertEqual(content?.body, "5 cards due for review")
  }

  func testContentIsNilForNegativeDueCount() {
    // Should never happen in practice, but a due count must never produce a
    // notification claiming cards are due when the count isn't positive.
    XCTAssertNil(StudyNotificationPlan.content(forDueCount: -1))
  }

  // MARK: - trigger components

  func testTriggerComponentsUseConfiguredFireHour() {
    let components = StudyNotificationPlan.triggerComponents()
    XCTAssertEqual(components.hour, StudyNotificationPlan.fireHour)
    XCTAssertEqual(components.minute, 0)
    // Only hour/minute are set — no day/month/year — so
    // `UNCalendarNotificationTrigger(repeats: true)` fires this time every day.
    XCTAssertNil(components.day)
    XCTAssertNil(components.month)
    XCTAssertNil(components.year)
  }

  // MARK: - nextFireDate

  func testNextFireDateIsLaterTodayWhenFireHourHasNotPassed() {
    let now = Self.isoDate(2024, 1, 1, hour: 7, minute: 0)

    let next = StudyNotificationPlan.nextFireDate(after: now, calendar: Self.utcCalendar)

    let expected = Self.isoDate(2024, 1, 1, hour: StudyNotificationPlan.fireHour, minute: 0)
    XCTAssertEqual(next, expected)
  }

  func testNextFireDateRollsOverToTomorrowWhenFireHourHasAlreadyPassed() {
    let now = Self.isoDate(2024, 1, 1, hour: 20, minute: 0)

    let next = StudyNotificationPlan.nextFireDate(after: now, calendar: Self.utcCalendar)

    let expected = Self.isoDate(2024, 1, 2, hour: StudyNotificationPlan.fireHour, minute: 0)
    XCTAssertEqual(next, expected)
  }

  func testNextFireDateAtExactlyFireHourRollsOverToTomorrow() {
    // `todayAtFireHour > now` is strict, so landing exactly on the fire hour counts as
    // "already passed" for this call — matching a trigger that just fired.
    let now = Self.isoDate(2024, 1, 1, hour: StudyNotificationPlan.fireHour, minute: 0)

    let next = StudyNotificationPlan.nextFireDate(after: now, calendar: Self.utcCalendar)

    let expected = Self.isoDate(2024, 1, 2, hour: StudyNotificationPlan.fireHour, minute: 0)
    XCTAssertEqual(next, expected)
  }

  func testNextFireDateIsDeterministicUnderAFixedNow() {
    let now = Self.isoDate(2024, 6, 15, hour: 3, minute: 30)

    let first = StudyNotificationPlan.nextFireDate(after: now, calendar: Self.utcCalendar)
    let second = StudyNotificationPlan.nextFireDate(after: now, calendar: Self.utcCalendar)

    XCTAssertEqual(first, second)
  }
}
