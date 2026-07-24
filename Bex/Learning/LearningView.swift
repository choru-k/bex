import SwiftUI

/// Phase 1 v1 read-only Learning window: recurring grammar-tag counts and recent
/// expression suggestions aggregated from the Prompt Gate learning log. No editing,
/// no menu-bar badge, no metrics — see docs/learning-mode-plan.md v6.2.
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
        if !viewModel.recurringMistakes.isEmpty {
          Section("Grammar mistakes by type") {
            ForEach(viewModel.recurringMistakes, id: \.category) { item in
              HStack {
                Text(item.displayName)
                Spacer()
                Text("\(item.count)")
                  .foregroundStyle(.secondary)
                  .accessibilityLabel("\(item.count) times")
              }
              .accessibilityIdentifier("learning-mistake-\(item.category)")
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
