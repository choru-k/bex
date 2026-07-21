import AppKit
import XCTest

@testable import Bex

final class QuickCheckPanelTests: XCTestCase {
  func testPlainReturnRemainsAvailableToMultilineEditor() {
    XCTAssertNil(
      QuickCheckPanelController.command(
        keyCode: 36,
        charactersIgnoringModifiers: "\r",
        modifierFlags: []
      )
    )
  }

  func testCommandReturnIsPhasePrimaryAndCommandBracketIsBack() {
    XCTAssertEqual(
      QuickCheckPanelController.command(
        keyCode: 36,
        charactersIgnoringModifiers: "\r",
        modifierFlags: [.command]
      ),
      .primaryAction
    )
    XCTAssertEqual(
      QuickCheckPanelController.command(
        keyCode: 33,
        charactersIgnoringModifiers: "[",
        modifierFlags: [.command]
      ),
      .back
    )
  }

  func testEscapeIsCancelAndShiftCommandCRemainsCopy() {
    XCTAssertEqual(
      QuickCheckPanelController.command(
        keyCode: 53,
        charactersIgnoringModifiers: nil,
        modifierFlags: []
      ),
      .cancel
    )
    XCTAssertEqual(
      QuickCheckPanelController.command(
        keyCode: 8,
        charactersIgnoringModifiers: "c",
        modifierFlags: [.command, .shift]
      ),
      .copy
    )
  }

  @MainActor
  func testPanelCanBecomeKeyButNeverMain() {
    let panel = QuickCheckPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
  }

}
