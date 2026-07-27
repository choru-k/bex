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
  @Published private(set) var categoryRates: [CategoryRate] = []
  @Published private(set) var medianSentenceLength: Double = 0
  @Published private(set) var weeklyRates: [WeeklyRate] = []
  @Published private(set) var uptakeAdopted: Int = 0
  @Published private(set) var uptakeSuggested: Int = 0

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

    let samples = LearningLogSamples.parse(entries)
    categoryRates = LearningMetrics.categoryRates(samples: samples)
    medianSentenceLength = LearningMetrics.medianSentenceLength(originals: samples.map(\.original))
    weeklyRates = LearningMetrics.weeklyRates(samples: samples)
    let uptake = LearningMetrics.uptake(samples: samples)
    uptakeAdopted = uptake.adopted
    uptakeSuggested = uptake.suggested

    isLoading = false
  }
}
