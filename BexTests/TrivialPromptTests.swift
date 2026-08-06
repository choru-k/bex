import Foundation
import XCTest

@testable import Bex

final class TrivialPromptTests: XCTestCase {
  func testAcknowledgementsAreSkipped() {
    for prompt in [
      "yes", "Yes", "yes.", "Yes!", "y", "ok", "OK.", "okay", "sure", "no", "nope",
      "go", "go ahead", "Go ahead.", "next", "continue", "do it", "done", "thanks",
      "  yes  ", "yes?",
    ] {
      XCTAssertTrue(TrivialPrompt.isTrivial(prompt), "should skip: \(prompt)")
    }
  }

  /// The reason this is a closed list and not a length rule. Some of the owner's most
  /// useful cards are two words long, and a size cutoff would silently delete them.
  func testShortButCorrectablePromptsAreNotSkipped() {
    for prompt in [
      "check status",  // -> "check the status"
      "make commit",  // -> "make a commit"
      "do rebase",  // -> "do a rebase"
      "agreed on",  // -> "agreed with"
      "it show",  // -> "it shows"
      "yes but the deploy failed",  // starts with an acknowledgement, is not one
      "ok so what about the article",
      "continue the migration",
    ] {
      XCTAssertFalse(TrivialPrompt.isTrivial(prompt), "should NOT skip: \(prompt)")
    }
  }

  func testEmptyAndPunctuationOnlyPromptsAreSkipped() {
    XCTAssertTrue(TrivialPrompt.isTrivial(""))
    XCTAssertTrue(TrivialPrompt.isTrivial("   "))
    XCTAssertTrue(TrivialPrompt.isTrivial("."))
  }
}
