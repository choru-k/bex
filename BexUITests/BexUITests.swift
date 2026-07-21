import XCTest

@MainActor
final class BexUITests: XCTestCase {
  func testWelcomeIntroducesCoreWorkflowsAndContinuesToSettings() throws {
    continueAfterFailure = false
    let app = launchScenario("welcome")
    defer { app.terminate() }

    XCTAssertTrue(app.windows["Welcome to Bex"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Quick Check"].exists)
    XCTAssertTrue(app.staticTexts["Fix & Send"].exists)
    XCTAssertTrue(app.staticTexts["You stay in control"].exists)

    app.buttons["welcome-set-up-provider"].click()
    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.windows["Welcome to Bex"].waitForNonExistence(timeout: 3))
  }

  func testCheckRewriteCopyCloseAndHistory() throws {
    continueAfterFailure = false
    let (app, copySink) = launch(openQuickCheck: true, scenario: "configured-provider")
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
    XCTAssertEqual(input.value as? String, "")
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
    let diffElement = app.descendants(matching: .any)["quick-check-diff"]
    let diffSummary = accessibilityText(of: diffElement)
    XCTAssertTrue(diffSummary.contains("Removed “are” between"))
    XCTAssertTrue(diffSummary.contains("Inserted “is” between"))

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
    XCTAssertTrue(app.descendants(matching: .any)["settings-provider"].waitForExistence(timeout: 3))
    XCTAssertFalse(quickCheck.exists)
  }

  func testPromptGateDisclosureReviewEditCancelAndReopen() throws {
    continueAfterFailure = false
    let (app, targetSink, deliveryEventsSink) = launchPromptGate()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    let disclosure = app.descendants(matching: .any)["prompt-gate-disclosure"]
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))
    app.buttons["prompt-gate-confirm-outbound"].click()

    let corrected = awaitPromptCorrection(in: app)
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    XCTAssertEqual(corrected.value as? String, expected)
    XCTAssertTrue((corrected.value as? String)?.contains("/tmp/a.swift") == true)
    XCTAssertTrue((corrected.value as? String)?.contains("--dry-run") == true)
    XCTAssertTrue((corrected.value as? String)?.contains("https://example.com/a?q=1") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))
    let initialDiff = app.descendants(matching: .any)["prompt-gate-diff-summary"]
    XCTAssertTrue(initialDiff.waitForExistence(timeout: 3))
    let initialDiffSummary = accessibilityText(of: initialDiff)
    XCTAssertTrue(initialDiffSummary.contains("Removed"))
    XCTAssertTrue(initialDiffSummary.contains("Inserted"))

    corrected.click()
    corrected.typeText(" please")
    XCTAssertEqual(corrected.value as? String, expected + " please")
    let editedDiff = app.descendants(matching: .any)["prompt-gate-diff-summary"]
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
    let editedDiffSummary = accessibilityText(of: editedDiff)
    XCTAssertTrue(editedDiffSummary.contains("Inserted"))
    XCTAssertTrue(editedDiffSummary.contains("please"))

    app.buttons["prompt-gate-cancel"].click()
    let discardEdits = app.buttons["Discard Edits"]
    XCTAssertTrue(discardEdits.waitForExistence(timeout: 3))
    discardEdits.click()
    XCTAssertTrue(app.windows["Fix & Send"].waitForNonExistence(timeout: 3))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))

    openMenuCommand("Fix & Send", in: app)
    XCTAssertTrue(app.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 3))
    app.buttons["prompt-gate-confirm-outbound"].click()
    let reopened = awaitPromptCorrection(in: app)
    XCTAssertEqual(reopened.value as? String, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))
    app.buttons["prompt-gate-cancel"].click()
  }

  func testPromptGateSendsOnlyApprovedCorrectionOnce() throws {
    continueAfterFailure = false
    let (app, targetSink, deliveryEventsSink) = launchPromptGate()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    XCTAssertTrue(
      app.descendants(matching: .any)["prompt-gate-disclosure"].waitForExistence(timeout: 5)
    )
    app.buttons["prompt-gate-confirm-outbound"].click()
    let corrected = awaitPromptCorrection(in: app)
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    XCTAssertEqual(corrected.value as? String, expected)
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))

    let send = app.buttons["prompt-gate-delivery-pasteAndSubmit"]
    XCTAssertTrue(send.isEnabled)
    send.click()
    XCTAssertTrue(app.windows["Fix & Send"].waitForNonExistence(timeout: 3))
    XCTAssertEqual(try String(contentsOf: targetSink, encoding: .utf8), expected)
    XCTAssertFalse(app.buttons["prompt-gate-delivery-pasteAndSubmit"].exists)
    XCTAssertEqual(
      try readDeliveryEvents(at: deliveryEventsSink),
      [RecordedDeliveryEvent(sequence: 1, effect: "submitted")]
    )
  }

  func testPromptGatePartialDeliveryExplainsEffectWithoutRetry() throws {
    continueAfterFailure = false
    let (app, targetSink, deliveryEventsSink) = launchPromptGate(deliveryError: true)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    XCTAssertTrue(
      app.descendants(matching: .any)["prompt-gate-disclosure"].waitForExistence(timeout: 5)
    )
    app.buttons["prompt-gate-confirm-outbound"].click()
    let corrected = awaitPromptCorrection(in: app)
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    XCTAssertEqual(corrected.value as? String, expected)
    app.buttons["prompt-gate-delivery-pasteAndSubmit"].click()

    let error = app.descendants(matching: .any)["prompt-gate-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 3))
    XCTAssertTrue(((error.value as? String) ?? error.label).contains("already in UI Test Target"))
    XCTAssertTrue(app.windows["Fix & Send"].exists)
    XCTAssertEqual(app.textViews["prompt-gate-corrected"].value as? String, expected)
    XCTAssertEqual(try? String(contentsOf: targetSink, encoding: .utf8), expected)
    XCTAssertTrue(app.buttons["prompt-gate-delivery-done"].exists)
    XCTAssertEqual(
      try readDeliveryEvents(at: deliveryEventsSink),
      [RecordedDeliveryEvent(sequence: 1, effect: "pastedNotSubmitted")]
    )
  }

  func testNamedFreshConsentAndConfiguredProviderScenariosLaunchTheirRoutes() {
    continueAfterFailure = false

    let freshConsent = launchScenario("fresh-consent")
    XCTAssertTrue(freshConsent.windows["Fix & Send"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      freshConsent.descendants(matching: .any)["prompt-gate-disclosure"]
        .waitForExistence(timeout: 3)
    )
    freshConsent.terminate()

    let configuredProvider = launchScenario("configured-provider")
    defer { configuredProvider.terminate() }
    XCTAssertTrue(configuredProvider.windows["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      configuredProvider.descendants(matching: .any)["settings-provider"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      configuredProvider.descendants(matching: .any)["settings-provider-connection"].exists
    )
  }
  func testFreshQuickCheckMakesRetentionChoicesAndConfirmsFullCustomPayload() {
    continueAfterFailure = false
    let app = launchScenario("fresh-quick-check")
    defer { app.terminate() }

    XCTAssertTrue(app.windows["Quick Check"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.descendants(matching: .any)["quick-check-retention-choices"]
        .waitForExistence(timeout: 3)
    )
    let enableDraft = app.buttons["quick-check-enable-draft-retention"]
    let disableHistory = app.buttons["quick-check-disable-history-retention"]
    XCTAssertTrue(enableDraft.exists)
    XCTAssertTrue(disableHistory.exists)
    enableDraft.click()
    XCTAssertTrue(enableDraft.waitForNonExistence(timeout: 3))
    disableHistory.click()
    XCTAssertTrue(disableHistory.waitForNonExistence(timeout: 3))

    let writingStyle = app.descendants(matching: .any)["quick-check-writing-style"]
    XCTAssertTrue(writingStyle.waitForExistence(timeout: 3))
    XCTAssertTrue(accessibilityText(of: writingStyle).contains("Product Writing"))
    let input = app.textViews["quick-check-input"]
    input.click()
    typeTextReliably("this are a test", into: input)
    app.buttons["quick-check-check"].click()

    let summary = app.descendants(matching: .any)["quick-check-outbound-summary"]
    XCTAssertTrue(summary.waitForExistence(timeout: 3))
    for expectedText in [
      "Check draft",
      "Claude",
      "claude-opus-4-8",
      "Product Writing",
    ] {
      XCTAssertTrue(
        descendant(in: summary, containing: expectedText).waitForExistence(timeout: 3)
      )
    }
    XCTAssertEqual(
      accessibilityText(
        of: summary.descendants(matching: .any)[
          "quick-check-outbound-writing-style-guidance"
        ]
      ),
      "Use concise, direct language for a product team."
    )
    XCTAssertEqual(
      accessibilityText(
        of: summary.descendants(matching: .any)["quick-check-outbound-full-draft"]
      ),
      "this are a test"
    )
    app.buttons["quick-check-outbound-confirm"].click()
    let corrected = app.descendants(matching: .any)["quick-check-corrected"]
    XCTAssertTrue(corrected.waitForExistence(timeout: 5))
    XCTAssertEqual(accessibilityText(of: corrected), "this is a test")
  }

  func testHotKeyConflictFixtureExposesDeterministicFallbackMessage() {
    continueAfterFailure = false
    let app = launchScenario("hotkey-conflict")
    defer { app.terminate() }

    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    let statusItem = app.statusItems["bex-status-item"]
    XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
    statusItem.click()
    let fallback =
      "Keyboard shortcuts could not be registered. "
      + "Quick Check and Fix & Send remain available from the Bex menu."
    let message = app.menuItems[fallback]
    XCTAssertTrue(message.waitForExistence(timeout: 3))
    XCTAssertFalse(message.isEnabled)
  }

  func testQuickCheckAuxiliaryNavigationPreservesInFlightResultErrorDraftAndFocus() {
    continueAfterFailure = false
    let app = launchScenario("quick-check-grammar-in-flight")
    defer { app.terminate() }

    var input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "this are a test")
    app.buttons["quick-check-check"].click()
    XCTAssertTrue(app.descendants(matching: .any)["quick-check-busy-label"].waitForExistence(timeout: 3))

    app.buttons["quick-check-settings"].click()
    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    openMenuCommand("Quick Check", in: app)
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "this are a test")
    XCTAssertTrue(app.descendants(matching: .any)["quick-check-busy-label"].exists)
    XCTAssertTrue(waitForKeyboardFocus(on: input))

    postUITestingCommand("com.bex.desktop.ui-testing.release-grammar")
    let corrected = app.descendants(matching: .any)["quick-check-corrected"]
    XCTAssertTrue(corrected.waitForExistence(timeout: 5))
    XCTAssertEqual(accessibilityText(of: corrected), "this is a test")

    app.buttons["quick-check-history"].click()
    XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 5))
    openMenuCommand("Quick Check", in: app)
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "this are a test")
    XCTAssertEqual(
      accessibilityText(of: app.descendants(matching: .any)["quick-check-corrected"]),
      "this is a test"
    )
    XCTAssertTrue(waitForKeyboardFocus(on: input))

    app.buttons["Recheck"].click()
    let error = app.descendants(matching: .any)["quick-check-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertEqual(accessibilityText(of: error), "Forced UI test grammar failure.")

    app.buttons["quick-check-writing-styles"].click()
    XCTAssertTrue(app.windows["Writing Styles"].waitForExistence(timeout: 5))
    openMenuCommand("Quick Check", in: app)
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "this are a test")
    XCTAssertEqual(
      accessibilityText(of: app.descendants(matching: .any)["quick-check-error"]),
      "Forced UI test grammar failure."
    )
    XCTAssertTrue(waitForKeyboardFocus(on: input))
  }

  func testPromptDeliveryInFlightGateReleasesOneSubmittedEvent() throws {
    continueAfterFailure = false
    let targetSink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestGatedTarget-\(UUID().uuidString).txt")
    let deliveryEventsSink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestGatedEvents-\(UUID().uuidString).json")
    let app = launchScenario(
      "prompt-delivery-in-flight",
      environment: [
        "BEX_UI_TEST_PROMPT_TARGET_PATH": targetSink.path,
        "BEX_UI_TEST_PROMPT_DELIVERY_EVENTS_PATH": deliveryEventsSink.path,
      ]
    )
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    XCTAssertTrue(app.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 5))
    app.buttons["prompt-gate-confirm-outbound"].click()
    let expected = "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    _ = awaitPromptCorrection(in: app, expected: expected)
    app.buttons["prompt-gate-delivery-pasteAndSubmit"].click()
    XCTAssertTrue(app.staticTexts["Delivering…"].waitForExistence(timeout: 3))
    XCTAssertFalse(FileManager.default.fileExists(atPath: deliveryEventsSink.path))

    postUITestingCommand("com.bex.desktop.ui-testing.release-delivery")
    XCTAssertTrue(app.windows["Fix & Send"].waitForNonExistence(timeout: 5))
    XCTAssertEqual(try String(contentsOf: targetSink, encoding: .utf8), expected)
    XCTAssertEqual(
      try readDeliveryEvents(at: deliveryEventsSink),
      [RecordedDeliveryEvent(sequence: 1, effect: "submitted")]
    )
  }


  func testNamedPermissionScenariosExposeDistinctSettingsAndCopyOnlyStates() throws {
    continueAfterFailure = false
    let copySink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestPermissionCopy-\(UUID().uuidString).txt")
    try? FileManager.default.removeItem(at: copySink)

    let denied = launchScenario(
      "permission-denied",
      environment: ["BEX_UI_TEST_PASTEBOARD_PATH": copySink.path]
    )
    XCTAssertTrue(denied.windows["Settings"].waitForExistence(timeout: 5))
    let deniedStatus = denied.descendants(matching: .any)["settings-accessibility-status"]
    XCTAssertTrue(deniedStatus.waitForExistence(timeout: 3))
    XCTAssertEqual(accessibilityText(of: deniedStatus), "Accessibility access is not enabled")

    openMenuCommand("Fix & Send", in: denied)
    let prompt = denied.textViews["prompt-gate-input"]
    XCTAssertTrue(prompt.waitForExistence(timeout: 5))
    prompt.click()
    typeTextReliably("this are a test", into: prompt)
    denied.buttons["prompt-gate-review"].click()
    XCTAssertTrue(denied.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 3))
    denied.buttons["prompt-gate-confirm-outbound"].click()
    XCTAssertEqual(
      awaitPromptCorrection(in: denied, expected: "this is a test").value as? String,
      "this is a test"
    )
    let copy = denied.buttons["prompt-gate-delivery-copyCorrection"]
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    XCTAssertFalse(denied.buttons["prompt-gate-delivery-pasteInDestination"].exists)
    XCTAssertFalse(denied.buttons["prompt-gate-delivery-pasteAndSubmit"].exists)
    copy.click()
    XCTAssertTrue(denied.windows["Fix & Send"].waitForNonExistence(timeout: 3))
    XCTAssertEqual(try String(contentsOf: copySink, encoding: .utf8), "this is a test")
    denied.terminate()
    try? FileManager.default.removeItem(at: copySink)

    let trusted = launchScenario("permission-trusted")
    defer { trusted.terminate() }
    XCTAssertTrue(trusted.windows["Settings"].waitForExistence(timeout: 5))
    let trustedStatus = trusted.descendants(matching: .any)["settings-accessibility-status"]
    XCTAssertTrue(trustedStatus.waitForExistence(timeout: 3))
    XCTAssertEqual(accessibilityText(of: trustedStatus), "Accessibility access is enabled")
  }

  func testHookRequestRequiresConsentLocksClientAndOffersCopyOnlyDelivery() throws {
    continueAfterFailure = false
    let copySink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestHookCopy-\(UUID().uuidString).txt")
    try? FileManager.default.removeItem(at: copySink)
    let hook = launchScenario(
      "hook-provided-client",
      environment: ["BEX_UI_TEST_PASTEBOARD_PATH": copySink.path]
    )
    defer {
      hook.terminate()
      try? FileManager.default.removeItem(at: copySink)
    }

    XCTAssertTrue(hook.windows["Fix & Send"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      hook.descendants(matching: .any)["prompt-gate-disclosure"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      accessibilityText(
        of: hook.descendants(matching: .any)["prompt-gate-outbound-payload"]
      ).contains("Make this UI test prompt concise.")
    )
    hook.buttons["prompt-gate-confirm-outbound"].click()
    _ = awaitPromptCorrection(
      in: hook,
      expected: "Make this UI test prompt concise."
    )

    let client = hook.descendants(matching: .any)["prompt-gate-client"]
    XCTAssertTrue(client.waitForExistence(timeout: 3))
    XCTAssertTrue(accessibilityText(of: client).contains("Codex"))
    XCTAssertFalse(client.isEnabled)
    let copy = hook.buttons["prompt-gate-delivery-copyCorrection"]
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    XCTAssertFalse(hook.buttons["prompt-gate-delivery-pasteInDestination"].exists)
    XCTAssertFalse(hook.buttons["prompt-gate-delivery-pasteAndSubmit"].exists)
    copy.click()
    XCTAssertTrue(hook.windows["Fix & Send"].waitForNonExistence(timeout: 3))
    XCTAssertEqual(
      try String(contentsOf: copySink, encoding: .utf8),
      "Make this UI test prompt concise."
    )
  }

  func testNamedDirtyEditorAndSetupResumeScenariosLaunchExpectedWork() {
    continueAfterFailure = false

    let dirtyEditor = launchScenario("dirty-editor-resume")
    XCTAssertTrue(dirtyEditor.windows["Quick Check"].waitForExistence(timeout: 5))
    let input = dirtyEditor.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 3))
    XCTAssertEqual(input.value as? String, "A saved UI test draft with unsent changes.")
    dirtyEditor.terminate()

    let setupResume = launchScenario("setup-resume")
    defer { setupResume.terminate() }
    XCTAssertTrue(setupResume.windows["Settings"].waitForExistence(timeout: 5))
    let credential = setupResume.secureTextFields["settings-credential-input"]
    XCTAssertTrue(credential.waitForExistence(timeout: 3))
    credential.click()
    credential.typeText("ui-testing-key")
    setupResume.buttons["settings-save-credential"].click()
    let returnToQuickCheck = setupResume.buttons["settings-setup-route"]
    XCTAssertTrue(returnToQuickCheck.waitForExistence(timeout: 3))
    returnToQuickCheck.click()
    XCTAssertTrue(setupResume.windows["Quick Check"].waitForExistence(timeout: 5))
  }

  func testNamedHistoryAndWritingStyleScenariosCoverEmptyAndPopulatedStates() {
    continueAfterFailure = false

    let emptyHistory = launchScenario("history-empty")
    XCTAssertTrue(emptyHistory.windows["History"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      emptyHistory.buttons["history-open-quick-check"].waitForExistence(timeout: 3)
    )
    emptyHistory.terminate()

    let populatedHistory = launchScenario("history-populated")
    XCTAssertTrue(populatedHistory.windows["History"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      populatedHistory.descendants(matching: .any)[
        "history-entry-20000000-0000-0000-0000-000000000001"
      ].waitForExistence(timeout: 3)
    )
    populatedHistory.terminate()

    let emptyStyles = launchScenario("profiles-empty")
    XCTAssertTrue(emptyStyles.windows["Writing Styles"].waitForExistence(timeout: 5))
    XCTAssertTrue(emptyStyles.buttons["writing-styles-empty-new"].waitForExistence(timeout: 3))
    emptyStyles.terminate()

    let populatedStyles = launchScenario("profiles-populated")
    defer { populatedStyles.terminate() }
    XCTAssertTrue(populatedStyles.windows["Writing Styles"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      populatedStyles.descendants(matching: .any)[
        "writing-style-row-10000000-0000-0000-0000-000000000001"
      ].waitForExistence(timeout: 3)
    )
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
    app.buttons["prompt-gate-confirm-outbound"].click()
    XCTAssertEqual(awaitPromptCorrection(in: app).value as? String, expected)
    app.buttons["prompt-gate-delivery-pasteInDestination"].click()

    let replaced = NSPredicate(format: "value == %@", expected)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: replaced, object: editor)],
        timeout: 5
      ),
      .completed
    )
  }

  private func launchScenario(
    _ scenario: String,
    environment: [String: String] = [:]
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launchEnvironment["BEX_UI_TESTING"] = "1"
    app.launchEnvironment["BEX_UI_TEST_SCENARIO"] = scenario
    for (key, value) in environment {
      app.launchEnvironment[key] = value
    }
    app.launch()
    return app
  }

  private func launch(
    openQuickCheck: Bool,
    missingCredential: Bool = false,
    scenario: String? = nil
  ) -> (XCUIApplication, URL) {
    let copySink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestCopy-\(UUID().uuidString).txt")
    try? FileManager.default.removeItem(at: copySink)
    let app = XCUIApplication()
    app.launchEnvironment["BEX_UI_TESTING"] = "1"
    app.launchArguments = ["--ui-testing"]
    if let scenario {
      app.launchEnvironment["BEX_UI_TEST_SCENARIO"] = scenario
    }
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

  private func launchPromptGate(
    deliveryError: Bool = false
  ) -> (XCUIApplication, URL, URL) {
    let targetSink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestPromptTarget-\(UUID().uuidString).txt")
    let copySink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestPromptCopy-\(UUID().uuidString).txt")
    let deliveryEventsSink = FileManager.default.temporaryDirectory
      .appendingPathComponent("BexUITestPromptEvents-\(UUID().uuidString).json")
    try? FileManager.default.removeItem(at: targetSink)
    try? FileManager.default.removeItem(at: copySink)
    try? FileManager.default.removeItem(at: deliveryEventsSink)
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--open-prompt-gate"]
    app.launchEnvironment["BEX_UI_TESTING"] = "1"
    app.launchEnvironment["BEX_UI_TEST_OPEN_PROMPT_GATE"] = "1"
    app.launchEnvironment["BEX_UI_TEST_PROMPT_SOURCE"] =
      "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    app.launchEnvironment["BEX_UI_TEST_PROMPT_TARGET_PATH"] = targetSink.path
    app.launchEnvironment["BEX_UI_TEST_PROMPT_DELIVERY_EVENTS_PATH"] = deliveryEventsSink.path
    app.launchEnvironment["BEX_UI_TEST_PASTEBOARD_PATH"] = copySink.path
    if deliveryError {
      app.launchEnvironment["BEX_UI_TEST_SCENARIO"] = "delivery-failure-effect"
    }
    app.launch()
    return (app, targetSink, deliveryEventsSink)
  }

  private func awaitPromptCorrection(
    in app: XCUIApplication,
    expected: String =
      "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
  ) -> XCUIElement {
    XCTAssertTrue(app.windows["Fix & Send"].waitForExistence(timeout: 5))
    let corrected = app.textViews["prompt-gate-corrected"]
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


  private struct RecordedDeliveryEvent: Codable, Equatable {
    let sequence: Int
    let effect: String
  }

  private func readDeliveryEvents(at url: URL) throws -> [RecordedDeliveryEvent] {
    try JSONDecoder().decode(
      [RecordedDeliveryEvent].self,
      from: Data(contentsOf: url)
    )
  }

  private func accessibilityText(of element: XCUIElement) -> String {
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    return element.label
  }
  private func descendant(
    in root: XCUIElement,
    containing text: String
  ) -> XCUIElement {
    root.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
        text,
        text
      )
    ).firstMatch
  }


  private func waitForKeyboardFocus(on element: XCUIElement) -> Bool {
    let predicate = NSPredicate(format: "hasKeyboardFocus == true")
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
      timeout: 3
    ) == .completed
  }

  private func postUITestingCommand(_ rawName: String) {
    DistributedNotificationCenter.default().postNotificationName(
      Notification.Name(rawName),
      object: nil,
      userInfo: nil,
      deliverImmediately: true
    )
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
