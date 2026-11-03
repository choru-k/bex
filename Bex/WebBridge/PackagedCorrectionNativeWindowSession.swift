import AppKit

extension PackagedCorrectionWindowOwner {
  /// Captures existing stores only. No window, WebKit, preferences read, credential
  /// read, provider transport or Task is created until a future explicit open.
  convenience init(preferences: PreferencesStore, keychain: KeychainStore) {
    self.init { onClose in
      PackagedCorrectionNativeWindowSession(preferences: preferences,
        keychain: keychain, onClose: onClose)
    }
  }
}

/// Real native implementation for the dormant app owner. No arbitrary bundle, URL,
/// provider destination, settings snapshot or renderer-supplied factory is accepted.
@MainActor
private final class PackagedCorrectionNativeWindowSession: NSObject,
  PackagedCorrectionWindowSession, NSWindowDelegate {
  private let window: NSWindow
  private let preferences: PreferencesStore
  private let keychain: KeychainStore
  private let onClose: @MainActor @Sendable () -> Void
  private var host: PackagedCorrectionHost?
  private var closed = false
  var isClosed: Bool { closed || host?.isClosed == true }

  init(preferences: PreferencesStore, keychain: KeychainStore,
       onClose: @escaping @MainActor @Sendable () -> Void) {
    self.preferences = preferences
    self.keychain = keychain
    self.onClose = onClose
    // Creation happens only inside the owner's serialized, explicit open operation.
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: true)
    super.init()
    window.title = "Bex Correction"
    window.contentMinSize = NSSize(width: 720, height: 480)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
  }

  func prepare() async throws {
    guard !closed, host == nil else { throw CancellationError() }
    try Task.checkCancellation()
    // make replaces this factory's transport with its own isolated transport. It
    // reserves the shared account epoch BEFORE reading a native settings snapshot.
    let factory = ProviderClientFactory(preferences: preferences, keychain: keychain,
      transport: URLSessionTransport())
    let candidate = try await PackagedCorrectionHost.make(window: window, factory: factory)
    host = candidate
    guard !closed, !candidate.isClosed, !Task.isCancelled else {
      candidate.close()
      await candidate.closeAndWait()
      throw CancellationError()
    }
    window.contentView = candidate.view
  }

  func present() {
    guard !isClosed, host != nil else { return }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func close() {
    guard !closed else { return }
    closed = true
    host?.close()
    window.close()
  }

  func closeAndWait() async {
    close()
    await host?.closeAndWait()
    window.contentView = nil
    host = nil
  }

  func windowWillClose(_ notification: Notification) {
    guard let closingWindow = notification.object as? NSWindow,
      closingWindow === window else { return }
    closed = true
    host?.close()
    onClose()
  }
}
