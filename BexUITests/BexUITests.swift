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

  func testCheckShowsReviewCardCopiesCorrectionAndSavesHistory() throws {
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
    XCTAssertTrue(titledSurface(app, "Quick Check").waitForNonExistence(timeout: 3))

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

    // The result is the shared review card (design 4a): an editable final message with
    // the redline under it, grammar notes behind one Details disclosure, and the footer
    // as the only surface difference from Fix & Send.
    let corrected = app.textViews["quick-check-corrected"]
    XCTAssertTrue(corrected.waitForExistence(timeout: 5))
    XCTAssertEqual(corrected.value as? String, "this is a test")
    let diffElement = app.descendants(matching: .any)["quick-check-diff-summary"]
    let diffSummary = accessibilityText(of: diffElement)
    XCTAssertTrue(diffSummary.contains("Removed “are” between"))
    XCTAssertTrue(diffSummary.contains("Inserted “is” between"))

    // The Details disclosure exposes as a disclosure triangle, not a button.
    app.descendants(matching: .any)["quick-check-details-disclosure"].firstMatch.click()
    let grammarNotes = app.descendants(matching: .any)["quick-check-explanation"]
    XCTAssertTrue(grammarNotes.waitForExistence(timeout: 3))
    XCTAssertEqual(accessibilityText(of: grammarNotes), "Changed subject-verb agreement.")

    app.buttons["quick-check-copy-correction"].click()
    XCTAssertTrue(titledSurface(app, "Quick Check").waitForNonExistence(timeout: 3))
    XCTAssertEqual(
      try String(contentsOf: copySink, encoding: .utf8),
      "this is a test"
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
    // The row stamps its history-entry id over every child, so the detail is found by
    // label + value; the section heading shares the label but carries no value.
    let historyCorrected = historyWindow.staticTexts.matching(
      NSPredicate(format: "label == 'Corrected' AND value == 'this is a test'")
    ).firstMatch
    XCTAssertTrue(historyCorrected.waitForExistence(timeout: 3))
  }

  func testMissingCredentialShowsSetupAndNavigatesToSettings() {
    continueAfterFailure = false
    let (app, copySink) = launch(openQuickCheck: true, missingCredential: true)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: copySink)
    }

    let quickCheck = titledSurface(app, "Quick Check")
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
    XCTAssertEqual(
      accessibilityText(of: app.descendants(matching: .any)["prompt-gate-review-title"]),
      "Review Message for UI Test Target"
    )
    XCTAssertTrue(
      accessibilityText(of: app.descendants(matching: .any)["prompt-gate-review-context"])
        .contains("Captured from UI Test Target · Checked by OpenAI")
    )
    XCTAssertEqual(
      accessibilityText(
        of: app.descendants(matching: .any)["prompt-gate-review-pending-status"]
      ),
      "Nothing has been sent."
    )
    // Re-baselined to the current card: one collapsed Details disclosure carries the
    // original message and the grammar notes (the separate original/AI-note disclosures
    // left with the v1 redesign).
    let finalHeading = app.descendants(matching: .any)["prompt-gate-final-message-heading"]
    let detailsDisclosure =
      app.descendants(matching: .any)["prompt-gate-details-disclosure"].firstMatch
    XCTAssertTrue(finalHeading.exists)
    XCTAssertTrue(detailsDisclosure.exists)
    XCTAssertLessThan(finalHeading.frame.minY, detailsDisclosure.frame.minY)
    XCTAssertFalse(app.descendants(matching: .any)["prompt-gate-original"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["prompt-gate-explanation"].exists)
    let initialDiff = app.descendants(matching: .any)["prompt-gate-diff-summary"]
    XCTAssertTrue(initialDiff.waitForExistence(timeout: 3))
    XCTAssertTrue(initialDiff.label.contains("3 changes"))
    let initialDiffSummary = accessibilityText(of: initialDiff)
    XCTAssertTrue(initialDiffSummary.contains("Removed"))
    XCTAssertTrue(initialDiffSummary.contains("Inserted"))
    XCTAssertLessThan(corrected.frame.minY, initialDiff.frame.minY)

    detailsDisclosure.click()
    let originalContent = app.descendants(matching: .any)["prompt-gate-original"]
    XCTAssertTrue(originalContent.waitForExistence(timeout: 3))
    XCTAssertEqual(
      accessibilityText(of: originalContent),
      "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    )
    let explanation = app.descendants(matching: .any)["prompt-gate-explanation"]
    XCTAssertTrue(explanation.waitForExistence(timeout: 3))
    XCTAssertEqual(
      accessibilityText(of: explanation),
      "Corrected capitalization, agreement, and spelling."
    )

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
    XCTAssertTrue(
      app.descendants(matching: .any)["prompt-gate-ai-note-stale"]
        .waitForExistence(timeout: 3)
    )

    app.buttons["prompt-gate-cancel"].click()
    // Scoped to the sheet: an unscoped label query can land on the Touch Bar copy of the
    // same button, which XCUITest cannot click.
    let discardEdits = app.sheets.buttons["Discard Edits"].firstMatch
    XCTAssertTrue(discardEdits.waitForExistence(timeout: 3))
    discardEdits.click()
    XCTAssertTrue(corrected.waitForNonExistence(timeout: 3))
    XCTAssertTrue(titledSurface(app, "Fix & Send").waitForNonExistence(timeout: 3))
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetSink.path))

    app.terminate()
    app.launch()
    XCTAssertTrue(app.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 3))
    app.buttons["prompt-gate-confirm-outbound"].click()
    let reopened = awaitPromptCorrection(in: app)
    XCTAssertEqual(reopened.value as? String, expected)
    XCTAssertFalse(app.descendants(matching: .any)["prompt-gate-original"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["prompt-gate-explanation"].exists)
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
    XCTAssertTrue(corrected.waitForNonExistence(timeout: 3))
    XCTAssertEqual(try String(contentsOf: targetSink, encoding: .utf8), expected)
    XCTAssertFalse(app.buttons["prompt-gate-delivery-pasteAndSubmit"].exists)
    XCTAssertEqual(
      try readDeliveryEvents(at: deliveryEventsSink),
      [RecordedDeliveryEvent(sequence: 1, effect: "submitted")]
    )
  }

  func testPromptGateCommandReturnReplacesWithoutSending() throws {
    continueAfterFailure = false
    let (app, targetSink, deliveryEventsSink) = launchPromptGate()
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    XCTAssertTrue(app.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 5))
    app.buttons["prompt-gate-confirm-outbound"].click()
    let corrected = awaitPromptCorrection(in: app)
    corrected.typeKey(.return, modifierFlags: .command)

    XCTAssertTrue(corrected.waitForNonExistence(timeout: 3))
    XCTAssertEqual(
      try String(contentsOf: targetSink, encoding: .utf8),
      "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
    )
    XCTAssertEqual(
      try readDeliveryEvents(at: deliveryEventsSink),
      [RecordedDeliveryEvent(sequence: 1, effect: "pastedNotSubmitted")]
    )
  }

  func testPromptGateNoChangeKeepsFinalMessagePrimary() throws {
    continueAfterFailure = false
    let source = "Already correct."
    let (app, targetSink, deliveryEventsSink) = launchPromptGate(source: source)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    XCTAssertTrue(app.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 5))
    app.buttons["prompt-gate-confirm-outbound"].click()
    let corrected = awaitPromptCorrection(in: app, expected: source)
    let noChanges = app.descendants(matching: .any)["prompt-gate-no-changes"]
    let disclosure =
      app.descendants(matching: .any)["prompt-gate-details-disclosure"].firstMatch
    XCTAssertTrue(noChanges.waitForExistence(timeout: 3))
    XCTAssertLessThan(corrected.frame.minY, noChanges.frame.minY)
    XCTAssertLessThan(corrected.frame.minY, disclosure.frame.minY)
    corrected.click()
    corrected.typeText(" Edited")
    XCTAssertEqual(corrected.value as? String, "Already correct. Edited")
  }

  func testPromptGateLongMessageRemainsEditableAndDeliverable() throws {
    continueAfterFailure = false
    let source =
      "i has teh file "
      + (1...30).map { "line \($0): detail with wrapping text" }.joined(separator: "\n")
    let expected =
      "I have the file "
      + (1...30).map { "line \($0): detail with wrapping text" }.joined(separator: "\n")
    let (app, targetSink, deliveryEventsSink) = launchPromptGate(source: source)
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }

    XCTAssertTrue(app.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 5))
    app.buttons["prompt-gate-confirm-outbound"].click()
    let corrected = awaitPromptCorrection(in: app, expected: expected)
    corrected.click()
    corrected.typeKey(.downArrow, modifierFlags: .command)
    corrected.typeText(" Final edit.")
    XCTAssertEqual(corrected.value as? String, expected + " Final edit.")

    // Scroll until the disclosure row sits inside the scroll view's visible bounds.
    // Two traps here: `isHittable` reports true even when the row is clipped under the
    // footer bar (the click then lands on the footer), and with the auto-sizing editor
    // a long message fills 60% of the panel, so a scroll at the scroll view's centre
    // would be swallowed by the editor's own scroll view — hence the coordinate below
    // the editor.
    let detailsDisclosure =
      app.descendants(matching: .any)["prompt-gate-details-disclosure"].firstMatch
    let outerScroll = app.scrollViews.firstMatch
    let belowEditor = outerScroll.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
    )
    var scrollAttempts = 0
    while detailsDisclosure.frame.maxY > outerScroll.frame.maxY - 10, scrollAttempts < 8 {
      belowEditor.scroll(byDeltaX: 0, deltaY: -300)
      scrollAttempts += 1
    }
    XCTAssertLessThanOrEqual(detailsDisclosure.frame.maxY, outerScroll.frame.maxY)
    detailsDisclosure.click()
    XCTAssertTrue(
      app.descendants(matching: .any)["prompt-gate-original"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(app.buttons["prompt-gate-back"].isHittable)
    XCTAssertTrue(app.buttons["prompt-gate-delivery-pasteInDestination"].isHittable)
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
    XCTAssertTrue(corrected.exists)
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
    XCTAssertTrue(
      freshConsent.descendants(matching: .any)["prompt-gate-disclosure"]
        .waitForExistence(timeout: 3)
    )
    freshConsent.terminate()

    let configuredProvider = launchScenario("configured-provider")
    defer { configuredProvider.terminate() }
    XCTAssertTrue(configuredProvider.windows["Settings"].waitForExistence(timeout: 5))
    // Settings is categorized; the provider picker lives behind its tab.
    configuredProvider.descendants(matching: .any)["settings-category-provider"]
      .firstMatch.click()
    XCTAssertTrue(
      configuredProvider.descendants(matching: .any)["settings-provider"]
        .waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      configuredProvider.descendants(matching: .any)["settings-provider-connection"].exists
    )
  }
  func testIntegrationReviewAppliesOnlyAfterExplicitConfirmation() throws {
    continueAfterFailure = false
    let transcript = temporarySink("BexUIIntegrationSuccess", extension: "json")
    let app = launchScenario(
      "integrations",
      environment: ["BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH": transcript.path]
    )
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: transcript)
    }

    setOMPProfile("ui-test", in: app)
    let review = app.buttons["settings-omp-review-install"]
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    review.click()
    let apply = app.buttons["settings-integration-review-apply"]
    XCTAssertTrue(apply.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Install Oh My Pi"].exists)
    apply.click()
    XCTAssertTrue(apply.waitForNonExistence(timeout: 3))

    let events = try readStringEvents(at: transcript)
    XCTAssertTrue(events.contains { $0.hasPrefix("prepare:install:omp-ui-test:") })
    XCTAssertTrue(events.contains { $0.hasPrefix("apply:install:omp-ui-test:") })
  }

  func testIntegrationReviewStaleBaselineRequiresFreshReview() throws {
    continueAfterFailure = false
    let transcript = temporarySink("BexUIIntegrationStale", extension: "json")
    let app = launchScenario(
      "integrations",
      environment: [
        "BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH": transcript.path,
        "BEX_UI_TEST_INJECT_DRIFT_ID": "omp-ui-test",
      ]
    )
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: transcript)
    }

    setOMPProfile("ui-test", in: app)
    XCTAssertTrue(app.buttons["settings-omp-review-install"].waitForExistence(timeout: 5))
    app.buttons["settings-omp-review-install"].click()
    let apply = app.buttons["settings-integration-review-apply"]
    XCTAssertTrue(apply.waitForExistence(timeout: 3))
    apply.click()
    let latest = app.buttons["settings-integration-review-latest"]
    XCTAssertTrue(latest.waitForExistence(timeout: 3))
    let error = app.descendants(matching: .any)["settings-integration-review-error"]
    XCTAssertTrue(error.exists)
    XCTAssertTrue(accessibilityText(of: error).contains("Nothing changed"))
    XCTAssertFalse(apply.isEnabled)

    latest.click()
    XCTAssertTrue(apply.waitForExistence(timeout: 3))
    XCTAssertTrue(apply.isEnabled)
    apply.click()
    XCTAssertTrue(apply.waitForNonExistence(timeout: 3))

    let events = try readStringEvents(at: transcript)
    XCTAssertTrue(events.contains("drift:omp-ui-test"))
    XCTAssertEqual(events.filter { $0.hasPrefix("prepare:install:omp-ui-test:") }.count, 2)
    XCTAssertEqual(events.filter { $0.hasPrefix("apply:install:omp-ui-test:") }.count, 1)
  }

  func testIntegrationReviewReportsPartialRollbackPaths() throws {
    continueAfterFailure = false
    let transcript = temporarySink("BexUIIntegrationPartial", extension: "json")
    let app = launchScenario(
      "integrations",
      environment: [
        "BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH": transcript.path,
        "BEX_UI_TEST_PARTIAL_FAILURE_ID": "omp-ui-test",
      ]
    )
    defer {
      app.terminate()
      try? FileManager.default.removeItem(at: transcript)
    }

    setOMPProfile("ui-test", in: app)
    XCTAssertTrue(app.buttons["settings-omp-review-install"].waitForExistence(timeout: 5))
    app.buttons["settings-omp-review-install"].click()
    let apply = app.buttons["settings-integration-review-apply"]
    XCTAssertTrue(apply.waitForExistence(timeout: 3))
    apply.click()

    let error = app.descendants(matching: .any)["settings-integration-review-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 3))
    XCTAssertTrue(accessibilityText(of: error).contains("partially failed"))
    // SwiftUI Text exposes its string as value on current macOS; match either slot.
    for prefix in ["Completed:", "Restored:", "Retained or failed:"] {
      XCTAssertTrue(
        app.staticTexts.matching(
          NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)
        ).firstMatch.exists,
        "missing rollback line starting with \(prefix)"
      )
    }
    XCTAssertTrue(app.buttons["settings-integration-review-latest"].exists)
    XCTAssertFalse(apply.isEnabled)

    let events = try readStringEvents(at: transcript)
    XCTAssertTrue(events.contains("partial-failure:omp-ui-test"))
  }

  func testFreshQuickCheckMakesRetentionChoicesAndConfirmsFullCustomPayload() {
    continueAfterFailure = false
    let app = launchScenario("fresh-quick-check")
    defer { app.terminate() }

    XCTAssertTrue(titledSurface(app, "Quick Check").waitForExistence(timeout: 5))
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

  func testHotKeyConflictFixtureExposesDeterministicFallbackMessage() throws {
    continueAfterFailure = false
    let app = launchScenario("hotkey-conflict")
    defer { app.terminate() }

    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    // The status item exposes its label ("Bex") but not the identifier set on its button;
    // the app owns exactly one status item, so firstMatch is unambiguous.
    let statusItem = app.statusItems.firstMatch
    XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
    guard statusItem.isHittable else {
      throw XCTSkip("The menu bar is auto-hidden on this display; the status item cannot be clicked.")
    }
    statusItem.click()
    // The status item opens the hub popover now, not an `NSMenu`, so the fallback notice
    // is a line in the popover rather than a disabled menu item.
    let message = app.descendants(matching: .any)["hub-shortcut-conflict"]
    XCTAssertTrue(message.waitForExistence(timeout: 3))
    XCTAssertEqual(
      accessibilityText(of: message),
      "Quick Check and Fix & Send shortcuts could not be registered. The commands remain "
        + "available here and in the Bex menu."
    )
    // The commands it points at have to actually be there.
    XCTAssertTrue(app.descendants(matching: .any)["hub-quick-check"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["hub-fix-and-send"].exists)
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

    // The management row and context row are link-style buttons, which expose as links.
    app.links["quick-check-settings"].click()
    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    openMenuCommand("Quick Check", in: app)
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "this are a test")
    XCTAssertTrue(app.descendants(matching: .any)["quick-check-busy-label"].exists)
    XCTAssertTrue(waitForKeyboardFocus(on: input))

    postUITestingCommand("com.bex.desktop.ui-testing.release-grammar")
    let corrected = app.textViews["quick-check-corrected"]
    XCTAssertTrue(corrected.waitForExistence(timeout: 5))
    XCTAssertEqual(accessibilityText(of: corrected), "this is a test")

    // The post-check state is the shared review card, so auxiliary navigation now goes
    // through the context row (provider/model route to Settings). The card must survive
    // the round trip.
    app.links["quick-check-provider"].click()
    XCTAssertTrue(app.windows["Settings"].waitForExistence(timeout: 5))
    openMenuCommand("Quick Check", in: app)
    XCTAssertTrue(app.textViews["quick-check-corrected"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      accessibilityText(of: app.textViews["quick-check-corrected"]),
      "this is a test"
    )

    // ⌘[ returns to the draft, which still holds the original text; the scenario fails
    // the second check deterministically, and the error must survive navigation too.
    app.typeKey("[", modifierFlags: .command)
    input = app.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "this are a test")
    XCTAssertTrue(waitForKeyboardFocus(on: input))
    app.buttons["quick-check-check"].click()
    let error = app.descendants(matching: .any)["quick-check-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertEqual(accessibilityText(of: error), "Forced UI test grammar failure.")

    app.links["quick-check-writing-styles"].click()
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
    XCTAssertTrue(app.staticTexts["Delivering…"].waitForNonExistence(timeout: 5))
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
    // The accessibility status lives behind the Fix & Send category tab.
    denied.descendants(matching: .any)["settings-category-fix-and-send"].firstMatch.click()
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
    XCTAssertTrue(denied.textViews["prompt-gate-corrected"].waitForNonExistence(timeout: 3))
    XCTAssertEqual(try String(contentsOf: copySink, encoding: .utf8), "this is a test")
    denied.terminate()
    try? FileManager.default.removeItem(at: copySink)

    let trusted = launchScenario("permission-trusted")
    defer { trusted.terminate() }
    XCTAssertTrue(trusted.windows["Settings"].waitForExistence(timeout: 5))
    trusted.descendants(matching: .any)["settings-category-fix-and-send"].firstMatch.click()
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

    XCTAssertTrue(
      hook.descendants(matching: .any)["prompt-gate-disclosure"].waitForExistence(timeout: 3)
    )
    XCTAssertTrue(
      accessibilityText(
        of: hook.descendants(matching: .any)["prompt-gate-outbound-payload"]
      ).contains("Make this UI test prompt concise.")
    )
    hook.buttons["prompt-gate-confirm-outbound"].click()
    let corrected = awaitPromptCorrection(
      in: hook,
      expected: "Make this UI test prompt concise."
    )

    let context = hook.descendants(matching: .any)["prompt-gate-review-context"]
    XCTAssertTrue(context.waitForExistence(timeout: 3))
    XCTAssertTrue(accessibilityText(of: context).contains("Requested by Codex"))
    XCTAssertFalse(hook.descendants(matching: .any)["prompt-gate-client"].exists)
    let copy = hook.buttons["prompt-gate-delivery-copyCorrection"]
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    XCTAssertFalse(hook.buttons["prompt-gate-delivery-pasteInDestination"].exists)
    XCTAssertFalse(hook.buttons["prompt-gate-delivery-pasteAndSubmit"].exists)
    copy.click()
    XCTAssertTrue(corrected.waitForNonExistence(timeout: 3))
    XCTAssertEqual(
      try String(contentsOf: copySink, encoding: .utf8),
      "Make this UI test prompt concise."
    )
  }

  func testHookRequestCanSkipPerPromptOutboundConfirmation() throws {
    continueAfterFailure = false
    let hook = launchScenario("hook-skips-outbound-confirmation")
    defer { hook.terminate() }

    let corrected = awaitPromptCorrection(
      in: hook,
      expected: "Make this UI test prompt concise."
    )

    XCTAssertEqual(corrected.value as? String, "Make this UI test prompt concise.")
    XCTAssertFalse(hook.buttons["prompt-gate-confirm-outbound"].exists)
  }

  func testNamedDirtyEditorAndSetupResumeScenariosLaunchExpectedWork() {
    continueAfterFailure = false

    let dirtyEditor = launchScenario("dirty-editor-resume")
    XCTAssertTrue(titledSurface(dirtyEditor, "Quick Check").waitForExistence(timeout: 5))
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
    XCTAssertTrue(titledSurface(setupResume, "Quick Check").waitForExistence(timeout: 5))
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
    // Without Accessibility access the capture itself fails (an alert, no gate), so the
    // skip has to happen here — waiting for the disclosure first would fail before the
    // existing status-based skip below ever ran.
    let disclosure = app.descendants(matching: .any)["prompt-gate-disclosure"]
    guard disclosure.waitForExistence(timeout: 5) else {
      throw XCTSkip("Bex does not have Accessibility access on this runner (capture failed).")
    }
    let accessibilityStatus = app.staticTexts["prompt-gate-accessibility-status"]
    XCTAssertTrue(accessibilityStatus.waitForExistence(timeout: 2))
    guard accessibilityText(of: accessibilityStatus).contains("enabled") else {
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

  private func setOMPProfile(_ profile: String, in app: XCUIApplication) {
    let field = app.textFields["settings-omp-profile"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.click()
    field.typeKey("a", modifierFlags: .command)
    field.typeKey(.delete, modifierFlags: [])
    field.typeText(profile)
    XCTAssertEqual(field.value as? String, profile)
  }

  private func temporarySink(_ prefix: String, extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)
  }

  private func readStringEvents(at url: URL) throws -> [String] {
    try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
  }

  /// Captures the redesign's documentation screenshots from the seeded fixtures, into
  /// the directory named by `BEX_SCREENSHOT_DIR` (pass it as
  /// `TEST_RUNNER_BEX_SCREENSHOT_DIR=… xcodebuild … test`). Skipped in normal runs so
  /// the suite stays deterministic; run it deliberately when a design pass needs fresh
  /// baselines. Never real data — every state below is a fixture.
  func testCaptureRedesignScreenshots() throws {
    guard let dir = ProcessInfo.processInfo.environment["BEX_SCREENSHOT_DIR"] else {
      throw XCTSkip("Set TEST_RUNNER_BEX_SCREENSHOT_DIR to capture redesign screenshots.")
    }
    continueAfterFailure = false
    let directory = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func save(_ element: XCUIElement, as name: String) throws {
      try element.screenshot().pngRepresentation
        .write(to: directory.appendingPathComponent(name))
    }

    // Quick Check after a check: the shared review card, Copy Correction footer (4a),
    // with the alternatives panel present — the fixture sentence carries a Consider
    // section precisely so the baseline proves the panel renders here (v3 decision 5).
    let (quickCheckApp, copySink) = launch(openQuickCheck: true, scenario: "configured-provider")
    defer { try? FileManager.default.removeItem(at: copySink) }
    let input = quickCheckApp.textViews["quick-check-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.click()
    typeTextReliably("can you check this are a test", into: input)
    quickCheckApp.buttons["quick-check-check"].click()
    XCTAssertTrue(quickCheckApp.textViews["quick-check-corrected"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      quickCheckApp.descendants(matching: .any)["quick-check-better-expression"]
        .waitForExistence(timeout: 3),
      "the alternatives panel must render on the Quick Check card"
    )
    try save(titledSurface(quickCheckApp, "Quick Check"), as: "01-quickcheck-review-card.png")
    quickCheckApp.terminate()

    // Fix & Send on the same correction: the same card, delivery footer.
    let (promptGateApp, targetSink, deliveryEventsSink) = launchPromptGate()
    defer {
      try? FileManager.default.removeItem(at: targetSink)
      try? FileManager.default.removeItem(at: deliveryEventsSink)
    }
    XCTAssertTrue(
      promptGateApp.buttons["prompt-gate-confirm-outbound"].waitForExistence(timeout: 5)
    )
    promptGateApp.buttons["prompt-gate-confirm-outbound"].click()
    _ = awaitPromptCorrection(in: promptGateApp)
    try save(titledSurface(promptGateApp, "Fix & Send"), as: "02-fixsend-review-card.png")
    promptGateApp.terminate()

    // Learn on a fresh install: the first-run empty deck (4e).
    let learnApp = launchScenario("configured-provider")
    defer { learnApp.terminate() }
    XCTAssertTrue(learnApp.windows["Settings"].waitForExistence(timeout: 5))
    learnApp.descendants(matching: .any)["main-sidebar-learn"].firstMatch.click()
    XCTAssertTrue(
      learnApp.descendants(matching: .any)["study-first-run"].waitForExistence(timeout: 5)
    )
    try save(titledSurface(learnApp, "Learn"), as: "03-learn-first-run.png")
  }

  /// A titled top-level surface, whatever it exposes as. On current macOS an `NSPanel`
  /// (Quick Check, Fix & Send) is a Dialog in the accessibility tree while plain windows
  /// stay Windows — `app.windows[title]` silently never matches a panel, which also makes
  /// `waitForNonExistence` on it pass vacuously.
  private func titledSurface(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "(elementType == %d OR elementType == %d) AND title == %@",
        XCUIElement.ElementType.window.rawValue,
        XCUIElement.ElementType.dialog.rawValue,
        title
      )
    ).firstMatch
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
    deliveryError: Bool = false,
    source: String =
      "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
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
    app.launchEnvironment["BEX_UI_TEST_PROMPT_SOURCE"] = source
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
    let corrected = app.textViews["prompt-gate-corrected"]
    XCTAssertTrue(corrected.waitForExistence(timeout: 5))
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
    // Focus can settle mid-typing and swallow or duplicate a keystroke; clear and retry
    // rather than failing on the first garbled attempt.
    for _ in 0..<3 {
      element.typeText(text + "00")
      if let entered = element.value as? String, entered.hasPrefix(text) {
        for _ in 0..<(entered.count - text.count) {
          element.typeKey(.delete, modifierFlags: [])
        }
        verifyTypedText(text, in: element)
        return
      }
      element.typeKey("a", modifierFlags: .command)
      element.typeKey(.delete, modifierFlags: [])
    }
    XCTFail(
      "Could not enter UI test text. Expected prefix \(text), got \(String(describing: element.value))."
    )
  }

  private func verifyTypedText(_ text: String, in element: XCUIElement) {
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
