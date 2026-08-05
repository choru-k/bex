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
      StudyStatusFile.Status(
        dueCount: 7, updatedAt: "2026-08-05T09:00:00Z", severity: "normal", nextCard: nil,
        lastResult: nil))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"dueCount\":7"), json)
    XCTAssertTrue(json.contains("\"updatedAt\":\"2026-08-05T09:00:00Z\""), json)
  }

  /// A SketchyBar plugin wanting to color the indicator needs `severity` alongside
  /// `dueCount` — asserted on the encoded bytes for the same reason as `dueCount` above.
  func testEncodesSeverityFieldExternalReadersParse() throws {
    let data = try StudyStatusFile.encode(
      StudyStatusFile.Status(
        dueCount: 7, updatedAt: "2026-08-05T09:00:00Z", severity: "late", nextCard: nil,
        lastResult: nil))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"severity\":\"late\""), json)
  }

  /// `nextCard` is what the bar renders as clickable rows, so its nested shape
  /// (`id`/`prompt`/`choices`) is asserted on the encoded bytes exactly like the flat
  /// fields above — a plugin depends on this shape too.
  func testEncodesNextCardAsNestedObject() throws {
    let data = try StudyStatusFile.encode(
      StudyStatusFile.Status(
        dueCount: 1, updatedAt: "2026-08-05T09:00:00Z", severity: "normal",
        nextCard: StudyStatusFile.NextCard(
          id: "article|a go|the went", prompt: "I need _____ to the store.",
          choices: ["a", "the"]),
        lastResult: nil))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"nextCard\":{"), json)
    XCTAssertTrue(json.contains("\"id\":\"article|a go|the went\""), json)
    XCTAssertTrue(json.contains("\"prompt\":\"I need _____ to the store.\""), json)
    XCTAssertTrue(json.contains("\"choices\":[\"a\",\"the\"]"), json)
  }

  /// `lastResult` is how the bar shows the outcome of the click it just sent —
  /// asserted on the encoded bytes for the same reason as `nextCard` above.
  func testEncodesLastResultFields() throws {
    let data = try StudyStatusFile.encode(
      StudyStatusFile.Status(
        dueCount: 1, updatedAt: "2026-08-05T09:00:00Z", severity: "normal", nextCard: nil,
        lastResult: StudyStatusFile.LastResult(wasCorrect: false, correctAnswer: "the")))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertTrue(json.contains("\"lastResult\":{"), json)
    XCTAssertTrue(json.contains("\"wasCorrect\":false"), json)
    XCTAssertTrue(json.contains("\"correctAnswer\":\"the\""), json)
  }

  /// A plugin distinguishes "no next card" / "no result yet" from a malformed value —
  /// so both fields must be entirely absent from the JSON when `nil`, not encoded as
  /// `null`.
  func testNilNextCardAndLastResultAreOmittedFromJSON() throws {
    let data = try StudyStatusFile.encode(
      StudyStatusFile.Status(
        dueCount: 0, updatedAt: "2026-08-05T09:00:00Z", severity: "normal", nextCard: nil,
        lastResult: nil))
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(json.contains("nextCard"), json)
    XCTAssertFalse(json.contains("lastResult"), json)
  }

  func testWriteRoundTripsAndIsOwnerOnly() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    StudyStatusFile.write(
      dueCount: 12, severity: .normal, nextCard: nil, lastResult: nil, now: now, to: fileURL)

    let decoded = try JSONDecoder().decode(
      StudyStatusFile.Status.self, from: try Data(contentsOf: fileURL))
    XCTAssertEqual(decoded.dueCount, 12)
    XCTAssertFalse(decoded.updatedAt.isEmpty)
    XCTAssertEqual(decoded.severity, "normal")
    XCTAssertNil(decoded.nextCard)
    XCTAssertNil(decoded.lastResult)

    let mode = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(mode?.int16Value, 0o600)
  }

  /// Round-tripping `write` with both optional values present, confirming the
  /// nested objects survive encode-then-decode intact.
  func testWriteRoundTripsWithNextCardAndLastResult() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let nextCard = StudyStatusFile.NextCard(
      id: "article|a go|the went", prompt: "I need _____ to the store.", choices: ["a", "the"])
    let lastResult = StudyStatusFile.LastResult(wasCorrect: true, correctAnswer: "the")
    StudyStatusFile.write(
      dueCount: 5, severity: .behind, nextCard: nextCard, lastResult: lastResult, now: now,
      to: fileURL)

    let decoded = try JSONDecoder().decode(
      StudyStatusFile.Status.self, from: try Data(contentsOf: fileURL))
    XCTAssertEqual(decoded.nextCard, nextCard)
    XCTAssertEqual(decoded.lastResult, lastResult)
  }

  /// Zero must be published, not represented by an absent file — the reader needs
  /// "nothing due" stated so it can hide its indicator.
  func testZeroDueCountIsWrittenExplicitly() throws {
    StudyStatusFile.write(
      dueCount: 0, severity: .normal, nextCard: nil, lastResult: nil,
      now: Date(timeIntervalSince1970: 1), to: fileURL)
    let decoded = try JSONDecoder().decode(
      StudyStatusFile.Status.self, from: try Data(contentsOf: fileURL))
    XCTAssertEqual(decoded.dueCount, 0)
  }

  func testWriteCreatesMissingParentDirectory() throws {
    let nested = directory.appendingPathComponent("a/b/study-status.json")
    StudyStatusFile.write(
      dueCount: 3, severity: .normal, nextCard: nil, lastResult: nil,
      now: Date(timeIntervalSince1970: 1), to: nested)
    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
  }

  /// A write into an unwritable location must be swallowed, never thrown or crashed —
  /// publishing a status file can't be allowed to disturb the app.
  func testUnwritableDestinationIsSilentlyIgnored() {
    StudyStatusFile.write(
      dueCount: 1, severity: .normal, nextCard: nil, lastResult: nil,
      now: Date(timeIntervalSince1970: 1),
      to: URL(fileURLWithPath: "/System/nope/study-status.json"))
  }
}
