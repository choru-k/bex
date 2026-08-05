import Foundation
import XCTest

@testable import Bex

final class StudyStateStoreTests: XCTestCase {
  private func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("StudyStateStoreTests-\(UUID().uuidString)", isDirectory: true)
  }

  func testMissingFileYieldsEmptyState() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = StudyStateStore(directoryURL: directory)
    let states = await store.states()
    XCTAssertTrue(states.isEmpty)
  }

  func testRecordRoundTripsStateToDiskAndReloadsInFreshInstance() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let store = StudyStateStore(directoryURL: directory)
    await store.record(cardID: "card-1", correct: true, now: fixedNow)

    let fileURL = directory.appendingPathComponent("study-state.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    // A fresh instance pointed at the same directory must see the persisted state.
    let reloaded = StudyStateStore(directoryURL: directory)
    let states = await reloaded.states()
    let state = try XCTUnwrap(states["card-1"])
    XCTAssertEqual(state.box, 1)
    XCTAssertEqual(state.timesSeen, 1)
    XCTAssertEqual(state.timesCorrect, 1)
    XCTAssertEqual(
      state.dueAt.timeIntervalSince1970,
      fixedNow.addingTimeInterval(3 * 86_400).timeIntervalSince1970,
      accuracy: 0.001
    )
  }

  func testRecordAccumulatesAcrossMultipleCalls() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let store = StudyStateStore(directoryURL: directory)
    await store.record(cardID: "card-1", correct: true, now: fixedNow)
    await store.record(cardID: "card-1", correct: false, now: fixedNow.addingTimeInterval(86_400))
    await store.record(cardID: "card-2", correct: true, now: fixedNow)

    let states = await store.states()
    XCTAssertEqual(states.count, 2)
    let card1 = try XCTUnwrap(states["card-1"])
    XCTAssertEqual(card1.box, 0)
    XCTAssertEqual(card1.timesSeen, 2)
    XCTAssertEqual(card1.timesCorrect, 1)
  }

  func testCorruptFileYieldsEmptyStateWithoutThrowing() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fileURL = directory.appendingPathComponent("study-state.json")
    try Data("not valid json { garbage".utf8).write(to: fileURL)

    let store = StudyStateStore(directoryURL: directory)
    let states = await store.states()
    XCTAssertTrue(states.isEmpty)
  }

  func testResetClearsAllState() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let store = StudyStateStore(directoryURL: directory)
    await store.record(cardID: "card-1", correct: true, now: fixedNow)
    var states = await store.states()
    XCTAssertFalse(states.isEmpty)

    await store.reset()
    states = await store.states()
    XCTAssertTrue(states.isEmpty)

    // Reset must also persist, so a fresh instance also sees empty state.
    let reloaded = StudyStateStore(directoryURL: directory)
    let reloadedStates = await reloaded.states()
    XCTAssertTrue(reloadedStates.isEmpty)
  }

  func testFileAndDirectoryPermissionsAreOwnerOnly() async throws {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = StudyStateStore(directoryURL: directory)
    await store.record(cardID: "card-1", correct: true, now: Date(timeIntervalSince1970: 1_700_000_000))

    let fileURL = directory.appendingPathComponent("study-state.json")
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let filePermissions = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(filePermissions.uint16Value & 0o777, 0o600)

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let directoryPermissions = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(directoryPermissions.uint16Value & 0o777, 0o700)
  }
}
