import Foundation
import XCTest

@testable import Bex

final class LearningBadgeTests: XCTestCase {
  // Fixed ISO8601-calendar dates, built from components — never `Date()`.
  private static func isoDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(year: year, month: month, day: day, hour: 12)
    return calendar.date(from: components)!
  }

  /// `count` samples, evenly spread across `count` distinct days starting 2024-01-01,
  /// tagged so `recurringCategoryCount` categories each recur `perCategory` times
  /// (falling back to `[other]` once every canonical tag has been used once — fine
  /// since only the *count* of qualifying categories matters here, not which ones).
  private static func samples(
    count: Int,
    recurringCategoryCount: Int,
    perCategory: Int
  ) -> [LearningSample] {
    let tags = ["article", "verb-tense", "preposition", "spelling", "plural"]
    var explanations: [String] = []
    for categoryIndex in 0..<recurringCategoryCount {
      let tag = tags[categoryIndex % tags.count]
      for _ in 0..<perCategory {
        explanations.append("Fixed:\n[\(tag)] \"a\" → \"b\" — reason.")
      }
    }
    // Pad to `count` with suggestion-only entries: substantive (they carry learning
    // material) but contribute no grammar-category counts, so recurrence stays controlled.
    // Each carries a DISTINCT alternative, because the badge deduplicates by
    // `phrase|alternative` — identical padding would collapse to a count of 1.
    while explanations.count < count {
      let index = explanations.count
      explanations.append("Consider:\n\"x\(index)\" → \"y\(index)\" — reason.")
    }
    return explanations.enumerated().map { index, explanation in
      LearningSample(
        date: isoDate(2024, 1, 1).addingTimeInterval(TimeInterval(index) * 86_400),
        original: "some original text here",
        explanation: explanation
      )
    }
  }

  /// One entry per day starting 2024-01-01, matching `samples(count:...)`.
  private static func spread(_ explanations: [String]) -> [LearningSample] {
    explanations.enumerated().map { index, explanation in
      LearningSample(
        date: isoDate(2024, 1, 1).addingTimeInterval(TimeInterval(index) * 86_400),
        original: "some original text here",
        explanation: explanation
      )
    }
  }

  func testBelowEntryThresholdIsHidden() {
    // 19 entries total, well past the category/recurrence bar — still below 20 entries.
    let samples = Self.samples(count: 19, recurringCategoryCount: 2, perCategory: 3)

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: false, count: 0))
  }

  func testBelowCategoryRecurrenceThresholdIsHidden() {
    // 20 entries, but only 1 category recurs >= 3 times.
    let samples = Self.samples(count: 20, recurringCategoryCount: 1, perCategory: 3)

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: false, count: 0))
  }

  /// 20 entries: 6 grammar fixes (which carry no suggestion) and 14 distinct alternatives.
  /// The badge counts material to review, not entries — see `LearningBadge.status`.
  func testAtThresholdWithNoLastViewedCountsUntappedAlternatives() {
    let samples = Self.samples(count: 20, recurringCategoryCount: 2, perCategory: 3)

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: true, count: 14))
  }

  /// The v7 failure mode this fix exists for: every correction now carries a `Consider`
  /// section, and the same rephrasing recurs across many of them. Counted naively the badge
  /// is permanently lit; deduplicated it says how many decisions are actually waiting.
  func testRepeatedAlternativeCountsOnce() {
    var explanations = [String]()
    for tag in ["article", "verb-tense"] {
      for _ in 0..<3 { explanations.append("Fixed:\n[\(tag)] \"a\" → \"b\" — reason.") }
    }
    while explanations.count < 30 {
      explanations.append("Consider:\n\"plan for fixing\" → \"plan to fix\" — more direct.")
    }
    let samples = Self.spread(explanations)

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: true, count: 1))
  }

  /// A decision already made is not a backlog item. With the only pending alternative
  /// tapped, the badge has nothing left to say and goes dark — the property that makes it
  /// clearable rather than permanent wallpaper.
  func testTappedAlternativesAreNotCounted() {
    var explanations = [String]()
    for tag in ["article", "verb-tense"] {
      for _ in 0..<3 { explanations.append("Fixed:\n[\(tag)] \"a\" → \"b\" — reason.") }
    }
    while explanations.count < 30 {
      explanations.append("Consider:\n\"plan for fixing\" → \"plan to fix\" — more direct.")
    }
    let samples = Self.spread(explanations)

    let status = LearningBadge.status(
      samples: samples, tappedIDs: ["plan for fixing|plan to fix"], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: false, count: 0))
  }

  func testAtThresholdExcludesEntriesOlderThanLastViewed() {
    let samples = Self.samples(count: 20, recurringCategoryCount: 2, perCategory: 3)
    // Entries are one per day starting 2024-01-01; viewing right after day index 14
    // (2024-01-15) should leave the last 5 (indices 15...19) as "new".
    let lastViewedAt = Self.isoDate(2024, 1, 15)

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: lastViewedAt)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: true, count: 5))
  }

  func testAtThresholdButNoNewEntriesSinceLastViewedIsHidden() {
    let samples = Self.samples(count: 20, recurringCategoryCount: 2, perCategory: 3)
    let lastViewedAt = Self.isoDate(2024, 2, 1)  // after every sample date

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: lastViewedAt)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: false, count: 0))
  }

  func testNoOpEntriesDoNotCountTowardActivation() {
    // 6 real corrections (2 categories × 3) satisfy the recurrence bar, but the rest are
    // pure "No changes needed." no-ops. Substantive volume is only 6 (< 20) → hidden.
    var explanations = [String]()
    for tag in ["article", "verb-tense"] {
      for _ in 0..<3 { explanations.append("Fixed:\n[\(tag)] \"a\" → \"b\" — reason.") }
    }
    while explanations.count < 40 { explanations.append("No changes needed.") }
    let samples = explanations.enumerated().map { index, explanation in
      LearningSample(
        date: Self.isoDate(2024, 1, 1).addingTimeInterval(TimeInterval(index) * 86_400),
        original: "some original text here",
        explanation: explanation
      )
    }

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: false, count: 0))
  }

  func testAboveThresholdStillCountsCorrectly() {
    // 30 entries: 15 grammar fixes, 15 distinct alternatives.
    let samples = Self.samples(count: 30, recurringCategoryCount: 3, perCategory: 5)

    let status = LearningBadge.status(samples: samples, tappedIDs: [], lastViewedAt: nil)

    XCTAssertEqual(status, LearningBadge.Status(shouldShow: true, count: 15))
  }
}
