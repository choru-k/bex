import AppKit
import XCTest
import NativeBridgeCore
@testable import Bex

/// Real AppKit sheet tests, not a mocked approval UI. Added as source only: execution
/// requires a separately authorized macOS test session. They have NOT been run.
@MainActor
final class NativeCorrectionConsentPresenterTests: XCTestCase {
  private func request(_ exactText: String? = nil, explanationLanguage: String? = nil) throws -> BridgeRequest {
    var policy: [String: Any] = ["vocabulary": "stretch", "maxNotes": 2, "alternatives": true, "focus": "general"]
    if let explanationLanguage { policy["explanationLanguage"] = explanationLanguage }
    let data = try JSONSerialization.data(withJSONObject: [
      "protocolVersion": 1, "text": exactText ?? ("<b>Exact</b>\nI is ready.\n" + String(repeating: "z", count: 2_000)),
      "policy": policy,
      "source": ["title": "<script>not markup</script>", "section": "1.2", "excerpt": "Reference\nexact excerpt"],
    ])
    return try JSONDecoder().decode(BridgeRequest.self, from: data)
  }

  private func makeWindow() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
  }

  private func presenter(_ window: NSWindow) throws -> NativeCorrectionConsentPresenter {
    try NativeCorrectionConsentPresenter(window: window, providerName: "Provider",
      destinationDescription: "https://native.example/api/account-A", model: "native-model")
  }

  private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<3_000 {
      if predicate() { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("AppKit did not reach the expected state")
    throw BridgeValidation.invalid
  }

  private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
  }

  func testExactPlainTextAndSafeDefaultButtons() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    let input = try request(explanationLanguage: "en")
    let task = Task { try await consent.requestConsent(for: input, providerName: "Provider") }
    try await waitUntil { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet)
    let content = try XCTUnwrap(sheet.contentView)
    let texts = descendants(content, as: NSTextView.self)
    for exact in [input.text, input.source!.title, input.source!.section, input.source!.excerpt,
                  "Provider", "https://native.example/api/account-A", "native-model"] {
      XCTAssertTrue(texts.contains { $0.string == exact })
    }
    XCTAssertTrue(texts.contains { $0.string.contains("Explanation language: en") && $0.string.contains("necessary errors only") && $0.string.contains("separate notes only") })
    XCTAssertTrue(texts.allSatisfy { !$0.isEditable && !$0.isRichText })
    content.layoutSubtreeIfNeeded()
    let outer = try XCTUnwrap(descendants(content, as: NSScrollView.self)
      .first { $0.documentView is NSStackView })
    XCTAssertGreaterThan(outer.frame.height, 0)
    XCTAssertLessThanOrEqual(outer.frame.height, 420)
    XCTAssertGreaterThan(try XCTUnwrap(outer.documentView).frame.height, outer.contentSize.height)
    let fullText = try XCTUnwrap(texts.first { $0.string == input.text })
    let scroll = try XCTUnwrap(fullText.enclosingScrollView)
    XCTAssertGreaterThan(scroll.contentSize.width, 0)
    XCTAssertGreaterThan(scroll.contentSize.height, 0)
    scroll.scrollToVisible(scroll.bounds)
    let container = try XCTUnwrap(fullText.textContainer)
    let layout = try XCTUnwrap(fullText.layoutManager)
    layout.ensureLayout(for: container)
    let lastCharacter = NSRange(location: input.text.utf16.count - 1, length: 1)
    fullText.scrollRangeToVisible(lastCharacter)
    let glyphs = layout.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
    var lastRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    lastRect.origin.x += fullText.textContainerOrigin.x
    lastRect.origin.y += fullText.textContainerOrigin.y
    XCTAssertTrue(fullText.visibleRect.intersects(lastRect), "The full text's end must be reachable")
    let buttons = descendants(content, as: NSButton.self)
    let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
    let send = try XCTUnwrap(buttons.first { $0.title == "Send this request" })
    XCTAssertTrue(sheet.defaultButtonCell === cancel.cell)
    XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
    XCTAssertEqual(send.keyEquivalent, "")
    cancel.performClick(nil)
    let granted = try await task.value
    XCTAssertFalse(granted)
    XCTAssertNil(window.attachedSheet)
    XCTAssertFalse(sheet.isVisible)
    XCTAssertEqual(consent.outstandingRequestCount, 0)
  }

  func testExplicitSendReturnsOnlyAfterDismissal() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    let input = try request()
    let task = Task { try await consent.requestConsent(for: input, providerName: "Provider") }
    try await waitUntil { window.attachedSheet != nil }
    let sheet = try XCTUnwrap(window.attachedSheet)
    let send = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView), as: NSButton.self)
      .first { $0.title == "Send this request" })
    send.performClick(nil)
    let granted = try await task.value
    XCTAssertTrue(granted)
    XCTAssertFalse(sheet.isVisible)
    XCTAssertNil(window.attachedSheet)
  }

  func testBoundedQueueCancellationAndClose() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    let input = try request()
    var tasks: [Task<Bool, Error>] = []
    for count in 1...4 {
      tasks.append(Task { try await consent.requestConsent(for: input, providerName: "Provider") })
      try await waitUntil { consent.outstandingRequestCount == count }
    }
    let overflow = try await consent.requestConsent(for: input, providerName: "Provider")
    XCTAssertFalse(overflow)
    XCTAssertEqual(consent.outstandingRequestCount, 4)
    let sheet = try XCTUnwrap(window.attachedSheet)
    tasks[2].cancel() // A queued cancellation must not dismiss the active request.
    try await waitUntil { consent.outstandingRequestCount == 3 }
    XCTAssertTrue(window.attachedSheet === sheet)
    tasks[0].cancel()
    do { _ = try await tasks[0].value; XCTFail("Expected cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    XCTAssertFalse(sheet.isVisible)
    consent.close()
    for task in tasks {
      do { let granted = try await task.value; XCTAssertFalse(granted) }
      catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    XCTAssertEqual(consent.outstandingRequestCount, 0)
    XCTAssertNil(window.attachedSheet)
    let closedResult = try await consent.requestConsent(for: input, providerName: "Provider")
    XCTAssertFalse(closedResult)
  }

  func testFIFOShowsEachExactRequestInOrder() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    var tasks: [Task<Bool, Error>] = []
    for (index, text) in ["First exact request", "Second exact request", "Third exact request"].enumerated() {
      let input = try request(text)
      tasks.append(Task { try await consent.requestConsent(for: input, providerName: "Provider") })
      try await waitUntil { consent.outstandingRequestCount == index + 1 }
    }
    for (index, text) in ["First exact request", "Second exact request", "Third exact request"].enumerated() {
      try await waitUntil {
        guard let content = window.attachedSheet?.contentView else { return false }
        return self.descendants(content, as: NSTextView.self).contains { $0.string == text }
      }
      let sheet = try XCTUnwrap(window.attachedSheet)
      let cancel = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView), as: NSButton.self)
        .first { $0.title == "Cancel" })
      cancel.performClick(nil)
      let result = try await tasks[index].value
      XCTAssertFalse(result)
      XCTAssertFalse(sheet.isVisible)
    }
    XCTAssertEqual(consent.outstandingRequestCount, 0)
  }

  func testWindowCloseDeniesActiveAndQueuedRequests() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    let input = try request()
    let first = Task { try await consent.requestConsent(for: input, providerName: "Provider") }
    try await waitUntil { consent.outstandingRequestCount == 1 }
    let second = Task { try await consent.requestConsent(for: input, providerName: "Provider") }
    try await waitUntil { consent.outstandingRequestCount == 2 }
    window.close()
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertFalse(firstResult)
    XCTAssertFalse(secondResult)
    XCTAssertEqual(consent.outstandingRequestCount, 0)
  }

  func testAlreadyCancelledTaskNeverPresentsSheet() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    let input = try request()
    let task = Task { try await consent.requestConsent(for: input, providerName: "Provider") }
    // This main-actor method has not yielded, so the task has not entered enqueue.
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(consent.outstandingRequestCount, 0)
  }

  func testUnrelatedSheetIsNotQueuedBehind() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    let unrelated = NSAlert()
    unrelated.messageText = "Unrelated native sheet"
    unrelated.addButton(withTitle: "Cancel")
    unrelated.beginSheetModal(for: window)
    defer {
      consent.close()
      window.endSheet(unrelated.window)
      unrelated.window.orderOut(nil)
      window.close()
    }
    let denied = try await consent.requestConsent(for: request(), providerName: "Provider")
    XCTAssertFalse(denied)
    XCTAssertTrue(window.attachedSheet === unrelated.window)
    XCTAssertEqual(consent.outstandingRequestCount, 0)
  }

  func testProviderMismatchNeverPresentsSheet() async throws {
    let window = makeWindow()
    let consent = try presenter(window)
    defer { consent.close(); window.close() }
    let denied = try await consent.requestConsent(for: request(), providerName: "Renderer provider")
    XCTAssertFalse(denied)
    XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(consent.outstandingRequestCount, 0)
  }
}
