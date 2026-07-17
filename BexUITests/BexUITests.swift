import XCTest

@MainActor
final class BexUITests: XCTestCase {
  func testCheckRewriteCopyCloseAndHistory() throws {
    continueAfterFailure = false
    let (app, copySink) = launch(openQuickCheck: true)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: copySink)
    }

    var input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.click()
    input.typeText("draft survives")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.windows["Quick Check"].waitForNonExistence(timeout: 3))

    app.typeKey("g", modifierFlags: [.command, .shift])
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "draft survives")
    input.click()
    input.typeKey("a", modifierFlags: .command)
    input.typeKey(.delete, modifierFlags: [])
    XCTAssertEqual(input.value as? String, "")
    input.typeText("this are a test")

    let check = app.buttons["quick-check-check"]
    XCTAssertTrue(check.isEnabled)
    check.click()

    let corrected = app.staticTexts["quick-check-corrected"]
    XCTAssertTrue(corrected.waitForExistence(timeout: 5))
    XCTAssertEqual(corrected.value as? String, "this is a test")
    XCTAssertEqual(
      app.staticTexts["quick-check-explanation"].value as? String,
      "Changed subject-verb agreement."
    )
    XCTAssertEqual(
      app.staticTexts["quick-check-diff"].value as? String,
      "Removed: are, Inserted: is"
    )

    let formal = app.buttons["quick-check-rewrite-formal"]
    XCTAssertTrue(formal.waitForExistence(timeout: 2))
    formal.click()
    let formalResult = app.staticTexts["quick-check-corrected"]
    let formalValue = NSPredicate(format: "value == %@", "This is a test.")
    let formalExpectation = XCTNSPredicateExpectation(
      predicate: formalValue,
      object: formalResult
    )
    XCTAssertEqual(XCTWaiter.wait(for: [formalExpectation], timeout: 5), .completed)
    XCTAssertTrue(
      ((app.staticTexts["quick-check-explanation"].value as? String) ?? "")
        .contains("Rewrite applied: More Formal")
    )

    app.buttons["quick-check-copy-close"].click()
    XCTAssertTrue(app.windows["Quick Check"].waitForNonExistence(timeout: 3))
    XCTAssertEqual(
      try String(contentsOf: copySink, encoding: .utf8),
      "This is a test."
    )

    app.typeKey("g", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.textViews["quick-check-input"].waitForExistence(timeout: 5))
    let historyLink = app.links["quick-check-history"]
    XCTAssertTrue(historyLink.waitForExistence(timeout: 3))
    historyLink.click()
    let historyWindow = app.windows["History"]
    XCTAssertTrue(historyWindow.waitForExistence(timeout: 5))
    XCTAssertEqual(historyWindow.disclosureTriangles.count, 1)
    historyWindow.disclosureTriangles.firstMatch.click()
    let historyCorrected = historyWindow.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'Corrected'")
    ).firstMatch
    XCTAssertTrue(historyCorrected.waitForExistence(timeout: 3))
    XCTAssertEqual(historyCorrected.value as? String, "This is a test.")
    let rewrittenExplanation = historyWindow.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'Explanation'")
    ).firstMatch
    XCTAssertTrue(rewrittenExplanation.waitForExistence(timeout: 3))
    XCTAssertTrue(
      ((rewrittenExplanation.value as? String) ?? "")
        .contains("Rewrite applied: More Formal")
    )
  }

  func testMissingCredentialShowsSetupAndNavigatesToSettings() {
    continueAfterFailure = false
    let (app, copySink) = launch(openQuickCheck: true, missingCredential: true)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: copySink)
    }

    let quickCheck = app.windows["Quick Check"]
    XCTAssertTrue(quickCheck.waitForExistence(timeout: 5))
    XCTAssertTrue(quickCheck.staticTexts["Setup required"].waitForExistence(timeout: 3))
    XCTAssertTrue(quickCheck.staticTexts["Add your OpenAI API key in Settings."].exists)
    XCTAssertFalse(quickCheck.buttons["quick-check-check"].isEnabled)

    quickCheck.buttons["quick-check-open-settings"].click()
    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["settings-effort"].waitForExistence(timeout: 3))
    XCTAssertFalse(quickCheck.exists)
  }

  private func launch(
    openQuickCheck: Bool,
    missingCredential: Bool = false
  ) -> (XCUIApplication, URL) {
    let copySink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestCopy-\(UUID().uuidString).txt")
    try? FileManager.default.removeItem(at: copySink)
    let app = XCUIApplication()
    app.launchEnvironment["BEX_UI_TESTING"] = "1"
    app.launchArguments = ["--ui-testing"]
    if openQuickCheck {
      app.launchArguments.append("--open-quick-check")
      app.launchEnvironment["BEX_UI_TEST_OPEN_QUICK_CHECK"] = "1"
    }
    if missingCredential {
      app.launchArguments.append("--missing-credential")
      app.launchEnvironment["BEX_UI_TEST_MISSING_CREDENTIAL"] = "1"
    }
    app.launchEnvironment["BEX_UI_TEST_PASTEBOARD_PATH"] = copySink.path
    app.launch()
    return (app, copySink)
  }

}

extension XCUIElement {
  fileprivate func waitForNonExistence(timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
