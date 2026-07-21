import Foundation
import XCTest

@testable import Bex

final class BexDataStoreHistoryRestoreTests: XCTestCase {
  func testRestoreHistoryReturnsEntryToFront() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let entries = makeEntries(["front", "middle", "end"])
    try await seed(entries, in: fixture.store)

    try await fixture.store.deleteHistory(id: entries[0].id)
    try await fixture.store.restoreHistory(entries[0], at: 0)

    let history = try await fixture.store.loadHistory()
    XCTAssertEqual(history, entries)
  }

  func testRestoreHistoryReturnsEntryToMiddle() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let entries = makeEntries(["front", "middle", "end"])
    try await seed(entries, in: fixture.store)

    try await fixture.store.deleteHistory(id: entries[1].id)
    try await fixture.store.restoreHistory(entries[1], at: 1)

    let history = try await fixture.store.loadHistory()
    XCTAssertEqual(history, entries)
  }

  func testRestoreHistoryReturnsEntryToEnd() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let entries = makeEntries(["front", "middle", "end"])
    try await seed(entries, in: fixture.store)

    try await fixture.store.deleteHistory(id: entries[2].id)
    try await fixture.store.restoreHistory(entries[2], at: 2)

    let history = try await fixture.store.loadHistory()
    XCTAssertEqual(history, entries)
  }

  func testRestoreHistoryBoundsStaleIndexes() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let entries = makeEntries(["front", "end"])
    try await seed(entries, in: fixture.store)
    let restored = makeEntry("restored")

    try await fixture.store.restoreHistory(restored, at: -20)
    let historyAtFront = try await fixture.store.loadHistory()
    XCTAssertEqual(historyAtFront, [restored] + entries)

    try await fixture.store.deleteHistory(id: restored.id)
    try await fixture.store.restoreHistory(restored, at: 20)
    let historyAtEnd = try await fixture.store.loadHistory()
    XCTAssertEqual(historyAtEnd, entries + [restored])
  }

  func testRestoreHistoryDoesNotDuplicateAnExistingID() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let entries = makeEntries(["front", "existing", "end"])
    try await seed(entries, in: fixture.store)
    let duplicate = HistoryEntry(
      id: entries[1].id,
      original: "different original",
      corrected: "different corrected",
      explanation: "different explanation",
      provider: .claude,
      model: "different model",
      timestamp: Date(timeIntervalSince1970: 99),
      profileName: "different profile"
    )
    let persistedBeforeRestore = try Data(contentsOf: fixture.fileURL)

    try await fixture.store.restoreHistory(duplicate, at: 0)

    let history = try await fixture.store.loadHistory()
    XCTAssertEqual(history, entries)
    XCTAssertEqual(history.filter { $0.id == duplicate.id }.count, 1)
    XCTAssertEqual(try Data(contentsOf: fixture.fileURL), persistedBeforeRestore)
  }

  func testRestoreHistoryPersistsAndPostsChangeWithoutTouchingProfiles() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let profile = Profile(id: UUID(), name: "Work", prompt: "Be concise.")
    let entries = makeEntries(["front", "restored", "end"])
    try await fixture.store.saveProfile(profile)
    try await seed(entries, in: fixture.store)
    try await fixture.store.deleteHistory(id: entries[1].id)
    let notification = expectation(description: "History change notification")
    let observer = NotificationCenter.default.addObserver(
      forName: .bexHistoryDidChange,
      object: nil,
      queue: nil
    ) { _ in
      notification.fulfill()
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    try await fixture.store.restoreHistory(entries[1], at: 1)
    await fulfillment(of: [notification], timeout: 1)

    let reloaded = BexDataStore(fileURL: fixture.fileURL)
    let reloadedHistory = try await reloaded.loadHistory()
    let reloadedProfiles = try await reloaded.loadProfiles()
    XCTAssertEqual(reloadedHistory, entries)
    XCTAssertEqual(reloadedProfiles, [profile])
  }

  func testRestoreHistoryRetainsEntryAndLimitWhilePreservingUnaffectedOrder() async throws {
    let fixture = try HistoryRestoreStoreFixture()
    defer { fixture.remove() }
    let entries = (0..<BexDataStore.historyLimit).map { makeEntry("entry-\($0)") }
    try fixture.write(BexData(
      schemaVersion: BexDataStore.schemaVersion,
      profiles: [],
      history: entries
    ))
    let restored = makeEntry("restored")
    let restoreIndex = 200

    try await fixture.store.restoreHistory(restored, at: restoreIndex)

    let history = try await fixture.store.loadHistory()
    XCTAssertEqual(history.count, BexDataStore.historyLimit)
    XCTAssertEqual(history[restoreIndex], restored)
    XCTAssertEqual(Array(history[..<restoreIndex]), Array(entries[..<restoreIndex]))
    XCTAssertEqual(Array(history[(restoreIndex + 1)...]), Array(entries[restoreIndex..<(entries.count - 1)]))
    XCTAssertFalse(history.contains { $0.id == entries.last?.id })
  }

  private func seed(_ entries: [HistoryEntry], in store: BexDataStore) async throws {
    for entry in entries.reversed() {
      try await store.appendHistory(entry)
    }
  }

  private func makeEntries(_ labels: [String]) -> [HistoryEntry] {
    labels.map(makeEntry)
  }

  private func makeEntry(_ label: String) -> HistoryEntry {
    HistoryEntry(
      id: UUID(),
      original: "original-\(label)",
      corrected: "corrected-\(label)",
      explanation: "explanation-\(label)",
      provider: .openAI,
      model: "test-model",
      timestamp: Date(timeIntervalSince1970: 1),
      profileName: nil
    )
  }
}

private struct HistoryRestoreStoreFixture {
  let directory: URL
  let fileURL: URL
  let store: BexDataStore

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexHistoryRestoreTests-\(UUID().uuidString)", isDirectory: true)
    fileURL = directory.appendingPathComponent("data.json")
    store = BexDataStore(fileURL: fileURL)
  }

  func write(_ data: BexData) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(data).write(to: fileURL)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}
