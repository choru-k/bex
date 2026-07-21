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
    typeTextReliably("saved text", into: input)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(app.windows["Quick Check"].waitForNonExistence(timeout: 3))

    openMenuCommand("Quick Check", in: app)
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "saved text")
    input.click()
    input.typeKey("a", modifierFlags: .command)
    input.typeKey(.delete, modifierFlags: [])
    XCTAssertEqual(input.value as? String, "")
    typeTextReliably("this are a test", into: input)

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

    openMenuCommand("Quick Check", in: app)
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

  func testPromptGateDisclosureReviewEditCancelAndReopen() throws {
    continueAfterFailure = false
    let (app, targetSink) = launchPromptGate()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
    }

    let disclosure = app.descendants(matching: .any)["prompt-gate-disclosure"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))
    app.buttons["prompt-gate-continue"].click()

    let corrected = awaitPromptCorrection(in: app)
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    XCTAssertEqual(corrected.value as? String, expected)
    XCTAssertTrue((corrected.value as? String)?.contains("/tmp/a.swift") == true)
    XCTAssertTrue((corrected.value as? String)?.contains("--dry-run") == true)
    XCTAssertTrue((corrected.value as? String)?.contains("https://example.com/a?q=1") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))

    corrected.click()
    corrected.typeText(" please")
    XCTAssertEqual(corrected.value as? String, expected + " please")
    let editedDiff = app.staticTexts["prompt-gate-diff"]
    let editedDiffPredicate = NSPredicate(
      format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
      "please",
      "please"
    )
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: editedDiffPredicate, object: editedDiff)],
        timeout: 3
      ),
      .completed
    )

    app.buttons["prompt-gate-cancel"].click()
    XCTAssertTrue(app.windows["Fix & Send"].waitForNonExistence(timeout: 3))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))

    openMenuCommand("Fix & Send", in: app)
    let reopened = awaitPromptCorrection(in: app)
    XCTAssertEqual(reopened.value as? String, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))
    app.buttons["prompt-gate-cancel"].click()
  }

  func testPromptGateSendsOnlyApprovedCorrectionOnce() throws {
    continueAfterFailure = false
    let (app, targetSink) = launchPromptGate()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
    }

    XCTAssertTrue(
      app.descendants(matching: .any)["prompt-gate-disclosure"].waitForExistence(timeout: 5)
    )
    app.buttons["prompt-gate-continue"].click()
    let corrected = awaitPromptCorrection(in: app)
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    XCTAssertEqual(corrected.value as? String, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))

    let send = app.buttons["prompt-gate-send"]
    XCTAssertTrue(send.isEnabled)
    send.click()
    XCTAssertTrue(app.windows["Fix & Send"].waitForNonExistence(timeout: 3))
    XCTAssertEqual(try String(contentsOf: targetSink, encoding: .utf8), expected)
    XCTAssertFalse(app.buttons["prompt-gate-send"].exists)
    Thread.sleep(forTimeInterval: 0.2)
    XCTAssertEqual(try String(contentsOf: targetSink, encoding: .utf8), expected)
  }

  func testPromptGateDeliveryFailureRetainsReviewWithoutWritingTarget() {
    continueAfterFailure = false
    let (app, targetSink) = launchPromptGate(deliveryError: true)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
    }

    XCTAssertTrue(
      app.descendants(matching: .any)["prompt-gate-disclosure"].waitForExistence(timeout: 5)
    )
    app.buttons["prompt-gate-continue"].click()
    let corrected = awaitPromptCorrection(in: app)
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    XCTAssertEqual(corrected.value as? String, expected)
    app.buttons["prompt-gate-send"].click()

    let error = app.descendants(matching: .any)["prompt-gate-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 3))
    XCTAssertTrue(((error.value as? String) ?? error.label).contains("Forced UI test delivery failure."))
    XCTAssertTrue(app.windows["Fix & Send"].exists)
    XCTAssertEqual(app.textViews["prompt-gate-corrected"].value as? String, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))
  }

  func testStandardAXPromptGateSmoke() throws {
    continueAfterFailure = false
    let source = "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    let documentURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexAXSmoke-\(UUID().uuidString).txt")
    try source.write(to: documentURL, atomically: true, encoding: .utf8)

    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["BEX_UI_TESTING"] = "1"
    app.launchEnvironment["BEX_UI_TEST_REAL_TARGET"] = "1"
    app.launch()
    Thread.sleep(forTimeInterval: 1)

    let opener = Process()
    opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    opener.arguments = ["-a", "TextEdit", documentURL.path]
    try opener.run()
    opener.waitUntilExit()
    XCTAssertEqual(opener.terminationStatus, 0)

    let target = XCUIApplication(bundleIdentifier: "com.apple.TextEdit")
    defer {
      target.terminate()
      app.terminate()
      try? FileManager.default.removeItem(at: documentURL)
    }
    XCTAssertTrue(target.wait(for: .runningForeground, timeout: 5))
    target.activate()
    let editor = target.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    XCTAssertEqual(editor.value as? String, source)

    openMenuCommand("Fix & Send", in: app)
    Thread.sleep(forTimeInterval: 1)
    let disclosure = app.descendants(matching: .any)["prompt-gate-disclosure"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
    let accessibilityStatus = app.staticTexts["prompt-gate-accessibility-status"]
    XCTAssertTrue(accessibilityStatus.waitForExistence(timeout: 2))
    guard accessibilityStatus.label.contains("enabled") else {
      throw XCTSkip("Bex does not have Accessibility access on this runner.")
    }
    app.buttons["prompt-gate-continue"].click()
    XCTAssertEqual(awaitPromptCorrection(in: app).value as? String, expected)
    app.buttons["prompt-gate-send"].click()

    let replaced = NSPredicate(format: "value == %@", expected)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: replaced, object: editor)],
        timeout: 5
      ),
      .completed
    )
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

  private func launchPromptGate(deliveryError: Bool = false) -> (XCUIApplication, URL) {
    let targetSink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestPromptTarget-\(UUID().uuidString).txt")
    let copySink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestPromptCopy-\(UUID().uuidString).txt")
    try? FileManager.default.removeItem(at: targetSink)
    try? FileManager.default.removeItem(at: copySink)
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--open-prompt-gate"]
    app.launchEnvironment["BEX_UI_TESTING"] = "1"
    app.launchEnvironment["BEX_UI_TEST_OPEN_PROMPT_GATE"] = "1"
    app.launchEnvironment["BEX_UI_TEST_PROMPT_SOURCE"] =
      "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    app.launchEnvironment["BEX_UI_TEST_PROMPT_TARGET_PATH"] = targetSink.path
    app.launchEnvironment["BEX_UI_TEST_PASTEBOARD_PATH"] = copySink.path
    if deliveryError {
      app.launchEnvironment["BEX_UI_TEST_PROMPT_DELIVERY_ERROR"] = "1"
    }
    app.launch()
    return (app, targetSink)
  }

  private func awaitPromptCorrection(in app: XCUIApplication) -> XCUIElement {
    XCTAssertTrue(app.windows["Fix & Send"].waitForExistence(timeout: 5))
    let corrected = app.textViews["prompt-gate-corrected"]
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    let predicate = NSPredicate(format: "value == %@", expected)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: corrected)],
        timeout: 10
      ),
      .completed
    )
    return corrected
  }


  private func typeTextReliably(_ text: String, into element: XCUIElement) {
    element.typeText(text + "00")
    guard let entered = element.value as? String, entered.hasPrefix(text) else {
      XCTFail(
        "Could not enter UI test text. Expected prefix \(text), got \(String(describing: element.value))."
      )
      return
    }
    for _ in 0..<(entered.count - text.count) {
      element.typeKey(.delete, modifierFlags: [])
    }
    XCTAssertEqual(element.value as? String, text)
  }

  private func openMenuCommand(_ title: String, in app: XCUIApplication) {
    let name: Notification.Name
    switch title {
    case "Quick Check":
      name = Notification.Name("com.bex.desktop.ui-testing.open-quick-check")
    case "Fix & Send":
      name = Notification.Name("com.bex.desktop.ui-testing.open-prompt-gate")
    default:
      XCTFail("Unknown UI-test command: \(title)")
      return
    }
    DistributedNotificationCenter.default().postNotificationName(
      name,
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
  }

}

extension XCUIElement {
  fileprivate func waitForNonExistence(timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "exists == false")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
