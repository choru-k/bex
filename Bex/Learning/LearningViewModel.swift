import Foundation

/// How many recent "Consider" suggestions to surface. This is a display cap only, not a
/// stored limit — the underlying log keeps everything.
private let recentSuggestionsLimit = 20

/// Read-only aggregation of the learning log for the Phase 1 v1 Learning window
/// (docs/learning-mode-plan.md). No delete/edit/undo, no live notification observation —
/// data is loaded once when the window opens.
@MainActor
final class LearningViewModel: ObservableObject {
  @Published private(set) var isLoading = true
  @Published private(set) var recurringMistakes: [GrammarCategoryCount] = []
  @Published private(set) var recentSuggestions: [String] = []

  private let learningLog: LearningLogStore

  init(learningLog: LearningLogStore) {
    self.learningLog = learningLog
  }

  var isEmpty: Bool {
    !isLoading && recurringMistakes.isEmpty && recentSuggestions.isEmpty
  }

  func load() async {
    isLoading = true
    let entries = await learningLog.readAll()
    let explanations = entries.map(\.explanation)
    recurringMistakes = LearningAggregator.recurringCounts(explanations: explanations)
    recentSuggestions = Array(
      entries.reversed()
        .flatMap { LearningAggregator.parseConsiderSuggestions(from: $0.explanation) }
        .prefix(recentSuggestionsLimit)
    )
    isLoading = false
  }
}
