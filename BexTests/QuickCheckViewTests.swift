import XCTest

@testable import Bex

@MainActor
final class QuickCheckViewTests: XCTestCase {
  func testEditorHeightExpandsWithWindowAndRemainsBounded() {
    XCTAssertEqual(QuickCheckLayout.editorHeight(for: 300), 120)
    XCTAssertEqual(QuickCheckLayout.editorHeight(for: 600), 180)
    XCTAssertEqual(QuickCheckLayout.editorHeight(for: 1_200), 280)
  }

  func testBexStandardAndStorageDisclosureTerminology() {
    let disclosure = QuickCheckViewModel.historyStorageDisclosure
    XCTAssertTrue(disclosure.contains("Writing Style"))
    XCTAssertTrue(disclosure.contains("up to 500 items"))
    XCTAssertTrue(disclosure.contains("Fix & Send is not stored"))
    XCTAssertFalse(disclosure.contains("Profile"))
  }

  func testOutboundSummaryCarriesFullGuidanceOnlyWhenWritingStyleIsSent() {
    let guidance = QuickCheckOutboundWritingStyle(
      name: "Direct",
      guidance: "Prefer short sentences.\nKeep every technical qualifier."
    )
    let check = QuickCheckOutboundSummary(
      action: "Check draft",
      provider: "OpenAI",
      model: "gpt-test",
      writingStyle: guidance,
      fullDraft: "Draft",
      disclosure: "Disclosure"
    )
    let rewrite = QuickCheckOutboundSummary(
      action: "Apply More Formal",
      provider: "OpenAI",
      model: "gpt-test",
      writingStyle: nil,
      fullDraft: "Corrected draft",
      disclosure: "Disclosure"
    )

    XCTAssertEqual(check.writingStyle?.guidance, guidance.guidance)
    XCTAssertNil(rewrite.writingStyle)
  }
}
