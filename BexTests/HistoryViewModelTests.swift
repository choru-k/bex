import Foundation
import XCTest

@testable import Bex

@MainActor
final class HistoryViewModelTests: XCTestCase {
  func testLoadingEmptyAndRouteIntent() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    var openedQuickCheck = 0
    var replacementDraft: String?
    let viewModel = HistoryViewModel(
      data: fixture.data,
      useAsNewInput: { replacementDraft = $0 },
      openQuickCheck: { openedQuickCheck += 1 }
    )
    defer { viewModel.close() }

    XCTAssertEqual(viewModel.contentState, .loading)
    XCTAssertNil(viewModel.emptyStateContent)

    await viewModel.load()

    XCTAssertEqual(viewModel.contentState, .empty)
    XCTAssertEqual(
      viewModel.emptyStateContent,
      HistoryEmptyStateContent(
        title: "No History Yet",
        message: "Corrections you save from Quick Check will appear here.",
        actionTitle: "Open Quick Check"
      )
    )

    viewModel.openQuickCheck()
    XCTAssertEqual(openedQuickCheck, 1)

    let entry = makeEntry(id: UUID(), original: "Old", corrected: "New")
    viewModel.useCorrectedAsInput(entry)
    XCTAssertEqual(replacementDraft, "New")
  }

  func testFilteredEmptyExplainsRecoveryAndClearingFiltersRestoresEntries() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entry = makeEntry(
      id: UUID(),
      original: "This are a sentence.",
      corrected: "This is a sentence.",
      provider: .claude
    )
    try await fixture.data.appendHistory(entry)
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()

    XCTAssertEqual(viewModel.contentState, .entries)

    viewModel.searchQuery = "not present"
    XCTAssertEqual(viewModel.contentState, .filteredEmpty)
    XCTAssertEqual(
      viewModel.emptyStateContent,
      HistoryEmptyStateContent(
        title: "No Matching History",
        message: "No entries match your search or provider filter.",
        actionTitle: "Clear Filters"
      )
    )

    viewModel.searchQuery = ""
    viewModel.providerFilter = .openAI
    XCTAssertEqual(viewModel.contentState, .filteredEmpty)

    viewModel.clearFilters()
    XCTAssertEqual(viewModel.contentState, .entries)
    XCTAssertEqual(viewModel.filteredEntries, [entry])
  }

  func testDeleteUndoRestoresSameEntryAtOriginalRelativePosition() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entries = [
      makeEntry(id: UUID(), original: "First old", corrected: "First new"),
      makeEntry(id: UUID(), original: "Second old", corrected: "Second new"),
      makeEntry(id: UUID(), original: "Third old", corrected: "Third new"),
    ]
    for entry in entries.reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()

    viewModel.delete(entries[1], using: undoManager)
    await viewModel.waitForCurrentWork()

    let historyAfterDeletion = try await fixture.data.loadHistory()
    XCTAssertEqual(viewModel.entries, [entries[0], entries[2]])
    XCTAssertEqual(historyAfterDeletion, [entries[0], entries[2]])
    XCTAssertTrue(viewModel.canUndoDeletion)
    XCTAssertTrue(undoManager.canUndo)
    XCTAssertEqual(undoManager.undoActionName, "Delete History Entry")

    undoManager.undo()
    await Task.yield()
    await viewModel.waitForCurrentWork()

    let historyAfterUndo = try await fixture.data.loadHistory()
    XCTAssertEqual(viewModel.entries, entries)
    XCTAssertEqual(historyAfterUndo, entries)
    XCTAssertFalse(viewModel.canUndoDeletion)
  }

  func testRapidSequentialDeletesCompleteEachTransactionWithUndo() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entries = [
      makeEntry(id: UUID(), original: "A", corrected: "A corrected"),
      makeEntry(id: UUID(), original: "B", corrected: "B corrected"),
      makeEntry(id: UUID(), original: "C", corrected: "C corrected"),
      makeEntry(id: UUID(), original: "D", corrected: "D corrected"),
    ]
    for entry in entries.reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let controlledDelete = ControlledHistoryDelete(data: fixture.data)
    let viewModel = HistoryViewModel(
      data: fixture.data,
      useAsNewInput: { _ in },
      deleteHistory: { id in
        try await controlledDelete.delete(id: id)
      }
    )
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false

    viewModel.delete(entries[1], using: undoManager)
    await controlledDelete.waitUntilStarted(count: 1)
    viewModel.delete(entries[2], using: undoManager)

    let startedBeforeFirstCompletion = await controlledDelete.startedIDs
    XCTAssertEqual(startedBeforeFirstCompletion, [entries[1].id])

    await controlledDelete.release(ordinal: 1)
    await controlledDelete.waitUntilStarted(count: 2)

    let historyBeforeSecondCommit = try await fixture.data.loadHistory()
    XCTAssertEqual(historyBeforeSecondCommit, [entries[0], entries[2], entries[3]])
    XCTAssertEqual(viewModel.entries, [entries[0], entries[2], entries[3]])
    XCTAssertTrue(undoManager.canUndo)
    XCTAssertTrue(viewModel.canUndoDeletion)

    await controlledDelete.release(ordinal: 2)
    await viewModel.waitForCurrentWork()

    let historyAfterBothDeletes = try await fixture.data.loadHistory()
    XCTAssertEqual(historyAfterBothDeletes, [entries[0], entries[3]])
    XCTAssertEqual(viewModel.entries, [entries[0], entries[3]])

    viewModel.undoLastDeletion(using: undoManager)
    await viewModel.waitForCurrentWork()

    let historyAfterFirstUndo = try await fixture.data.loadHistory()
    XCTAssertEqual(historyAfterFirstUndo, [entries[0], entries[2], entries[3]])
    XCTAssertEqual(viewModel.entries, [entries[0], entries[2], entries[3]])
    XCTAssertTrue(undoManager.canUndo)
    XCTAssertTrue(viewModel.canUndoDeletion)

    viewModel.undoLastDeletion(using: undoManager)
    await viewModel.waitForCurrentWork()

    let historyAfterSecondUndo = try await fixture.data.loadHistory()
    XCTAssertEqual(historyAfterSecondUndo, entries)
    XCTAssertEqual(viewModel.entries, entries)
    XCTAssertFalse(viewModel.canUndoDeletion)
  }

  func testReverseAdjacentQueuedDeletesCaptureNeighborsAfterPriorTransaction() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entries = [
      makeEntry(id: UUID(), original: "A", corrected: "A corrected"),
      makeEntry(id: UUID(), original: "B", corrected: "B corrected"),
      makeEntry(id: UUID(), original: "C", corrected: "C corrected"),
    ]
    for entry in entries.reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let controlledDelete = ControlledHistoryDelete(data: fixture.data)
    let viewModel = HistoryViewModel(
      data: fixture.data,
      useAsNewInput: { _ in },
      deleteHistory: { id in
        try await controlledDelete.delete(id: id)
      }
    )
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false

    viewModel.delete(entries[1], using: undoManager)
    await controlledDelete.waitUntilStarted(count: 1)
    viewModel.delete(entries[0], using: undoManager)

    let startedBeforeFirstCompletion = await controlledDelete.startedIDs
    XCTAssertEqual(startedBeforeFirstCompletion, [entries[1].id])

    await controlledDelete.release(ordinal: 1)
    await controlledDelete.waitUntilStarted(count: 2)

    let historyBeforeSecondCommit = try await fixture.data.loadHistory()
    XCTAssertEqual(historyBeforeSecondCommit, [entries[0], entries[2]])
    XCTAssertEqual(viewModel.entries, [entries[0], entries[2]])

    await controlledDelete.release(ordinal: 2)
    await viewModel.waitForCurrentWork()

    let historyAfterBothDeletes = try await fixture.data.loadHistory()
    XCTAssertEqual(historyAfterBothDeletes, [entries[2]])
    XCTAssertEqual(viewModel.entries, [entries[2]])

    viewModel.undoLastDeletion(using: undoManager)
    viewModel.undoLastDeletion(using: undoManager)
    await viewModel.waitForCurrentWork()

    let historyAfterImmediateUndos = try await fixture.data.loadHistory()
    XCTAssertEqual(historyAfterImmediateUndos, entries)
    XCTAssertEqual(viewModel.entries, entries)
  }

  func testDeleteUndoKeepsPrependedEntryAheadOfOriginalPredecessor() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let a = makeEntry(id: UUID(), original: "A", corrected: "A corrected")
    let b = makeEntry(id: UUID(), original: "B", corrected: "B corrected")
    let c = makeEntry(id: UUID(), original: "C", corrected: "C corrected")
    let n = makeEntry(id: UUID(), original: "N", corrected: "N corrected")
    for entry in [a, b, c].reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()

    viewModel.delete(b, using: undoManager)
    await viewModel.waitForCurrentWork()
    try await fixture.data.appendHistory(n)

    viewModel.undoLastDeletion(using: undoManager)
    await Task.yield()
    await viewModel.waitForCurrentWork()

    let persistedHistory = try await fixture.data.loadHistory()
    XCTAssertEqual(viewModel.entries, [n, a, b, c])
    XCTAssertEqual(persistedHistory, [n, a, b, c])
  }

  func testDeleteUndoUsesSuccessorAtMissingPredecessorBoundary() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let a = makeEntry(id: UUID(), original: "A", corrected: "A corrected")
    let b = makeEntry(id: UUID(), original: "B", corrected: "B corrected")
    let c = makeEntry(id: UUID(), original: "C", corrected: "C corrected")
    let n = makeEntry(id: UUID(), original: "N", corrected: "N corrected")
    for entry in [a, b, c].reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()

    viewModel.delete(a, using: undoManager)
    await viewModel.waitForCurrentWork()
    try await fixture.data.appendHistory(n)

    viewModel.undoLastDeletion(using: undoManager)
    await Task.yield()
    await viewModel.waitForCurrentWork()

    let persistedHistory = try await fixture.data.loadHistory()
    XCTAssertEqual(viewModel.entries, [n, a, b, c])
    XCTAssertEqual(persistedHistory, [n, a, b, c])
  }

  func testDeleteUndoUsesPredecessorAtMissingSuccessorBoundary() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let a = makeEntry(id: UUID(), original: "A", corrected: "A corrected")
    let b = makeEntry(id: UUID(), original: "B", corrected: "B corrected")
    let c = makeEntry(id: UUID(), original: "C", corrected: "C corrected")
    let n = makeEntry(id: UUID(), original: "N", corrected: "N corrected")
    for entry in [a, b, c].reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()

    viewModel.delete(c, using: undoManager)
    await viewModel.waitForCurrentWork()
    try await fixture.data.appendHistory(n)

    viewModel.undoLastDeletion(using: undoManager)
    await Task.yield()
    await viewModel.waitForCurrentWork()

    let persistedHistory = try await fixture.data.loadHistory()
    XCTAssertEqual(viewModel.entries, [n, a, b, c])
    XCTAssertEqual(persistedHistory, [n, a, b, c])
  }

  func testImmediateUndoThenClearSerializesRestoreBeforeFinalClear() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entries = [
      makeEntry(id: UUID(), original: "A", corrected: "A corrected"),
      makeEntry(id: UUID(), original: "B", corrected: "B corrected"),
    ]
    for entry in entries.reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let controlledRestore = ControlledHistoryRestore(data: fixture.data)
    let viewModel = HistoryViewModel(
      data: fixture.data,
      useAsNewInput: { _ in },
      restoreHistory: { entry, predecessorID, successorID in
        try await controlledRestore.restore(
          entry,
          after: predecessorID,
          before: successorID
        )
      }
    )
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()

    viewModel.delete(entries[0], using: undoManager)
    await viewModel.waitForCurrentWork()
    viewModel.undoLastDeletion(using: undoManager)
    viewModel.clearAll(using: undoManager)

    await controlledRestore.waitUntilStarted()
    await controlledRestore.release()
    await viewModel.waitForCurrentWork()

    let historyAfterClear = try await fixture.data.loadHistory()
    XCTAssertTrue(viewModel.entries.isEmpty)
    XCTAssertTrue(historyAfterClear.isEmpty)
    XCTAssertFalse(viewModel.canUndoDeletion)
  }

  func testClearHistoryInvalidatesPendingDeletionUndo() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entries = [
      makeEntry(id: UUID(), original: "First old", corrected: "First new"),
      makeEntry(id: UUID(), original: "Second old", corrected: "Second new"),
    ]
    for entry in entries.reversed() {
      try await fixture.data.appendHistory(entry)
    }
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()
    let undoManager = UndoManager()

    viewModel.delete(entries[0], using: undoManager)
    await viewModel.waitForCurrentWork()
    XCTAssertTrue(undoManager.canUndo)

    viewModel.clearAll(using: undoManager)
    await viewModel.waitForCurrentWork()

    let historyAfterClear = try await fixture.data.loadHistory()
    XCTAssertTrue(viewModel.entries.isEmpty)
    XCTAssertTrue(historyAfterClear.isEmpty)
    XCTAssertFalse(viewModel.canUndoDeletion)

    undoManager.undo()
    await Task.yield()
    let historyAfterInvalidUndo = try await fixture.data.loadHistory()
    XCTAssertTrue(historyAfterInvalidUndo.isEmpty)
  }

  func testHistoryDiffUsesSharedAccessibleSummaryAndBexStandardTerminology() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanUp() }
    let entry = makeEntry(
      id: UUID(),
      original: "This are ready.",
      corrected: "This is ready.",
      profileName: nil
    )
    try await fixture.data.appendHistory(entry)
    let viewModel = HistoryViewModel(data: fixture.data, useAsNewInput: { _ in })
    defer { viewModel.close() }
    await viewModel.load()

    let sharedSegments = WordDiff.compute(original: entry.original, corrected: entry.corrected)
    XCTAssertEqual(viewModel.diffSegments(for: entry), sharedSegments)
    XCTAssertEqual(
      viewModel.accessibleDiffSummary(for: entry),
      AccessibleDiffSummary.make(from: sharedSegments)
    )

    viewModel.searchQuery = "Bex Standard"
    XCTAssertEqual(viewModel.filteredEntries, [entry])
  }

  private func makeFixture() throws -> HistoryFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexHistoryViewModelTests-\(UUID().uuidString)")
    return HistoryFixture(
      directory: directory,
      data: BexDataStore(fileURL: directory.appendingPathComponent("data.json"))
    )
  }

  private func makeEntry(
    id: UUID,
    original: String,
    corrected: String,
    provider: LLMProvider = .openAI,
    profileName: String? = nil
  ) -> HistoryEntry {
    HistoryEntry(
      id: id,
      original: original,
      corrected: corrected,
      explanation: "A correction was made.",
      provider: provider,
      model: provider.defaultModel,
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      profileName: profileName
    )
  }
}

private struct HistoryFixture {
  let directory: URL
  let data: BexDataStore

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }
}

private actor ControlledHistoryRestore {
  private let data: BexDataStore
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseContinuation: CheckedContinuation<Void, Never>?
  private var released = false

  init(data: BexDataStore) {
    self.data = data
  }

  func restore(
    _ entry: HistoryEntry,
    after predecessorID: UUID?,
    before successorID: UUID?
  ) async throws {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      if released {
        continuation.resume()
      } else {
        releaseContinuation = continuation
      }
    }
    try await data.restoreHistory(
      entry,
      after: predecessorID,
      before: successorID
    )
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func release() {
    released = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor ControlledHistoryDelete {
  private let data: BexDataStore
  private(set) var startedIDs: [UUID] = []
  private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
  private var releasedOrdinals: Set<Int> = []

  init(data: BexDataStore) {
    self.data = data
  }

  func delete(id: UUID) async throws {
    startedIDs.append(id)
    let ordinal = startedIDs.count
    let readyWaiters = startWaiters.filter { $0.count <= ordinal }
    startWaiters.removeAll { $0.count <= ordinal }
    for waiter in readyWaiters {
      waiter.continuation.resume()
    }

    await withCheckedContinuation { continuation in
      if releasedOrdinals.remove(ordinal) != nil {
        continuation.resume()
      } else {
        releaseContinuations[ordinal] = continuation
      }
    }
    try await data.deleteHistory(id: id)
  }

  func waitUntilStarted(count: Int) async {
    guard startedIDs.count < count else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func release(ordinal: Int) {
    if let continuation = releaseContinuations.removeValue(forKey: ordinal) {
      continuation.resume()
    } else {
      releasedOrdinals.insert(ordinal)
    }
  }
}
