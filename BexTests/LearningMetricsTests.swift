import Foundation
import XCTest

@testable import Bex

final class LearningMetricsTests: XCTestCase {
  // Fixed ISO8601-calendar dates, built from components — never `Date()`.
  private static func isoDate(
    _ year: Int, _ month: Int, _ day: Int, hour: Int = 12
  ) -> Date {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(year: year, month: month, day: day, hour: hour)
    return calendar.date(from: components)!
  }

  // MARK: - wordCount

  func testWordCountSplitsOnWhitespaceAndNewlines() {
    XCTAssertEqual(LearningMetrics.wordCount("one two  three\nfour\n\nfive"), 5)
  }

  func testWordCountEmptyStringIsZero() {
    XCTAssertEqual(LearningMetrics.wordCount(""), 0)
    XCTAssertEqual(LearningMetrics.wordCount("   \n  "), 0)
  }

  // MARK: - categoryRates

  func testCategoryRatesComputesRatePer100Words() {
    // 20 words total, "article" tagged twice → 2 / 20 * 100 = 10 per 100 words.
    let samples = [
      LearningSample(
        date: Self.isoDate(2024, 1, 1),
        original: "one two three four five six seven eight nine ten",
        explanation: "Fixed:\n[article] \"a\" → \"the\" — reason."
      ),
      LearningSample(
        date: Self.isoDate(2024, 1, 2),
        original: "one two three four five six seven eight nine ten",
        explanation: "Fixed:\n[article] \"a\" → \"the\" — reason."
      ),
    ]

    let rates = LearningMetrics.categoryRates(samples: samples)
    XCTAssertEqual(rates, [CategoryRate(category: "article", count: 2, ratePer100Words: 10)])
  }

  func testCategoryRatesGuardsDivideByZero() {
    let samples = [
      LearningSample(
        date: Self.isoDate(2024, 1, 1),
        original: "",
        explanation: "Fixed:\n[spelling] \"teh\" → \"the\" — reason."
      )
    ]

    let rates = LearningMetrics.categoryRates(samples: samples)
    XCTAssertEqual(rates, [CategoryRate(category: "spelling", count: 1, ratePer100Words: 0)])
  }

  func testCategoryRatesSortsDescendingByRate() {
    let samples = [
      LearningSample(
        date: Self.isoDate(2024, 1, 1),
        original: "one two three four five six seven eight nine ten",
        explanation: """
          Fixed:
          [preposition] "arrive to" → "arrive at" — reason.
          [spelling] "teh" → "the" — reason.
          [spelling] "adn" → "and" — reason.
          """
      )
    ]

    let rates = LearningMetrics.categoryRates(samples: samples)
    XCTAssertEqual(rates.map(\.category), ["spelling", "preposition"])
    XCTAssertEqual(rates.map(\.ratePer100Words), [20, 10])
  }

  // MARK: - medianSentenceLength

  func testMedianSentenceLengthOddCount() {
    // Sentence word counts: 1, 2, 3 → median 2.
    let originals = ["a. bb cc. ddd eee fff."]
    XCTAssertEqual(LearningMetrics.medianSentenceLength(originals: originals), 2)
  }

  func testMedianSentenceLengthEvenCount() {
    // Sentence word counts: 1, 2, 3, 4 → median (2 + 3) / 2 = 2.5.
    let originals = ["a. bb cc. ddd eee fff. gg hh ii jj."]
    XCTAssertEqual(LearningMetrics.medianSentenceLength(originals: originals), 2.5)
  }

  func testMedianSentenceLengthZeroWhenNoSentences() {
    XCTAssertEqual(LearningMetrics.medianSentenceLength(originals: []), 0)
    XCTAssertEqual(LearningMetrics.medianSentenceLength(originals: ["   ", "..."]), 0)
  }

  // MARK: - weeklyRates

  func testWeeklyRatesBucketsAcrossYearBoundaryAndSortsChronologically() {
    // ISO calendar quirk (verified via Python's isocalendar()): Dec 31 2021 and
    // Jan 1 2022 both fall in ISO week 52 of ISO-year 2021, while Jan 3 2022 is
    // already ISO week 1 of 2022 — a real cross-Gregorian-year, same-ISO-week case.
    let samples = [
      LearningSample(
        date: Self.isoDate(2022, 1, 3),
        original: "seven word original sentence right here today",
        explanation: "Fixed:\n[plural] \"cat\" → \"cats\" — reason."
      ),
      LearningSample(
        date: Self.isoDate(2021, 12, 31),
        original: "three word sample",
        explanation: "Fixed:\n[spelling] \"teh\" → \"the\" — reason."
      ),
      LearningSample(
        date: Self.isoDate(2022, 1, 1),
        original: "one two three four",
        explanation: "No changes needed."
      ),
    ]

    let weeks = LearningMetrics.weeklyRates(samples: samples)

    XCTAssertEqual(weeks.count, 2)
    XCTAssertEqual(weeks[0].yearForWeekOfYear, 2021)
    XCTAssertEqual(weeks[0].weekOfYear, 52)
    XCTAssertEqual(weeks[0].totalWords, 3 + 4)
    // Match the source's exact arithmetic (Double(count) / Double(total) * 100) rather
    // than a re-derived literal, so this isn't sensitive to floating-point rounding.
    let expectedRate = Double(1) / Double(7) * 100
    XCTAssertEqual(
      weeks[0].categoryRates,
      [CategoryRate(category: "spelling", count: 1, ratePer100Words: expectedRate)])

    XCTAssertEqual(weeks[1].yearForWeekOfYear, 2022)
    XCTAssertEqual(weeks[1].weekOfYear, 1)
    XCTAssertEqual(weeks[1].totalWords, 7)
    XCTAssertEqual(
      weeks[1].categoryRates,
      [CategoryRate(category: "plural", count: 1, ratePer100Words: expectedRate)])
  }

  func testWeeklyRatesEmptyForEmptyCorpus() {
    XCTAssertEqual(LearningMetrics.weeklyRates(samples: []), [])
  }
}
