import XCTest

@testable import Bex

final class QuickCheckLifecycleTests: XCTestCase {
  func testTransientDismissalsPreserveSession() {
    XCTAssertEqual(
      QuickCheckDismissalReason.applicationDeactivated.sessionDisposition,
      .preserve
    )
    XCTAssertEqual(
      QuickCheckDismissalReason.auxiliaryNavigation.sessionDisposition,
      .preserve
    )
  }

  func testExplicitDismissalsDiscardSession() {
    XCTAssertEqual(QuickCheckDismissalReason.explicitCancel.sessionDisposition, .discard)
    XCTAssertEqual(QuickCheckDismissalReason.windowClose.sessionDisposition, .discard)
  }

  func testSuccessfulCompletionHasDistinctDisposition() {
    XCTAssertEqual(QuickCheckDismissalReason.completed.sessionDisposition, .complete)
  }
}
