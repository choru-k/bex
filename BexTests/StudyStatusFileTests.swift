import Foundation
import XCTest

@testable import Bex

final class StudyStatusFileTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("StudyStatusFileTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var fileURL: URL {
    directory.appendingPathComponent("study-status.json")
  }

  /// The contract external readers depend on: a `dueCount` integer they can pull out
  /// with `jq -r '.dueCount'`. Asserted on the encoded bytes so renaming the field
  /// breaks here rather than silently breaking the SketchyBar plugin.
  func testEncodesDueCountFieldExternalReadersParse() throws {
    let data = try StudyStatusFile.encode(
      StudyStatusFile.Status(dueCount: 7, updatedAt: "2026-08-05T09:00:00Z"))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"dueCount\":7"), json)
    XCTAssertTrue(json.contains("\"updatedAt\":\"2026-08-05T09:00:00Z\""), json)
  }

  func testWriteRoundTripsAndIsOwnerOnly() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    StudyStatusFile.write(dueCount: 12, now: now, to: fileURL)

    let decoded = try JSONDecoder().decode(
      StudyStatusFile.Status.self, from: try Data(contentsOf: fileURL))
    XCTAssertEqual(decoded.dueCount, 12)
    XCTAssertFalse(decoded.updatedAt.isEmpty)

    let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(mode?.int16Value, 0o600)
  }

  /// Zero must be published, not represented by an absent file — the reader needs
  /// "nothing due" stated so it can hide its indicator.
  func testZeroDueCountIsWrittenExplicitly() throws {
    StudyStatusFile.write(dueCount: 0, now: Date(timeIntervalSince1970: 1), to: fileURL)
    let decoded = try JSONDecoder().decode(
      StudyStatusFile.Status.self, from: try Data(contentsOf: fileURL))
    XCTAssertEqual(decoded.dueCount, 0)
  }

  func testWriteCreatesMissingParentDirectory() throws {
    let nested = directory.appendingPathComponent("a/b/study-status.json")
    StudyStatusFile.write(dueCount: 3, now: Date(timeIntervalSince1970: 1), to: nested)
    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
  }

  /// A write into an unwritable location must be swallowed, never thrown or crashed —
  /// publishing a status file can't be allowed to disturb the app.
  func testUnwritableDestinationIsSilentlyIgnored() {
    StudyStatusFile.write(
      dueCount: 1, now: Date(timeIntervalSince1970: 1),
      to: URL(fileURLWithPath: "/System/nope/study-status.json"))
  }
}
