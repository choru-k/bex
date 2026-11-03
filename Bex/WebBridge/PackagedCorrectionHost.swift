import AppKit
import WebKit
import NativeBridgeCore

/// UNACTIVATED candidate: no composition root constructs this type. No build phase
/// currently packages BexWebUI. Admission and every cooperative Bex-owned account /
/// destination write share AccountMutationCoordinator. This does not coordinate
/// external Keychain / preferences writers or establish native runtime validation.
@MainActor
final class PackagedCorrectionHost: NSObject, WKNavigationDelegate {
  enum HostError: Error { case missingPackagedUI, unsupportedProvider, invalidDocument }
  private static let handlerName = "bexCorrection"
  private let documentURL: URL
  private let webView: WKWebView
  private let presenter: NativeCorrectionConsentPresenter
  private let providerTransport: NativeProviderTransport
  private var coordinator: NativeCorrectionCoordinator?
  private var lifetime: PackagedCorrectionHostLifetime?
  private var allowedInitialNavigation = false
  private var committed = false
  private var closed = false
  var view: NSView { webView }
  var isClosed: Bool { closed }

  // A weak relay avoids WKUserContentController -> host -> WKWebView cycles.
  @MainActor private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var owner: PackagedCorrectionHost?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
      owner?.receive(message)
    }
  }

  /// No arbitrary URL/bundle/development-server or caller-supplied configuration
  /// initializer is exposed. A previous destination/effort value cannot be paired
  /// with newly read credentials: configuration is captured after reserving admission.
  static func make(window: NSWindow, factory: ProviderClientFactory) async throws
    -> PackagedCorrectionHost {
    let barrier = AccountMutationCoordinator.shared
    let reservation = try barrier.reserveAdmission()
    let construction = ConstructionObservation(window: window)
    defer { construction.stopObserving() }
    try Task.checkCancellation()
    let snapshot = try await factory.preferences.nativeCorrectionConfiguration()
    try barrier.validateAdmission(reservation)
    try construction.checkOpen()
    try Task.checkCancellation()
    guard snapshot.destination.provider != .openAICodex else {
      throw HostError.unsupportedProvider
    }
    // Validate the exact manifest, CSP template, inventory and content hashes before
    // any WebKit construction/load. Only Bundle.main can supply an admission.
    let admitted = try NativePackagedResourceValidator.validateMainBundle()
    let root = admitted.resourceURL
    let document = admitted.documentURL
    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "BexPackagedCorrectionNoNetwork-v1",
      encodedContentRuleList: Self.networkRules)
    try barrier.validateAdmission(reservation)
    try construction.checkOpen()
    try Task.checkCancellation()
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.preferences.javaScriptCanOpenWindowsAutomatically = false
    config.userContentController.add(rules)
    config.userContentController.addUserScript(WKUserScript(source: Self.endpointScript,
      injectionTime: .atDocumentStart, forMainFrameOnly: true))
    let relay = MessageRelay()
    config.userContentController.add(relay, name: handlerName)
    let host = try PackagedCorrectionHost(window: window, factory: factory,
      destination: snapshot.destination, effort: snapshot.effort, document: document,
      configuration: config, barrier: barrier)
    do {
      try Task.checkCancellation()
      try construction.checkOpen()
      // registerHost revalidates the same epoch atomically with insertion. No
      // suspension occurs between registration, relay installation and document load.
      guard let lifetime = host.lifetime else { throw HostError.invalidDocument }
      try lifetime.register(reservation: reservation)
      relay.owner = host
      host.webView.navigationDelegate = host
      host.webView.loadFileURL(document, allowingReadAccessTo: root)
      return host
    } catch {
      // A rejected candidate never loads or receives bridge messages. Still drain
      // the resources it constructed; cancellation does not skip that cleanup.
      await host.closeAndWait()
      throw error
    }
  }

  // Observe the window before either construction await. A window closed during
  // rule compilation must not acquire a newly loaded, orphaned host afterward.
  @MainActor private final class ConstructionObservation: NSObject {
    private var closed = false
    init(window: NSWindow) {
      super.init()
      NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
        name: NSWindow.willCloseNotification, object: window)
    }
    @objc private func windowWillClose(_ notification: Notification) { closed = true }
    func checkOpen() throws { if closed { throw CancellationError() } }
    func stopObserving() { NotificationCenter.default.removeObserver(self) }
  }

  private init(window: NSWindow, factory: ProviderClientFactory,
               destination: OutboundDestination, effort: ReasoningEffort,
               document: URL, configuration: WKWebViewConfiguration,
               barrier: AccountMutationCoordinator) throws {
    documentURL = document
    webView = WKWebView(frame: .zero, configuration: configuration)
    presenter = try NativeCorrectionConsentPresenter(window: window,
      providerName: destination.provider.displayName,
      destinationDescription: destination.disclosureTarget, model: destination.model)
    providerTransport = try NativeProviderTransport(destination: destination)
    super.init()
    // Never pass the caller's potentially shared/custom transport into this host.
    // The stores stay readable during drain. Their cooperative writes cannot commit
    // until this registered lifetime has fully terminated.
    let isolatedFactory = ProviderClientFactory(preferences: factory.preferences,
      keychain: factory.keychain, transport: providerTransport)
    let provider = NativeStructuredCorrectionProvider(factory: isolatedFactory,
      destination: destination, effort: effort)
    let coordinator = try NativeCorrectionCoordinator(providerName: destination.provider.displayName,
      consent: presenter, provider: provider, emit: { [weak self] json in self?.emit(json) })
    self.coordinator = coordinator
    lifetime = PackagedCorrectionHostLifetime(barrier: barrier,
      revoke: { [weak self, coordinator, providerTransport, presenter] in
        self?.revokeDocument()
        coordinator.close()
        providerTransport.close()
        presenter.close()
      }, drain: { [coordinator, providerTransport] in
        await coordinator.closeAndWait()
        await providerTransport.closeAndWait()
      })
    NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: window)
  }

  private func exactDocument(_ url: URL?) -> Bool {
    // Compare the full URL, not merely a path prefix or origin. Queries/fragments and
    // file URL aliases do not identify the one admitted document.
    url?.absoluteString == documentURL.absoluteString
  }

  private func receive(_ message: WKScriptMessage) {
    guard !closed, committed, message.name == Self.handlerName,
      message.webView === webView, message.frameInfo.isMainFrame,
      exactDocument(message.frameInfo.request.url), exactDocument(webView.url),
      let json = message.body as? String,
      json.utf8.count <= NativeCorrectionBridge.maximumBytes else { return }
    coordinator?.receiveTrustedDocumentMessage(json)
  }

  private func emit(_ json: String) {
    guard !closed, committed, exactDocument(webView.url),
      json.utf8.count <= NativeCorrectionBridge.maximumBytes else { return }
    // WebKit serializes argument values. JSON (including quotes/newlines/script tags)
    // is never interpolated into executable source, and delivery targets main frame.
    webView.callAsyncJavaScript("globalThis.__bexDeliverNativeCorrection(payload)",
      arguments: ["payload": json], in: nil, in: .page) { [weak self] result in
        if case .failure = result { self?.close() }
      }
  }

  @objc private func windowWillClose(_ notification: Notification) { close() }

  /// Synchronous revocation, NOT proof that provider/UI work has terminated.
  /// This starts one owned drain even if the caller does not await closeAndWait().
  func close() { lifetime?.close() }

  private func revokeDocument() {
    guard !closed else { return }
    closed = true
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    committed = false
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
  }

  /// All callers join the same full drain. The barrier registration survives close
  /// and caller cancellation until coordinator AND provider-session termination.
  func closeAndWait() async { await lifetime?.closeAndWait() }

  deinit {
    // The registered lifetime owns coordinator/transport cleanup independently of
    // the view owner. A concurrent mutation can still see and await it before this
    // scheduled close runs; dropping a host cannot silently unregister running work.
    if let lifetime { Task { @MainActor in lifetime.close() } }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard webView === self.webView, !closed, !allowedInitialNavigation,
      navigationAction.targetFrame?.isMainFrame == true,
      exactDocument(navigationAction.request.url) else {
      close()
      decisionHandler(.cancel)
      return
    }
    allowedInitialNavigation = true
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard webView === self.webView, !closed, navigationResponse.isForMainFrame,
      exactDocument(navigationResponse.response.url) else {
      close()
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
    guard webView === self.webView, !closed, allowedInitialNavigation, !committed,
      exactDocument(webView.url) else { close(); return }
    committed = true
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { close() }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) { close() }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }

  // Blocks external scripts, fetches, frames, images and other network resources.
  // Navigation is separately denied above. Packaging/CSP and WebKit runtime checks
  // remain required before activation; Node tests cannot verify WebKit rule behavior.
  private static let networkRules = #"""
  [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
   {"trigger":{"url-filter":"^file://"},"action":{"type":"ignore-previous-rules"}}]
  """#

  // Source-extracted Node tests exercise this exact literal, not a second copy.
  static let endpointScript = #"""
  (() => {
    'use strict';
    if (window !== window.top) return;
    const listeners = new Set();
    const encode = new TextEncoder();
    const valid = value => typeof value === 'string' && encode.encode(value).length <= 128000;
    const send = window.webkit.messageHandlers.bexCorrection.postMessage.bind(window.webkit.messageHandlers.bexCorrection);
    const endpoint = Object.freeze({
      postMessage(json) {
        if (!valid(json)) throw new TypeError('Invalid bridge message.');
        send(json);
      },
      subscribe(listener) {
        if (typeof listener !== 'function' || listeners.size >= 16) throw new TypeError('Invalid bridge listener.');
        listeners.add(listener);
        return () => { listeners.delete(listener); };
      }
    });
    Object.defineProperty(globalThis, '__bexNativeCorrectionEndpoint', { value: endpoint });
    Object.defineProperty(globalThis, '__bexDeliverNativeCorrection', { value: json => {
      if (!valid(json)) return;
      for (const listener of Array.from(listeners)) {
        try { listener(json); } catch (_) { /* A listener cannot block other delivery. */ }
      }
    }});
  })();
  """#
}

/// The exact lifetime owner used by PackagedCorrectionHost. Kept independent of
/// AppKit construction so synthetic tests can hold each drain stage explicitly.
/// The coordinator retains this object until both stages have really returned.
@MainActor
final class PackagedCorrectionHostLifetime {
  private let barrier: AccountMutationCoordinator
  private var registration: UUID?
  private var revokeWork: (@MainActor @Sendable () -> Void)?
  private var drainWork: (@MainActor @Sendable () async -> Void)?
  private var drainTask: Task<Void, Never>?
  private(set) var isClosed = false

  init(barrier: AccountMutationCoordinator,
       revoke: @escaping @MainActor @Sendable () -> Void,
       drain: @escaping @MainActor @Sendable () async -> Void) {
    self.barrier = barrier
    revokeWork = revoke
    drainWork = drain
  }

  func register(reservation: AccountMutationCoordinator.AdmissionReservation) throws {
    guard !isClosed, registration == nil else { throw CancellationError() }
    registration = try barrier.registerHost(reservation: reservation,
      revoke: { [self] in close() }, drain: { [self] in await closeAndWait() })
  }

  func close() {
    guard !isClosed else { return }
    isClosed = true
    revokeWork?()
    revokeWork = nil
    // Unstructured ownership is deliberate: cancellation of a close waiter or a
    // mutation waiter must not cancel the cleanup or mark still-running work done.
    let drain = drainWork
    drainTask = Task { @MainActor [self] in
      await drain?()
      drainWork = nil
      if let registration {
        barrier.removeHost(registration)
        self.registration = nil
      }
      drainTask = nil
    }
  }

  func closeAndWait() async {
    close()
    await drainTask?.value
  }
}
