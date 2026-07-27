import Foundation
import XCTest

@testable import Bex

final class LearningLogSamplesTests: XCTestCase {
  private func makeEntry(timestamp: String, original: String = "he go store") -> LearningLogStore.Entry {
    LearningLogStore.Entry(
      timestamp: timestamp,
      client: "claude-code",
      original: original,
      corrected: "He went to the store.",
      explanation: "Fixed:\n[verb-tense] \"go\" → \"went\" — past tense.",
      provider: "openai",
      model: "gpt-5.6-sol"
    )
  }

  func testParsesValidISO8601Timestamp() {
    let entry = makeEntry(timestamp: "2024-01-08T12:00:00Z")

    let samples = LearningLogSamples.parse([entry])

    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples[0].original, entry.original)
    XCTAssertEqual(samples[0].explanation, entry.explanation)
    XCTAssertEqual(
      samples[0].date,
      ISO8601DateFormatter().date(from: "2024-01-08T12:00:00Z")
    )
  }

  func testSkipsEntriesWithUnparsableTimestamps() {
    let valid = makeEntry(timestamp: "2024-01-08T12:00:00Z", original: "valid entry")
    let malformed = makeEntry(timestamp: "not-a-date", original: "malformed entry")
    let empty = makeEntry(timestamp: "", original: "empty timestamp entry")

    let samples = LearningLogSamples.parse([valid, malformed, empty])

    XCTAssertEqual(samples.count, 1)
    XCTAssertEqual(samples[0].original, "valid entry")
  }

  func testEmptyInputYieldsEmptyOutput() {
    XCTAssertEqual(LearningLogSamples.parse([]), [])
  }
}
