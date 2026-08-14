import Foundation

/// How many recent "Consider" suggestions to surface. This is a display cap only, not a
/// stored limit — the underlying log keeps everything.
private let recentSuggestionsLimit = 20

/// One tappable "Consider" alternative, ready for the list.
///
/// Carries `sourceOriginal` because that is what makes it drillable: `StudyCardBuilder`
/// blanks `phrase` inside it to build the cloze, so a suggestion divorced from the text it
/// was made about cannot become a card.
struct ConsiderSuggestion: Identifiable, Equatable, Sendable {
  let sourceOriginal: String
  let phrase: String
  let alternative: String
  let reason: String
  /// Whether the owner already chose this one. Matches `ConsiderTap.id`, so re-opening the
  /// window shows previous picks as taken.
  let isTapped: Bool

  var id: String { "\(phrase)|\(alternative)" }

  /// The line as the model wrote it, reassembled for display.
  var displayLine: String {
    let suffix = reason.isEmpty ? "" : " — \(reason)"
    return "\"\(phrase)\" → \"\(alternative)\"\(suffix)"
  }
}

/// Aggregation of the learning log for the Learning window.
/// Read-only except for one action — tapping a "Consider" alternative — which is the
/// deferred review session's entire point: expression is reviewed here, off the shipping
/// flow, and a tap is what turns exposure into a drill.
@MainActor
final class LearningViewModel: ObservableObject {
  @Published private(set) var isLoading = true
  @Published private(set) var recurringMistakes: [GrammarCategoryCount] = []
  @Published private(set) var suggestions: [ConsiderSuggestion] = []
  @Published private(set) var categoryRates: [CategoryRate] = []
  @Published private(set) var medianSentenceLength: Double = 0
  @Published private(set) var weeklyRates: [WeeklyRate] = []
  @Published private(set) var uptakeAdopted: Int = 0
  @Published private(set) var uptakeSuggested: Int = 0

  /// Bex's own model of the owner, shown so they can see it and correct it.
  ///
  /// Until now this was computed in the background, injected into every correction prompt,
  /// and never displayed anywhere — Bex was carrying an opinion about the owner's English
  /// that the owner could not read, let alone argue with.
  @Published private(set) var profile: WriterLevelProfile?
  /// The owner's own description of themselves, bound to the editor. Saved explicitly.
  @Published var ownerNote: String = ""

  private let learningLog: LearningLogStore
  private let considerTaps: ConsiderTapStore
  private let writerLevel: WriterLevelStore

  init(
    learningLog: LearningLogStore,
    considerTaps: ConsiderTapStore,
    writerLevel: WriterLevelStore = WriterLevelStore()
  ) {
    self.learningLog = learningLog
    self.considerTaps = considerTaps
    self.writerLevel = writerLevel
  }

  /// Phrases still waiting for a pick.
  ///
  /// One phrase is one decision, however many alternatives it was offered — which is the unit
  /// the Suggestions list is grouped into and the unit its header reports. The tab badge used
  /// to count individual alternatives instead, so it read "5" above a list that said "3 of 3".
  var pickDecisionsWaiting: Int {
    var phrases: Set<String> = []
    var answered: Set<String> = []
    for suggestion in suggestions {
      phrases.insert(suggestion.phrase)
      if suggestion.isTapped { answered.insert(suggestion.phrase) }
    }
    return phrases.subtracting(answered).count
  }

  /// What Bex reliably sees the owner getting right, as short labels.
  var solid: [String] {
    profile?.solid ?? []
  }

  /// What the owner is still working on, taken from the measured rates rather than from the
  /// model's prose.
  ///
  /// Non-negotiable 8 is the reason: these are the categories Bex claims are recurring, and
  /// there is already a real number for each one. Asking a model to restate them would put a
  /// second, unmeasured opinion next to the measurement.
  var workingOn: [CategoryRate] {
    Array(categoryRates.prefix(3))
  }

  /// "updated 3 hours ago", or nil before the first background pass has ever run.
  var profileAgeDescription: String? {
    guard let generatedAt = profile?.generatedAt,
      let date = ISO8601DateFormatter().date(from: generatedAt)
    else { return nil }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "updated \(formatter.localizedString(for: date, relativeTo: Date()))"
  }

  func saveOwnerNote() async {
    await writerLevel.setOwnerNote(ownerNote)
    profile = await writerLevel.current()
  }

  var isEmpty: Bool {
    !isLoading && recurringMistakes.isEmpty && suggestions.isEmpty
  }

  func load() async {
    isLoading = true
    profile = await writerLevel.current()
    ownerNote = profile?.ownerNote ?? ""
    let entries = await learningLog.readAll()
    let tappedIDs = await considerTaps.tappedIDs()
    let explanations = entries.map(\.explanation)
    recurringMistakes = LearningAggregator.recurringCounts(explanations: explanations)

    // Newest first, and deduplicated by `phrase|alternative`: since v7 the same
    // alternative recurs across many corrections, and a list showing it twenty times is a
    // list nobody scrolls. First occurrence wins, so the newest context is the one kept.
    var seen = Set<String>()
    var collected: [ConsiderSuggestion] = []
    for entry in entries.reversed() {
      for line in LearningAggregator.parseConsiderSuggestions(from: entry.explanation) {
        guard let parsed = LearningAggregator.parseSuggestionLine(line) else { continue }
        let suggestion = ConsiderSuggestion(
          sourceOriginal: entry.original,
          phrase: parsed.phrase,
          alternative: parsed.alternative,
          reason: parsed.reason,
          isTapped: tappedIDs.contains("\(parsed.phrase)|\(parsed.alternative)")
        )
        guard seen.insert(suggestion.id).inserted else { continue }
        collected.append(suggestion)
        if collected.count == recentSuggestionsLimit { break }
      }
      if collected.count == recentSuggestionsLimit { break }
    }
    suggestions = collected

    let samples = LearningLogSamples.parse(entries)
    categoryRates = LearningMetrics.categoryRates(samples: samples)
    medianSentenceLength = LearningMetrics.medianSentenceLength(originals: samples.map(\.original))
    weeklyRates = LearningMetrics.weeklyRates(samples: samples)

    // Goal-2 uptake, now measured rather than inferred: how many distinct alternatives were
    // offered across the whole log, and how many the owner actually picked.
    uptakeSuggested =
      Set(
        entries.flatMap { entry in
          LearningAggregator.parseConsiderSuggestions(from: entry.explanation)
            .compactMap { LearningAggregator.parseSuggestionLine($0) }
            .map { "\($0.phrase)|\($0.alternative)" }
        }
      ).count
    uptakeAdopted = tappedIDs.count

    isLoading = false
  }

  /// Records the owner's choice and mints a Study card from it. Deliberately does NOT
  /// rewrite anything already corrected — v6.1's rule that expression alternatives are
  /// never auto-applied still holds; a tap says "drill me on this", not "change my text".
  func chooseSuggestion(_ suggestion: ConsiderSuggestion) async {
    guard !suggestion.isTapped else { return }
    await considerTaps.record(
      sourceOriginal: suggestion.sourceOriginal,
      phrase: suggestion.phrase,
      alternative: suggestion.alternative,
      reason: suggestion.reason
    )
    guard let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) else { return }
    suggestions[index] = ConsiderSuggestion(
      sourceOriginal: suggestion.sourceOriginal,
      phrase: suggestion.phrase,
      alternative: suggestion.alternative,
      reason: suggestion.reason,
      isTapped: true
    )
    uptakeAdopted += 1
  }
}
