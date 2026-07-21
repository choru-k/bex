import Foundation

enum HistoryContentState: Equatable {
  case loading
  case empty
  case filteredEmpty
  case entries
}

struct HistoryEmptyStateContent: Equatable {
  let title: String
  let message: String
  let actionTitle: String
}

struct HistoryAccessibilityAnnouncement: Equatable, Sendable {
  let sequence: Int
  let message: String
}

@MainActor
final class HistoryViewModel: ObservableObject {
  @Published private(set) var entries: [HistoryEntry] = []
  @Published private(set) var isLoading = true
  @Published var searchQuery = ""
  @Published var providerFilter: LLMProvider?
  @Published var changesOnly = false
  @Published private(set) var userVisibleError: String?
  @Published private(set) var canUndoDeletion = false
  @Published private(set) var accessibilityAnnouncement: HistoryAccessibilityAnnouncement?

  private let data: BexDataStore
  private let deleteHistoryAction: @Sendable (UUID) async throws -> Void
  private let restoreHistoryAction: @Sendable (HistoryEntry, UUID?, UUID?) async throws -> Void
  private let useAsNewInputAction: @MainActor (String) -> Void
  private let openQuickCheckAction: @MainActor () -> Void
  private var operationTask: Task<Void, Never>?
  private var notificationTask: Task<Void, Never>?
  private var undoGeneration = 0
  private var registeredDeletionUndoCount = 0
  private var announcementSequence = 0

  init(
    data: BexDataStore,
    useAsNewInput: @escaping @MainActor (String) -> Void,
    openQuickCheck: @escaping @MainActor () -> Void = {},
    deleteHistory: (@Sendable (UUID) async throws -> Void)? = nil,
    restoreHistory: (@Sendable (HistoryEntry, UUID?, UUID?) async throws -> Void)? = nil
  ) {
    self.data = data
    deleteHistoryAction =
      deleteHistory ?? { id in
        try await data.deleteHistory(id: id)
      }
    restoreHistoryAction =
      restoreHistory ?? { entry, predecessorID, successorID in
        try await data.restoreHistory(
          entry,
          after: predecessorID,
          before: successorID
        )
      }
    useAsNewInputAction = useAsNewInput
    openQuickCheckAction = openQuickCheck
  }

  var filteredEntries: [HistoryEntry] {
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return entries.filter { entry in
      if let providerFilter, entry.provider != providerFilter {
        return false
      }
      guard !query.isEmpty else { return true }
      return [
        entry.original,
        entry.corrected,
        entry.explanation,
        entry.provider.rawValue,
        entry.provider.displayName,
        entry.model,
        entry.profileName ?? "Bex Standard",
      ].contains { $0.lowercased().contains(query) }
    }
  }

  var contentState: HistoryContentState {
    if isLoading {
      return .loading
    }
    if entries.isEmpty {
      return .empty
    }
    return filteredEntries.isEmpty ? .filteredEmpty : .entries
  }

  var emptyStateContent: HistoryEmptyStateContent? {
    switch contentState {
    case .empty:
      HistoryEmptyStateContent(
        title: "No History Yet",
        message: "Corrections you save from Quick Check will appear here.",
        actionTitle: "Open Quick Check"
      )
    case .filteredEmpty:
      HistoryEmptyStateContent(
        title: "No Matching History",
        message: "No entries match your search or provider filter.",
        actionTitle: "Clear Filters"
      )
    case .loading, .entries:
      nil
    }
  }

  func load() async {
    isLoading = true
    do {
      entries = try await data.loadHistory()
      userVisibleError = nil
    } catch {
      userVisibleError = error.localizedDescription
    }
    isLoading = false
    startObservingIfNeeded()
  }

  func delete(_ entry: HistoryEntry, using undoManager: UndoManager?) {
    guard entries.contains(where: { $0.id == entry.id }) else {
      return
    }

    let previousTask = operationTask
    let generation = undoGeneration
    operationTask = Task { [weak self] in
      await previousTask?.value
      guard !Task.isCancelled, let self else { return }
      guard let originalIndex = entries.firstIndex(where: { $0.id == entry.id }) else {
        return
      }
      let predecessorID =
        originalIndex > entries.startIndex ? entries[originalIndex - 1].id : nil
      let successorID =
        originalIndex + 1 < entries.endIndex ? entries[originalIndex + 1].id : nil
      do {
        try await deleteHistoryAction(entry.id)
        guard generation == undoGeneration else { return }
        entries.removeAll { $0.id == entry.id }
        registerUndo(
          for: entry,
          after: predecessorID,
          before: successorID,
          generation: generation,
          using: undoManager
        )
        userVisibleError = nil
        announce(
          canUndoDeletion
            ? "History entry deleted. Undo available."
            : "History entry deleted."
        )
      } catch {
        guard !Task.isCancelled else { return }
        userVisibleError = error.localizedDescription
      }
    }
  }

  func undoLastDeletion(using undoManager: UndoManager?) {
    guard canUndoDeletion else { return }
    undoManager?.undo()
  }

  func clearAll(using undoManager: UndoManager?) {
    invalidateDeletionUndo(using: undoManager)
    let previousTask = operationTask
    let generation = undoGeneration
    operationTask = Task { [weak self] in
      await previousTask?.value
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do {
        try await data.clearHistory()
        guard !Task.isCancelled, generation == undoGeneration else { return }
        entries = []
        userVisibleError = nil
        announce("History cleared.")
      } catch {
        guard !Task.isCancelled else { return }
        userVisibleError = error.localizedDescription
      }
    }
  }

  func clearFilters() {
    searchQuery = ""
    providerFilter = nil
  }

  func openQuickCheck() {
    openQuickCheckAction()
  }

  func useOriginalAsInput(_ entry: HistoryEntry) {
    useAsNewInputAction(entry.original)
  }

  func useCorrectedAsInput(_ entry: HistoryEntry) {
    useAsNewInputAction(entry.corrected)
  }

  func diffSegments(for entry: HistoryEntry) -> [DiffSegment] {
    WordDiff.compute(original: entry.original, corrected: entry.corrected)
  }

  func accessibleDiffSummary(for entry: HistoryEntry) -> String {
    AccessibleDiffSummary.make(from: diffSegments(for: entry))
  }

  func close() {
    operationTask?.cancel()
    operationTask = nil
    notificationTask?.cancel()
    notificationTask = nil
  }

  func waitForCurrentWork() async {
    await operationTask?.value
  }

  private func registerUndo(
    for entry: HistoryEntry,
    after predecessorID: UUID?,
    before successorID: UUID?,
    generation: Int,
    using undoManager: UndoManager?
  ) {
    guard let undoManager else {
      canUndoDeletion = registeredDeletionUndoCount > 0
      return
    }

    let createsStandaloneGroup = undoManager.groupingLevel == 0
    if createsStandaloneGroup {
      undoManager.beginUndoGrouping()
    }
    undoManager.registerUndo(withTarget: self) { viewModel in
      viewModel.restoreDeletedEntry(
        entry,
        after: predecessorID,
        before: successorID,
        generation: generation
      )
    }
    undoManager.setActionName("Delete History Entry")
    if createsStandaloneGroup {
      undoManager.endUndoGrouping()
    }
    registeredDeletionUndoCount += 1
    canUndoDeletion = true
  }

  private func restoreDeletedEntry(
    _ entry: HistoryEntry,
    after predecessorID: UUID?,
    before successorID: UUID?,
    generation: Int
  ) {
    guard generation == undoGeneration else { return }
    registeredDeletionUndoCount = max(0, registeredDeletionUndoCount - 1)
    canUndoDeletion = registeredDeletionUndoCount > 0
    let previousTask = operationTask
    operationTask = Task { [weak self] in
      await previousTask?.value
      guard !Task.isCancelled, let self else { return }
      do {
        try await restoreHistoryAction(entry, predecessorID, successorID)
        guard !Task.isCancelled, generation == undoGeneration else { return }
        entries = try await data.loadHistory()
        userVisibleError = nil
        announce("History entry restored.")
      } catch {
        guard !Task.isCancelled else { return }
        userVisibleError = error.localizedDescription
      }
    }
  }

  private func invalidateDeletionUndo(using undoManager: UndoManager?) {
    undoGeneration += 1
    registeredDeletionUndoCount = 0
    canUndoDeletion = false
    undoManager?.removeAllActions(withTarget: self)
  }

  private func announce(_ message: String) {
    announcementSequence &+= 1
    accessibilityAnnouncement = HistoryAccessibilityAnnouncement(
      sequence: announcementSequence,
      message: message
    )
  }

  private func startObservingIfNeeded() {
    guard notificationTask == nil else { return }
    notificationTask = Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: .bexHistoryDidChange) {
        guard !Task.isCancelled, let self else { return }
        do {
          entries = try await data.loadHistory()
        } catch {
          userVisibleError = error.localizedDescription
        }
      }
    }
  }
}
