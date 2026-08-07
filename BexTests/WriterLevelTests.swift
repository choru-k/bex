import Foundation
import XCTest

@testable import Bex

/// Covers v7.1 decision 2 (docs/learning-mode-plan.md): the accumulated level profile that
/// lets the correction prompt tell a typo from a genuine gap.
final class WriterLevelTests: XCTestCase {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func profile(
    daysAgo: Double, sampleCount: Int, summary: String = "Reliable on tenses."
  ) -> WriterLevelProfile {
    WriterLevelProfile(
      generatedAt: ISO8601DateFormatter().string(
        from: now.addingTimeInterval(-daysAgo * 24 * 60 * 60)),
      summary: summary,
      sampleCount: sampleCount
    )
  }

  // MARK: - Refresh policy

  func testNeverProfiledWaitsForEnoughMaterial() {
    XCTAssertFalse(
      WriterLevelRefresh.shouldRefresh(current: nil, correctionCount: 9, now: Self.now))
    XCTAssertTrue(
      WriterLevelRefresh.shouldRefresh(current: nil, correctionCount: 10, now: Self.now))
  }

  /// Both conditions must hold. A profile summarizing months of writing does not change
  /// because two more corrections landed, and re-asking a provider to restate the same
  /// paragraph is pure cost.
  func testRefreshNeedsBothNewMaterialAndAge() {
    let current = Self.profile(daysAgo: 30, sampleCount: 100)
    XCTAssertFalse(
      WriterLevelRefresh.shouldRefresh(current: current, correctionCount: 105, now: Self.now),
      "old enough, but only 5 new corrections")

    let fresh = Self.profile(daysAgo: 0.5, sampleCount: 100)
    XCTAssertFalse(
      WriterLevelRefresh.shouldRefresh(current: fresh, correctionCount: 200, now: Self.now),
      "plenty of new material, but generated hours ago")

    XCTAssertTrue(
      WriterLevelRefresh.shouldRefresh(current: current, correctionCount: 200, now: Self.now))
  }

  /// A profile whose timestamp cannot be parsed is not trustworthy state to skip on.
  func testUnparseableTimestampForcesRefresh() {
    let broken = WriterLevelProfile(
      generatedAt: "not a date", summary: "x", sampleCount: 100)
    XCTAssertTrue(
      WriterLevelRefresh.shouldRefresh(current: broken, correctionCount: 200, now: Self.now))
  }

  // MARK: - Corpus

  /// Suggestion-only entries carry no evidence of a mistake, so they are not level signal.
  /// The `Consider` half is stripped from the rest for the same reason.
  func testProfilingMessageUsesOnlyCorrections() {
    let samples = [
      LearningSample(
        date: Self.now, original: "he go store",
        explanation: "Fixed:\n[verb-tense] \"go\" → \"went\" — past tense.\n\nConsider:\n\"he go\" → \"he headed out\" — livelier."),
      LearningSample(
        date: Self.now, original: "already perfect",
        explanation: "Consider:\n\"a\" → \"b\" — reason."),
    ]

    let message = WriterLevelProfile.profilingMessage(samples: samples)

    XCTAssertTrue(message.contains("he go store"))
    XCTAssertTrue(message.contains("[verb-tense]"))
    XCTAssertFalse(message.contains("already perfect"))
    XCTAssertFalse(message.contains("livelier"))
  }

  /// The fix for what the first real profile got wrong: it named articles and plurals as
  /// this writer's top gaps, which is true but useless — those are corrected silently and
  /// never explained, so the profile was spending a third of its 80 words on something the
  /// writer will never be shown.
  func testProfilingMessageDropsSilentlyCorrectedTags() {
    let samples = [
      LearningSample(
        date: Self.now, original: "check status of PR and add it into sprint",
        explanation: """
          Fixed:
          [article] "check status" → "check the status" — needs an article.
          [plural] "PR" → "PRs" — plural.
          [capitalization] "check" → "Check" — sentence start.
          [preposition] "add it into" → "add it to" — wrong preposition.
          """),
      LearningSample(
        date: Self.now, original: "these PR are merged",
        explanation: "Fixed:\n[plural] \"PR\" → \"PRs\" — plural."),
    ]

    let message = WriterLevelProfile.profilingMessage(samples: samples)

    XCTAssertTrue(message.contains("add it into"), "teachable gaps must survive")
    for dropped in ["check the status", "\"PR\" → \"PRs\"", "sentence start"] {
      XCTAssertFalse(message.contains(dropped), "\(dropped) should have been filtered out")
    }
    // The second sample had nothing left after filtering, so it contributes no context at
    // all rather than an original with an empty Fixed section.
    XCTAssertFalse(message.contains("these PR are merged"))
  }

  func testProfilingMessageIsEmptyWithoutCorrections() {
    let samples = [
      LearningSample(date: Self.now, original: "fine", explanation: "No changes needed."),
      // Article-only: real, but unteachable, so it leaves nothing to profile from.
      LearningSample(
        date: Self.now, original: "make commit",
        explanation: "Fixed:\n[article] \"make commit\" → \"make a commit\" — needs an article."),
    ]
    XCTAssertTrue(WriterLevelProfile.profilingMessage(samples: samples).isEmpty)
  }

  // MARK: - Prompt injection

  func testWriterLevelIsAppendedToBothPrompts() {
    let summary = "Reliable on articles. Still misses perfect tenses."

    let quickCheck = GrammarPrompts.buildSystemPrompt(
      profilePrompt: nil, writerLevel: summary)
    let promptGate = GrammarPrompts.buildPromptSafeSystem(writerLevel: summary)

    for prompt in [quickCheck, promptGate] {
      XCTAssertTrue(prompt.contains(summary))
      // The model must not repeat the profile back at the owner or treat it as a licence
      // to skip a real correction.
      XCTAssertTrue(prompt.contains("never mention it"))
    }
    // The base rules survive injection.
    XCTAssertTrue(promptGate.contains("BEX_PROTECTED_"))
  }

  func testAbsentOrBlankWriterLevelLeavesPromptsUnchanged() {
    XCTAssertEqual(
      GrammarPrompts.buildSystemPrompt(profilePrompt: nil, writerLevel: nil),
      GrammarPrompts.system)
    XCTAssertEqual(
      GrammarPrompts.buildSystemPrompt(profilePrompt: nil, writerLevel: "   "),
      GrammarPrompts.system)
    XCTAssertEqual(
      GrammarPrompts.buildPromptSafeSystem(writerLevel: nil),
      GrammarPrompts.promptSafeSystem)
  }

  func testProfilePromptAndWriterLevelCoexist() {
    let prompt = GrammarPrompts.buildSystemPrompt(
      profilePrompt: "Keep it casual.", writerLevel: "Reliable on articles.")

    XCTAssertTrue(prompt.contains("Keep it casual."))
    XCTAssertTrue(prompt.contains("Reliable on articles."))
  }

  // MARK: - Store

  func testStoreRoundTripsAndCachesAbsence() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("WriterLevelTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WriterLevelStore(directoryURL: directory)

    let empty = await store.summary()
    XCTAssertNil(empty)

    await store.store(Self.profile(daysAgo: 0, sampleCount: 42, summary: "Knows tenses."))
    let summary = await store.summary()
    XCTAssertEqual(summary, "Knows tenses.")

    let reread = await WriterLevelStore(directoryURL: directory).current()
    XCTAssertEqual(reread?.sampleCount, 42)
  }

  func testParseRejectsEmptySummary() {
    XCTAssertThrowsError(
      try WriterLevelProfile.parse("{\"summary\": \"  \"}", generatedAt: Self.now, sampleCount: 1))
    XCTAssertThrowsError(
      try WriterLevelProfile.parse("not json", generatedAt: Self.now, sampleCount: 1))
  }
}
