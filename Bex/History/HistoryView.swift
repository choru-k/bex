import SwiftUI

struct HistoryView: View {
  @ObservedObject var viewModel: HistoryViewModel
  @State private var expandedIDs: Set<UUID> = []
  @State private var confirmClear = false

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      if viewModel.isLoading {
        ProgressView("Loading history…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if viewModel.filteredEntries.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "clock.arrow.circlepath")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
          Text(viewModel.entries.isEmpty ? "No history yet" : "No matching history")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(viewModel.filteredEntries) { entry in
          DisclosureGroup(
            isExpanded: expansionBinding(for: entry.id)
          ) {
            entryDetails(entry)
              .padding(.top, 8)
          } label: {
            entrySummary(entry)
          }
          .accessibilityIdentifier("history-entry-\(entry.id.uuidString)")
        }
      }

      if let error = viewModel.userVisibleError {
        Divider()
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("history-error")
      }
    }
    .searchable(text: $viewModel.searchQuery, prompt: "Search history")
    .task {
      await viewModel.load()
    }
    .onDisappear {
      viewModel.close()
    }
    .alert("Clear all history?", isPresented: $confirmClear) {
      Button("Clear All", role: .destructive) {
        viewModel.clearAll()
        expandedIDs.removeAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes every Bex history entry.")
    }
  }

  private var controls: some View {
    HStack(spacing: 12) {
      Text("History")
        .font(.title2.bold())
      Picker("Provider", selection: $viewModel.providerFilter) {
        Text("All Providers").tag(LLMProvider?.none)
        ForEach(LLMProvider.allCases, id: \.self) { provider in
          Text(provider.displayName).tag(Optional(provider))
        }
      }
      .frame(width: 180)
      .accessibilityIdentifier("history-provider-filter")
      Toggle("Show only changes", isOn: $viewModel.changesOnly)
        .toggleStyle(.checkbox)
        .accessibilityIdentifier("history-changes-only")
      Spacer()
      Button("Clear All", role: .destructive) {
        confirmClear = true
      }
      .disabled(viewModel.entries.isEmpty)
      .accessibilityIdentifier("history-clear")
    }
    .padding()
  }

  private func entrySummary(_ entry: HistoryEntry) -> some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.corrected)
          .lineLimit(2)
          .font(.body)
          .accessibilityLabel("Corrected text")
          .accessibilityValue(entry.corrected)
        HStack(spacing: 6) {
          Text(entry.provider.displayName)
          Text("·")
          Text(entry.model)
          if let profileName = entry.profileName {
            Text("·")
            Label(profileName, systemImage: "person.crop.circle")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Text(entry.timestamp, format: .dateTime.month().day().hour().minute())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func entryDetails(_ entry: HistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      detailSection(title: "Original", text: entry.original)

      VStack(alignment: .leading, spacing: 5) {
        Text("Changes")
          .font(.headline)
        DiffText(
          segments: WordDiff.compute(
            original: entry.original,
            corrected: entry.corrected
          ),
          changesOnly: viewModel.changesOnly
        )
        .textSelection(.enabled)
      }

      detailSection(title: "Corrected", text: entry.corrected)
      detailSection(title: "Explanation", text: entry.explanation)

      HStack {
        Button("Use as New Input") {
          viewModel.useAsNewInput(entry)
        }
        .accessibilityIdentifier("history-use-input-\(entry.id.uuidString)")
        Spacer()
        Button("Delete", role: .destructive) {
          viewModel.delete(id: entry.id)
          expandedIDs.remove(entry.id)
        }
        .accessibilityIdentifier("history-delete-\(entry.id.uuidString)")
      }
    }
    .padding(.leading, 4)
  }

  private func detailSection(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.headline)
      Text(text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityLabel(title)
        .accessibilityValue(text)
    }
  }

  private func expansionBinding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { expandedIDs.contains(id) },
      set: { expanded in
        if expanded {
          expandedIDs.insert(id)
        } else {
          expandedIDs.remove(id)
        }
      }
    )
  }
}
