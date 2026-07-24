import Foundation
import XCTest

@testable import Bex

final class LearningLogStoreTests: XCTestCase {
  func testAppendRoundTripsFieldsAndWritesOwnerOnlyFile() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LearningLogStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    let store = LearningLogStore(directoryURL: directory, now: { fixedNow })

    await store.append(
      client: "claude-code",
      original: "he go to store yesterday",
      corrected: "He went to the store yesterday.",
      explanation: "[verb-tense] \"go\" -> \"went\" for past tense.",
      provider: "openai",
      model: "gpt-5.6-sol"
    )

    let fileURL = directory.appendingPathComponent("learning-log.jsonl")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
    XCTAssertEqual(lines.count, 1)

    let entry = try JSONDecoder().decode(LearningLogStore.Entry.self, from: Data(lines[0].utf8))
    XCTAssertEqual(entry.client, "claude-code")
    XCTAssertEqual(entry.original, "he go to store yesterday")
    XCTAssertEqual(entry.corrected, "He went to the store yesterday.")
    XCTAssertEqual(entry.explanation, "[verb-tense] \"go\" -> \"went\" for past tense.")
    XCTAssertEqual(entry.provider, "openai")
    XCTAssertEqual(entry.model, "gpt-5.6-sol")
    XCTAssertEqual(entry.timestamp, ISO8601DateFormatter().string(from: fixedNow))

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let filePermissions = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(filePermissions.uint16Value & 0o777, 0o600)

    let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    let directoryPermissions = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(directoryPermissions.uint16Value & 0o777, 0o700)
  }
}
