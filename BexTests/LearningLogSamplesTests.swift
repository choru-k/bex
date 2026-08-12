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

  /// Provenance drives the card tint (design 3b): corrections stay `.correction`,
  /// ask-thread saves become `.ask`, tapped alternatives become `.pick` — and the
  /// source rides through `StudyCardBuilder` onto the card itself.
  func testSampleSourceFollowsProvenanceAndReachesTheCard() {
    let correction = makeEntry(timestamp: "2024-01-08T12:00:00Z")
    var ask = makeEntry(timestamp: "2024-01-08T13:00:00Z", original: "let me shortly explain")
    ask = LearningLogStore.Entry(
      timestamp: ask.timestamp,
      client: "bex-ask",
      original: ask.original,
      corrected: "let me briefly explain",
      explanation: "Fixed:\n[expression] \"shortly\" → \"briefly\" — shortly means soon.",
      provider: ask.provider,
      model: ask.model
    )
    let tap = ConsiderTap(
      timestamp: "2024-01-08T14:00:00Z",
      sourceOriginal: "can you check this",
      phrase: "can you check",
      alternative: "could you check",
      reason: "softer"
    )

    let samples = LearningLogSamples.merged([correction, ask], taps: [tap])
    XCTAssertEqual(samples.map(\.source), [.correction, .ask, .pick])

    let cards = StudyCardBuilder.cards(from: samples)
    XCTAssertEqual(cards.count, 3)
    XCTAssertEqual(cards.map(\.source), [.correction, .ask, .pick])
  }
}
