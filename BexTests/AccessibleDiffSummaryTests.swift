import XCTest

@testable import Bex

final class AccessibleDiffSummaryTests: XCTestCase {
  func testNoChangeHasExactFallback() {
    XCTAssertEqual(AccessibleDiffSummary.make(from: []), "No differences")
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [segment("Already correct.", .unchanged)]),
      "No differences"
    )
  }

  func testStartAndEndInsertionsAndRemovals() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("Well, ", .inserted),
        segment("hello.", .unchanged),
      ]),
      "Inserted “Well,”, then one space before “hello.”"
    )
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("Hello", .unchanged),
        segment("!", .inserted),
      ]),
      "Inserted “!” after “Hello”"
    )
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("Well, ", .removed),
        segment("hello.", .unchanged),
      ]),
      "Removed “Well,”, then one space before “hello.”"
    )
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("Hello", .unchanged),
        segment("!", .removed),
      ]),
      "Removed “!” after “Hello”"
    )
  }

  func testReplacementReportsChangesInSourceOrder() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("This ", .unchanged),
        segment("are", .removed),
        segment("is", .inserted),
        segment(" correct.", .unchanged),
      ]),
      "Removed “are” between “This” and “correct.”; "
        + "Inserted “is” between “This” and “correct.”"
    )
  }

  func testRepeatedAndSeparatedEditsIncludeDisambiguatingContext() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("red cat, ", .unchanged),
        segment("red", .removed),
        segment("blue", .inserted),
        segment(" cat, red ", .unchanged),
        segment("cat", .removed),
        segment("dog", .inserted),
        segment("!", .unchanged),
      ]),
      "Removed “red” between “red cat,” and “cat, red”; "
        + "Inserted “blue” between “red cat,” and “cat, red”; "
        + "Removed “cat” between “cat, red” and “!”; "
        + "Inserted “dog” between “cat, red” and “!”"
    )
  }

  func testContextIsNormalizedAndBounded() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("abcdefghijklmnopqrstuvwxyz", .unchanged),
        segment("x", .inserted),
        segment("ABCDEFGHIJKLMNOPQRSTUVWXYZ", .unchanged),
      ]),
      "Inserted “x” between “…cdefghijklmnopqrstuvwxyz” "
        + "and “ABCDEFGHIJKLMNOPQRSTUVWX…”"
    )
  }

  func testPunctuationRemainsIntelligible() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("Hello", .unchanged),
        segment(",", .removed),
        segment(";", .inserted),
        segment(" world!", .unchanged),
      ]),
      "Removed “,” between “Hello” and “world!”; "
        + "Inserted “;” between “Hello” and “world!”"
    )
  }

  func testWhitespaceChangesAreSpokenExplicitly() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("Hello", .unchanged),
        segment("  \t", .removed),
        segment(" ", .inserted),
        segment("world", .unchanged),
      ]),
      "Removed 2 spaces, then one tab between “Hello” and “world”; "
        + "Inserted one space between “Hello” and “world”"
    )
  }

  func testMultilineChangesNameLineBreaksAndNormalizeContext() {
    XCTAssertEqual(
      AccessibleDiffSummary.make(from: [
        segment("First\tline ", .unchanged),
        segment("old\ntext", .removed),
        segment("new\ntext", .inserted),
        segment("\nLast   line", .unchanged),
      ]),
      "Removed “old”, then one line break, then “text” between “First line” and “Last line”; "
        + "Inserted “new”, then one line break, then “text” between “First line” and “Last line”"
    )
  }

  func testDiffChangeGroupsReplacementFromWordDiff() {
    XCTAssertEqual(
      changes("This are correct.", "This is correct."),
      [DiffChange(oldText: "are", newText: "is")]
    )
  }

  func testDiffChangePreservesOrderedMultipleReplacements() {
    XCTAssertEqual(
      changes("i has teh file", "I have the file"),
      [
        DiffChange(oldText: "i", newText: "I"),
        DiffChange(oldText: "has", newText: "have"),
        DiffChange(oldText: "teh", newText: "the"),
      ]
    )
  }

  func testDiffChangeHandlesOneSidedAndEqualInputs() {
    XCTAssertEqual(
      changes("", "Inserted"),
      [DiffChange(oldText: "", newText: "Inserted")]
    )
    XCTAssertEqual(
      changes("Removed", ""),
      [DiffChange(oldText: "Removed", newText: "")]
    )
    XCTAssertEqual(changes("Equal", "Equal"), [])
  }

  func testDiffChangeKeepsPunctuationAttached() {
    XCTAssertEqual(
      changes("Hello,", "Hello;"),
      [DiffChange(oldText: "Hello,", newText: "Hello;")]
    )
  }

  func testDiffChangePreservesWhitespaceOnlyReplacement() {
    XCTAssertEqual(
      changes("Hello  world", "Hello\tworld"),
      [DiffChange(oldText: "  ", newText: "\t")]
    )
  }

  func testDiffChangePreservesInsertedTrailingSpace() {
    XCTAssertEqual(
      changes("Hello", "Hello "),
      [DiffChange(oldText: "", newText: " ")]
    )
  }

  func testDiffChangePreservesMixedTabAndLineBreakKinds() {
    XCTAssertEqual(
      changes("a\tb\nc\r\nd", "a b\r\nc\nd"),
      [
        DiffChange(oldText: "\t", newText: " "),
        DiffChange(oldText: "\nc", newText: ""),
        DiffChange(oldText: "", newText: "c\n"),
      ]
    )
  }

  func testDiffChangeDefensivelyGroupsInterleavedChangedSegments() {
    XCTAssertEqual(
      DiffChange.make(from: [
        segment("a", .removed),
        segment("b", .inserted),
        segment("c", .removed),
        segment("d", .inserted),
      ]),
      [DiffChange(oldText: "ac", newText: "bd")]
    )
  }

  private func changes(_ original: String, _ corrected: String) -> [DiffChange] {
    DiffChange.make(from: WordDiff.compute(original: original, corrected: corrected))
  }

  private func segment(_ text: String, _ kind: DiffSegment.Kind) -> DiffSegment {
    DiffSegment(text: text, kind: kind)
  }
}
