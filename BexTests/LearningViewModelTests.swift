import Foundation
import XCTest

@testable import Bex

@MainActor
final class LearningViewModelTests: XCTestCase {
  private func makeStore() -> (
    store: LearningLogStore, taps: ConsiderTapStore, cleanUp: () -> Void
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LearningViewModelTests-\(UUID().uuidString)", isDirectory: true)
    let store = LearningLogStore(directoryURL: directory)
    let taps = ConsiderTapStore(directoryURL: directory)
    return (store, taps, { try? FileManager.default.removeItem(at: directory) })
  }

  func testLoadIsEmptyWhenLogHasNoEntries() async {
    let (store, taps, cleanUp) = makeStore()
    defer { cleanUp() }
    let viewModel = LearningViewModel(learningLog: store, considerTaps: taps)

    XCTAssertTrue(viewModel.isLoading)
    await viewModel.load()

    XCTAssertFalse(viewModel.isLoading)
    XCTAssertTrue(viewModel.isEmpty)
    XCTAssertEqual(viewModel.recurringMistakes, [])
    XCTAssertEqual(viewModel.suggestions, [])
  }

  func testLoadAggregatesRecurringMistakesAndRecentSuggestions() async {
    let (store, taps, cleanUp) = makeStore()
    defer { cleanUp() }

    await store.append(
      client: "claude-code",
      original: "he go store",
      corrected: "He went to the store.",
      explanation: """
        Fixed:
        [verb-tense] "go" → "went" — past tense.
        [article] "store" → "the store" — missing article.

        Consider:
        "he go" → "he went" — more natural.
        """,
      provider: "openai",
      model: "gpt-5.6-sol"
    )
    await store.append(
      client: "codex",
      original: "she go home",
      corrected: "She went home.",
      explanation: """
        Fixed:
        [verb-tense] "go" → "went" — past tense.
        """,
      provider: "openai",
      model: "gpt-5.6-sol"
    )

    let viewModel = LearningViewModel(learningLog: store, considerTaps: taps)
    await viewModel.load()

    XCTAssertFalse(viewModel.isEmpty)
    XCTAssertEqual(
      viewModel.recurringMistakes,
      [
        GrammarCategoryCount(category: "verb-tense", count: 2),
        GrammarCategoryCount(category: "article", count: 1),
      ]
    )
    XCTAssertEqual(viewModel.suggestions.map(\.phrase), ["he go"])
    XCTAssertEqual(viewModel.suggestions.map(\.alternative), ["he went"])
    XCTAssertEqual(viewModel.suggestions.map(\.reason), ["more natural."])
    XCTAssertEqual(viewModel.suggestions.map(\.isTapped), [false])
    // The source text has to survive the parse — without it `StudyCardBuilder` has no
    // sentence to blank the phrase inside, so the tap could never become a card.
    XCTAssertEqual(viewModel.suggestions.map(\.sourceOriginal), ["he go store"])
  }

  func testLoadComputesMetricsFromParsedSamples() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LearningViewModelTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let store = LearningLogStore(directoryURL: directory, now: { fixedNow })
    let taps = ConsiderTapStore(directoryURL: directory)

    await store.append(
      client: "claude-code",
      original: "he go store yesterday to buy food",
      corrected: "He went to the store yesterday to buy food.",
      explanation: """
        Fixed:
        [verb-tense] "go" → "went" — past tense.

        Consider:
        "he go" → "he went" — more natural.
        """,
      provider: "openai",
      model: "gpt-5.6-sol"
    )

    let viewModel = LearningViewModel(learningLog: store, considerTaps: taps)
    await viewModel.load()

    XCTAssertEqual(viewModel.categoryRates.map(\.category), ["verb-tense"])
    XCTAssertEqual(viewModel.categoryRates.first?.count, 1)
    XCTAssertGreaterThan(viewModel.medianSentenceLength, 0)
    XCTAssertEqual(viewModel.weeklyRates.count, 1)
    XCTAssertEqual(viewModel.uptakeSuggested, 1)
    XCTAssertEqual(viewModel.uptakeAdopted, 0)
  }
}
