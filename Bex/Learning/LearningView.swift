import SwiftUI

/// Stable `ForEach` identity for one ISO week — `WeeklyRate` itself is `Equatable` but
/// not `Hashable`, and (year, week) is already unique per `LearningMetrics.weeklyRates`.
extension WeeklyRate {
  fileprivate var weekIdentifier: String { "\(yearForWeekOfYear)-\(weekOfYear)" }
}

/// Phase 1 read-only Learning window: recurring grammar-tag counts + rates, the
/// sentence-length avoidance guard, a weekly trend, expression-suggestion uptake, and
/// recent "Consider" suggestions — all aggregated from the Prompt Gate learning log. No
/// editing; see docs/learning-mode-plan.md.
struct LearningView: View {
  @ObservedObject var viewModel: LearningViewModel

  var body: some View {
    content
      .task {
        await viewModel.load()
      }
  }

  @ViewBuilder
  private var content: some View {
    if viewModel.isLoading {
      ProgressView("Loading Learning…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("learning-loading")
    } else if viewModel.isEmpty {
      emptyState
    } else {
      List {
        if !viewModel.categoryRates.isEmpty {
          Section("Grammar mistakes by type") {
            ForEach(viewModel.categoryRates, id: \.category) { item in
              HStack {
                Text(item.displayName)
                Spacer()
                Text("\(item.count) (\(Self.formattedNumber(item.ratePer100Words))/100 words)")
                  .foregroundStyle(.secondary)
                  .accessibilityLabel(
                    "\(item.count) times, "
                      + "\(Self.formattedNumber(item.ratePer100Words)) per 100 words"
                  )
              }
              .accessibilityIdentifier("learning-mistake-\(item.category)")
            }
          }
          Section {
            VStack(alignment: .leading, spacing: 2) {
              Text("Typical sentence length: \(Self.formattedNumber(viewModel.medianSentenceLength)) words")
                .accessibilityIdentifier("learning-median-sentence-length")
              Text("Shown so a drop in mistakes isn't just shorter, simpler sentences.")
                .font(.caption)
                .foregroundStyle(.secondary)
              Text("Sentence-start capitalization is excluded — it's a terminal typing habit, not an English mistake.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("learning-capitalization-note")
            }
          }
        }
        if !viewModel.weeklyRates.isEmpty {
          Section("By week") {
            ForEach(viewModel.weeklyRates, id: \.weekIdentifier) { week in
              VStack(alignment: .leading, spacing: 2) {
                Text(Self.weekLabel(week))
                  .font(.subheadline.weight(.medium))
                Text(Self.topCategoriesSummary(week))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .accessibilityIdentifier("learning-week-\(week.yearForWeekOfYear)-\(week.weekOfYear)")
            }
          }
        }
        if viewModel.uptakeSuggested > 0 {
          Section {
            VStack(alignment: .leading, spacing: 2) {
              Text("Expression suggestions chosen: \(viewModel.uptakeAdopted) of \(viewModel.uptakeSuggested)")
                .accessibilityIdentifier("learning-uptake")
              Text("Counts the alternatives you picked below — not a guess at whether you reused them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        if !viewModel.suggestions.isEmpty {
          Section {
            ForEach(viewModel.suggestions) { suggestion in
              suggestionRow(suggestion)
            }
          } header: {
            Text("Recent suggestions")
          } footer: {
            Text("Bex won't tell you which is better. Pick the one you'd actually say — it becomes a Study card.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.inset)
    }
  }

  /// One suggestion plus the button that makes it a drill. The button is the only write
  /// action in this window — everything else here is read-only aggregation.
  private func suggestionRow(_ suggestion: ConsiderSuggestion) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(suggestion.displayLine)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(suggestion.isTapped ? "Chosen" : "I'd use this") {
        Task { await viewModel.chooseSuggestion(suggestion) }
      }
      .disabled(suggestion.isTapped)
      .accessibilityIdentifier("learning-suggestion-choose-\(suggestion.id)")
    }
    .accessibilityIdentifier("learning-suggestion-\(suggestion.id)")
  }

  /// Trims a trailing ".0" so whole numbers read as "12 words" rather than "12.0 words".
  private static func formattedNumber(_ value: Double) -> String {
    value.truncatingRemainder(dividingBy: 1) == 0
      ? String(format: "%.0f", value)
      : String(format: "%.1f", value)
  }

  private static func weekLabel(_ week: WeeklyRate) -> String {
    String(format: "%d, week %02d", week.yearForWeekOfYear, week.weekOfYear)
  }

  /// Top (already rate-sorted) categories for one week, e.g. "Prepositions 20.0/100w ·
  /// Spelling 10.0/100w" — a simple summary line, sparse by design in the first weeks.
  private static func topCategoriesSummary(_ week: WeeklyRate) -> String {
    guard !week.categoryRates.isEmpty else { return "No grammar mistakes this week" }
    return week.categoryRates.prefix(3)
      .map { "\($0.displayName) \(formattedNumber($0.ratePer100Words))/100w" }
      .joined(separator: " · ")
  }

  private var emptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: "graduationcap")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("No corrections yet")
        .font(.headline)
      Text("Use Bex in Claude Code or Codex and check back after a week.")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("learning-empty")
  }
}
