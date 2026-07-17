import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
  @Published private(set) var entries: [HistoryEntry] = []
  @Published private(set) var isLoading = false
  @Published var searchQuery = ""
  @Published var providerFilter: LLMProvider?
  @Published var changesOnly = false
  @Published private(set) var userVisibleError: String?

  private let data: BexDataStore
  private let useAsNewInputAction: @MainActor (String) -> Void
  private var operationTask: Task<Void, Never>?
  private var notificationTask: Task<Void, Never>?

  init(
    data: BexDataStore,
    useAsNewInput: @escaping @MainActor (String) -> Void
  ) {
    self.data = data
    useAsNewInputAction = useAsNewInput
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
        entry.profileName ?? "",
      ].contains { $0.lowercased().contains(query) }
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

  func delete(id: UUID) {
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await data.deleteHistory(id: id)
        entries.removeAll { $0.id == id }
        userVisibleError = nil
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func clearAll() {
    operationTask?.cancel()
    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await data.clearHistory()
        entries = []
        userVisibleError = nil
      } catch {
        userVisibleError = error.localizedDescription
      }
    }
  }

  func useAsNewInput(_ entry: HistoryEntry) {
    useAsNewInputAction(entry.corrected)
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
