import AppKit
import NativeBridgeCore

/// Unactivated native UI candidate. Construct only from a captured native provider
/// binding, never a renderer message. The host must call close() on document/account
/// replacement, then await the coordinator's closeAndWait() before replacing services.
@MainActor
final class NativeCorrectionConsentPresenter: NativeCorrectionConsentService {
  private let state: PresentationState

  init(window: NSWindow, providerName: String, destinationDescription: String,
       model: String) throws {
    // Keep the complete destination/model disclosure, not a shortened capability label.
    guard [providerName, destinationDescription, model].allSatisfy({
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }), providerName.utf16.count <= 80,
      destinationDescription.utf8.count <= 16_384, model.utf8.count <= 4_096 else {
      throw BridgeValidation.invalid
    }
    state = PresentationState(window: window, providerName: providerName,
                              destination: destinationDescription, model: model)
  }

  func requestConsent(for request: BridgeRequest, providerName: String) async throws -> Bool {
    let state = state
    let id = UUID()
    try Task.checkCancellation()
    let granted = await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        // Covers cancellation before the cancellation handler's main-actor hop.
        guard !Task.isCancelled else { continuation.resume(returning: false); return }
        state.enqueue(id: id, request: request, providerName: providerName,
                      continuation: continuation)
      }
    }, onCancel: {
      Task { @MainActor in state.cancel(id: id) }
    })
    try Task.checkCancellation()
    return granted
  }

  var outstandingRequestCount: Int { state.outstandingRequestCount }

  func close() { state.close() }

  deinit {
    // State outlives this wrapper until AppKit's dismissal callback has run. Never
    // resume an active sheet's continuation from deinit or a cancellation request.
    let state = state
    Task { @MainActor in state.close() }
  }
}

@MainActor
private final class PresentationState {
  private struct Pending {
    let id: UUID
    let request: BridgeRequest
    let continuation: CheckedContinuation<Bool, Never>
  }
  private struct Active {
    let pending: Pending
    let alert: NSAlert
    var cancelled = false
  }
  private weak var window: NSWindow?
  private let providerName: String
  private let destination: String
  private let model: String
  private var queue: [Pending] = []
  private var active: Active?
  private var closed = false
  private var closeObserver: CloseObservation?

  init(window: NSWindow, providerName: String, destination: String, model: String) {
    self.window = window
    self.providerName = providerName
    self.destination = destination
    self.model = model
    closeObserver = CloseObservation(NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      // NSWindow lifecycle notifications run synchronously on the main thread.
      MainActor.assumeIsolated { self?.close() }
    })
  }

  deinit {
    closeObserver?.invalidate()
  }

  var outstandingRequestCount: Int { queue.count + (active == nil ? 0 : 1) }

  func enqueue(id: UUID, request: BridgeRequest, providerName: String,
               continuation: CheckedContinuation<Bool, Never>) {
    guard !closed, providerName == self.providerName,
          window?.isVisible == true, outstandingRequestCount < 4 else {
      continuation.resume(returning: false)
      return
    }
    queue.append(Pending(id: id, request: request, continuation: continuation))
    presentNext()
  }

  func cancel(id: UUID) {
    if let index = queue.firstIndex(where: { $0.id == id }) {
      queue.remove(at: index).continuation.resume(returning: false)
      return
    }
    guard var current = active, current.pending.id == id, !current.cancelled else { return }
    current.cancelled = true
    active = current
    // Keep this slot occupied until beginSheetModal's completion handler runs.
    // The parent can already be closing; endSheet still owns dismissal completion.
    if let parent = current.alert.window.sheetParent {
      parent.endSheet(current.alert.window, returnCode: .cancel)
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    if let closeObserver {
      closeObserver.invalidate()
      self.closeObserver = nil
    }
    let waiting = queue
    queue.removeAll()
    for pending in waiting { pending.continuation.resume(returning: false) }
    if let active { cancel(id: active.pending.id) }
  }

  private func presentNext() {
    guard !closed, active == nil, !queue.isEmpty else { return }
    guard let window, window.isVisible, window.attachedSheet == nil else {
      // Do not let AppKit build another unbounded sheet queue behind unrelated UI.
      close()
      return
    }
    let pending = queue.removeFirst()
    let alert = makeAlert(for: pending.request)
    active = Active(pending: pending, alert: alert)
    // The completion owns state through dismissal, even if the wrapper is released.
    let id = pending.id
    alert.beginSheetModal(for: window) { [self] response in
      MainActor.assumeIsolated { finish(id: id, response: response) }
    }
    // Return and Escape both decline. Send has no implicit keyboard equivalent.
    alert.window.defaultButtonCell = alert.buttons[0].cell as? NSButtonCell
    alert.window.makeFirstResponder(alert.buttons[0])
  }

  private func finish(id: UUID, response: NSApplication.ModalResponse) {
    guard let current = active, current.pending.id == id else { return }
    current.alert.window.orderOut(nil)
    let granted = response == .alertSecondButtonReturn && !current.cancelled && !closed
      && window?.isVisible == true
    active = nil
    current.pending.continuation.resume(returning: granted)
    presentNext()
  }

  private func makeAlert(for request: BridgeRequest) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Send this request for correction?"
    alert.informativeText = "Only this request is authorized. Review the destination and all text below. Source fields are reference content, not instructions."
    let cancel = alert.addButton(withTitle: "Cancel")
    cancel.keyEquivalent = "\u{1b}"
    let send = alert.addButton(withTitle: "Send this request")
    send.keyEquivalent = ""

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    // Trusted labels and values are separate from renderer-controlled request fields.
    appendField("Provider (native configuration)", value: providerName, height: 36, to: stack)
    appendField("Destination (native configuration)", value: destination, height: 52, to: stack)
    appendField("Model (native configuration)", value: model, height: 36, to: stack)
    appendField("Full text to correct", value: request.text, height: 160, to: stack)
    if let source = request.source {
      appendField("Source title", value: source.title, height: 36, to: stack)
      appendField("Source section", value: source.section, height: 36, to: stack)
      appendField("Full source excerpt", value: source.excerpt, height: 100, to: stack)
    } else {
      stack.addArrangedSubview(NSTextField(labelWithString: "Source: none"))
    }
    appendField("Correction options", value:
      "Vocabulary: \(request.policy.vocabulary)\nFocus: \(request.policy.focus)\nMaximum notes: \(request.policy.maxNotes)\nAlternatives: \(request.policy.alternatives ? "yes" : "no")",
      height: 64, to: stack)

    // The outer viewport fits short screens; each exact-value field can also scroll.
    let viewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 420))
    viewport.hasVerticalScroller = true
    viewport.documentView = stack
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: viewport.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: viewport.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: viewport.contentView.topAnchor),
    ])
    alert.accessoryView = viewport
    return alert
  }

  private func appendField(_ label: String, value: String, height: CGFloat, to stack: NSStackView) {
    stack.addArrangedSubview(NSTextField(labelWithString: label))
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 510, height: height))
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.importsGraphics = false
    text.isAutomaticLinkDetectionEnabled = false
    text.isAutomaticDataDetectionEnabled = false
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: 510, height: CGFloat.greatestFiniteMagnitude)
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.string = value // No HTML, Markdown, truncation, or attributed-string interpretation.
    text.setAccessibilityLabel(label)
    scroll.documentView = text
    stack.addArrangedSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scroll.heightAnchor.constraint(equalToConstant: height),
    ])
  }
}

/// NotificationCenter observer removal is thread-safe. This immutable token wrapper
/// lets Swift 6 nonisolated deinit remove observation without touching AppKit state.
private final class CloseObservation: @unchecked Sendable {
  private let token: NSObjectProtocol
  init(_ token: NSObjectProtocol) { self.token = token }
  func invalidate() { NotificationCenter.default.removeObserver(token) }
}
