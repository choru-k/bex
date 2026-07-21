import AppKit
import SwiftUI

struct HistoryView: View {
  @Environment(\.undoManager) private var undoManager
  @ObservedObject var viewModel: HistoryViewModel
  @State private var expandedIDs: Set<UUID> = []
  @State private var confirmClear = false
  @State private var selectedEntryID: UUID?

  var body: some View {
    VStack(spacing: 0) {
      content

      if let error = viewModel.userVisibleError {
        Divider()
        Label(error, systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("History error")
          .accessibilityValue(error)
          .accessibilityIdentifier("history-error")
      }
    }
    .onChange(of: viewModel.accessibilityAnnouncement) { announcement in
      guard let announcement else { return }
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: announcement.message,
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
    }
    .searchable(
      text: $viewModel.searchQuery,
      placement: .toolbar,
      prompt: "Search History"
    )
    .toolbar {
      ToolbarItemGroup {
        Picker("Provider Filter", selection: $viewModel.providerFilter) {
          Text("All Providers").tag(LLMProvider?.none)
          ForEach(LLMProvider.allCases, id: \.self) { provider in
            Text(provider.displayName).tag(Optional(provider))
          }
        }
        .accessibilityIdentifier("history-provider-filter")

        Toggle(isOn: $viewModel.changesOnly) {
          Label("Changes Only", systemImage: "plus.forwardslash.minus")
        }
        .toggleStyle(.button)
        .help("Show only inserted and removed text in expanded entries")
        .accessibilityIdentifier("history-changes-only")

        Menu {
          if let entry = selectedEntry {
            Button("Use Original as Input") {
              viewModel.useOriginalAsInput(entry)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Use Corrected as Input") {
              viewModel.useCorrectedAsInput(entry)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])

            Divider()
          }
          Button(role: .destructive) {
            confirmClear = true
          } label: {
            Label("Clear History", systemImage: "trash")
          }
          .disabled(viewModel.entries.isEmpty)
          .accessibilityIdentifier("history-clear")
        } label: {
          Label("History Actions", systemImage: "ellipsis.circle")
        }
        .help("History Actions")
      }
    }
    .safeAreaInset(edge: .bottom) {
      if viewModel.canUndoDeletion {
        HStack(spacing: 12) {
          Text("History entry deleted.")
          Spacer()
          Button("Undo") {
            viewModel.undoLastDeletion(using: undoManager)
          }
          .accessibilityIdentifier("history-undo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("History entry deleted. Undo available.")
      }
    }
    .task {
      await viewModel.load()
    }
    .onDisappear {
      viewModel.close()
    }
    .alert("Clear History?", isPresented: $confirmClear) {
      Button("Clear History", role: .destructive) {
        viewModel.clearAll(using: undoManager)
        expandedIDs.removeAll()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This permanently deletes all History entries. "
          + "It does not delete Writing Styles, credentials, or your current work."
      )
    }
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.contentState {
    case .loading:
      ProgressView("Loading History…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("history-loading")
    case .empty, .filteredEmpty:
      if let emptyState = viewModel.emptyStateContent {
        emptyStateView(emptyState)
      }
    case .entries:
      List(viewModel.filteredEntries, selection: $selectedEntryID) { entry in
        DisclosureGroup(
          isExpanded: expansionBinding(for: entry.id)
        ) {
          entryDetails(entry)
            .padding(.top, 8)
        } label: {
          entrySummary(entry)
        }
        .tag(entry.id)
        .accessibilityIdentifier("history-entry-\(entry.id.uuidString)")
      }
      .contextMenu(forSelectionType: UUID.self) { selectedIDs in
        if let entry = selectedEntry(in: selectedIDs) {
          Button("Use Original as Input") {
            viewModel.useOriginalAsInput(entry)
          }
          Button("Use Corrected as Input") {
            viewModel.useCorrectedAsInput(entry)
          }
        }
      }
    }
  }

  private func emptyStateView(_ state: HistoryEmptyStateContent) -> some View {
    VStack(spacing: 10) {
      Image(
        systemName: viewModel.contentState == .empty
          ? "clock.arrow.circlepath"
          : "line.3.horizontal.decrease.circle"
      )
      .font(.largeTitle)
      .foregroundStyle(.secondary)
      Text(state.title)
        .font(.headline)
      Text(state.message)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(state.actionTitle) {
        if viewModel.contentState == .empty {
          viewModel.openQuickCheck()
        } else {
          viewModel.clearFilters()
        }
      }
      .accessibilityIdentifier(
        viewModel.contentState == .empty
          ? "history-open-quick-check"
          : "history-clear-filters"
      )
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
          Text("·")
          Label(entry.profileName ?? "Bex Standard", systemImage: "textformat")
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
    let segments = viewModel.diffSegments(for: entry)

    return VStack(alignment: .leading, spacing: 12) {
      detailSection(title: "Original", text: entry.original)

      VStack(alignment: .leading, spacing: 5) {
        Text("Changes")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        DiffText(
          segments: segments,
          changesOnly: viewModel.changesOnly
        )
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Changes")
        .accessibilityValue(AccessibleDiffSummary.make(from: segments))
        .accessibilityIdentifier("history-diff-\(entry.id.uuidString)")
      }

      detailSection(title: "Corrected", text: entry.corrected)
      detailSection(title: "Explanation", text: entry.explanation)

      HStack {
        Button("Use Original as Input") {
          viewModel.useOriginalAsInput(entry)
        }
        .accessibilityIdentifier("history-use-original-\(entry.id.uuidString)")
        Button("Use Corrected as Input") {
          viewModel.useCorrectedAsInput(entry)
        }
        .accessibilityIdentifier("history-use-input-\(entry.id.uuidString)")
        Spacer()
        Button("Delete", role: .destructive) {
          viewModel.delete(entry, using: undoManager)
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
        .accessibilityAddTraits(.isHeader)
      Text(text)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityLabel(title)
        .accessibilityValue(text)
    }
  }

  private var selectedEntry: HistoryEntry? {
    guard let selectedEntryID else { return nil }
    return viewModel.filteredEntries.first { $0.id == selectedEntryID }
  }

  private func selectedEntry(in selectedIDs: Set<UUID>) -> HistoryEntry? {
    guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
    return viewModel.filteredEntries.first { $0.id == id }
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
