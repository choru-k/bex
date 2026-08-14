import Foundation
import XCTest

@testable import Bex

/// Covers the contract that tapping a "Consider" alternative records the owner's pick and
/// turns it into a Study card.
@MainActor
final class ConsiderTapTests: XCTestCase {
  private func makeStores() -> (
    log: LearningLogStore, taps: ConsiderTapStore, state: StudyStateStore, cleanUp: () -> Void
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ConsiderTapTests-\(UUID().uuidString)", isDirectory: true)
    return (
      LearningLogStore(directoryURL: directory),
      ConsiderTapStore(directoryURL: directory),
      StudyStateStore(directoryURL: directory),
      { try? FileManager.default.removeItem(at: directory) }
    )
  }

  /// One correction whose `Consider` section has two unranked alternatives plus the
  /// closing prose line — the exact shape `GrammarPrompts` emits since v7.
  private func appendSuggestion(to store: LearningLogStore) async {
    await store.append(
      client: "claude-code",
      original: "What is your plan for fixing this issue?",
      corrected: "What is your plan for fixing this issue?",
      explanation: """
        Consider:
        "plan for fixing" → "plan to fix" — more direct, focuses on the intention.
        "plan for fixing" → "approach to fixing" — leans on the method instead.
        Which fits? The original already reads as asking about method.
        """,
      provider: "openai",
      model: "gpt-5.6-sol"
    )
  }

  // MARK: - Line parsing

  func testParseSuggestionLineExtractsBothSidesAndReason() {
    let parsed = LearningAggregator.parseSuggestionLine(
      "\"plan for fixing\" → \"plan to fix\" — more direct.")
    XCTAssertEqual(parsed?.phrase, "plan for fixing")
    XCTAssertEqual(parsed?.alternative, "plan to fix")
    XCTAssertEqual(parsed?.reason, "more direct.")
  }

  func testParseSuggestionLineToleratesAsciiArrowAndMissingReason() {
    let parsed = LearningAggregator.parseSuggestionLine("\"very good\" -> \"great\"")
    XCTAssertEqual(parsed?.phrase, "very good")
    XCTAssertEqual(parsed?.alternative, "great")
    XCTAssertEqual(parsed?.reason, "")
  }

  /// The closing prose line is not an alternative. It must drop out here rather than be
  /// special-cased by every caller — see `parseSuggestionLine`'s doc comment.
  func testParseSuggestionLineRejectsProseAndHalfLines() {
    XCTAssertNil(
      LearningAggregator.parseSuggestionLine("Which fits? The original already reads fine."))
    XCTAssertNil(LearningAggregator.parseSuggestionLine("\"only one side\" → no quotes after"))
    XCTAssertNil(LearningAggregator.parseSuggestionLine("no arrow here at all"))
  }

  // MARK: - Store

  func testRecordIsIdempotentPerPhraseAndAlternative() async {
    let (_, taps, _, cleanUp) = makeStores()
    defer { cleanUp() }

    await taps.record(
      sourceOriginal: "a b c", phrase: "a", alternative: "b", reason: "first")
    await taps.record(
      sourceOriginal: "different sentence", phrase: "a", alternative: "b", reason: "second")

    let recorded = await taps.taps()
    XCTAssertEqual(recorded.count, 1)
    // The FIRST tap wins: re-tapping must not restamp the timestamp, or the card would
    // jump the queue in `StudyDailyPlan`'s oldest-first intake every time it's re-tapped.
    XCTAssertEqual(recorded.first?.reason, "first")
    let ids = await taps.tappedIDs()
    XCTAssertEqual(ids, ["a|b"])
  }

  // MARK: - Merge ordering

  func testMergedInterleavesTapsWithLogEntriesByDate() {
    let entry = LearningLogStore.Entry(
      timestamp: "2026-08-01T00:00:00Z", client: "claude-code", original: "old",
      corrected: "old", explanation: "Fixed:\n[other] \"a\" → \"b\" — x.",
      provider: "openai", model: "m")
    let earlierTap = ConsiderTap(
      timestamp: "2026-07-01T00:00:00Z", sourceOriginal: "earlier", phrase: "p",
      alternative: "q", reason: "")

    let merged = LearningLogSamples.merged([entry], taps: [earlierTap])

    // Sorted, not appended: a tap older than the log's newest entry belongs before it, or
    // every chosen expression parks behind the whole backlog.
    XCTAssertEqual(merged.map(\.original), ["earlier", "old"])
  }

  // MARK: - End to end

  func testTappingASuggestionMakesItAStudyCard() async {
    let (log, taps, state, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendSuggestion(to: log)

    let learning = LearningViewModel(learningLog: log, considerTaps: taps)
    await learning.load()

    // Two alternatives are offered and neither is marked as chosen — v7 forbids ranking,
    // so the owner picking one is the only thing that can create a "correct" side.
    XCTAssertEqual(learning.suggestions.map(\.alternative), ["plan to fix", "approach to fixing"])
    XCTAssertEqual(learning.uptakeSuggested, 2)
    XCTAssertEqual(learning.uptakeAdopted, 0)

    guard let chosen = learning.suggestions.first else { return XCTFail("no suggestions") }
    await learning.chooseSuggestion(chosen)

    XCTAssertTrue(learning.suggestions[0].isTapped)
    XCTAssertFalse(learning.suggestions[1].isTapped)
    XCTAssertEqual(learning.uptakeAdopted, 1)

    let study = StudyViewModel(learningLog: log, considerTaps: taps, studyState: state)
    await study.load()

    // The tap is now a drill: the chosen wording is the answer, the owner's original
    // wording is the distractor, and the blank sits in the sentence he actually wrote.
    XCTAssertEqual(study.currentCard?.category, GrammarCategory.expression.rawValue)
    XCTAssertEqual(study.currentCard?.correct, "plan to fix")
    XCTAssertEqual(study.currentCard?.wrong, "plan for fixing")
    XCTAssertEqual(
      study.currentCard?.promptWithBlank, "What is your _____ this issue?")
  }

  /// A tap is a choice made while reviewing, not text the owner wrote. Counting it in the
  /// per-100-words denominators would dilute the error rates the Learning window exists to
  /// show, so `LearningMetrics` must never see taps.
  func testTapsDoNotEnterTheGrammarStatistics() async {
    let (log, taps, _, cleanUp) = makeStores()
    defer { cleanUp() }
    await appendSuggestion(to: log)

    let learning = LearningViewModel(learningLog: log, considerTaps: taps)
    await learning.load()
    guard let chosen = learning.suggestions.first else { return XCTFail("no suggestions") }
    await learning.chooseSuggestion(chosen)

    let before = learning.medianSentenceLength
    await learning.load()

    XCTAssertEqual(learning.medianSentenceLength, before)
    XCTAssertFalse(
      learning.categoryRates.map(\.category).contains(GrammarCategory.expression.rawValue))
  }
}
