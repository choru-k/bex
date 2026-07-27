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
              Text("Expression suggestions adopted: \(viewModel.uptakeAdopted) of \(viewModel.uptakeSuggested)")
                .accessibilityIdentifier("learning-uptake")
              Text("An early signal — adoption only shows once you reuse a suggested phrase later.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
        if !viewModel.recentSuggestions.isEmpty {
          Section("Recent suggestions") {
            ForEach(Array(viewModel.recentSuggestions.enumerated()), id: \.offset) { index, suggestion in
              Text(suggestion)
                .textSelection(.enabled)
                .accessibilityIdentifier("learning-suggestion-\(index)")
            }
          }
        }
      }
      .listStyle(.inset)
    }
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
