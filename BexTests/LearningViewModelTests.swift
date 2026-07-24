import Foundation
import XCTest

@testable import Bex

@MainActor
final class LearningViewModelTests: XCTestCase {
  private func makeStore() -> (store: LearningLogStore, cleanUp: () -> Void) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LearningViewModelTests-\(UUID().uuidString)", isDirectory: true)
    let store = LearningLogStore(directoryURL: directory)
    return (store, { try? FileManager.default.removeItem(at: directory) })
  }

  func testLoadIsEmptyWhenLogHasNoEntries() async {
    let (store, cleanUp) = makeStore()
    defer { cleanUp() }
    let viewModel = LearningViewModel(learningLog: store)

    XCTAssertTrue(viewModel.isLoading)
    await viewModel.load()

    XCTAssertFalse(viewModel.isLoading)
    XCTAssertTrue(viewModel.isEmpty)
    XCTAssertEqual(viewModel.recurringMistakes, [])
    XCTAssertEqual(viewModel.recentSuggestions, [])
  }

  func testLoadAggregatesRecurringMistakesAndRecentSuggestions() async {
    let (store, cleanUp) = makeStore()
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

    let viewModel = LearningViewModel(learningLog: store)
    await viewModel.load()

    XCTAssertFalse(viewModel.isEmpty)
    XCTAssertEqual(
      viewModel.recurringMistakes,
      [
        GrammarCategoryCount(category: "verb-tense", count: 2),
        GrammarCategoryCount(category: "article", count: 1),
      ]
    )
    XCTAssertEqual(viewModel.recentSuggestions, ["\"he go\" → \"he went\" — more natural."])
  }
}
