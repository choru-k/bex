import AppKit
import WebKit
import NativeBridgeCore

/// UNACTIVATED candidate: no composition root constructs this type. No build phase
/// currently packages BexWebUI. Account/key/model/endpoint mutation MUST await
/// closeAndWait() before mutating stores or creating another host. Production does
/// not yet implement that barrier; this is an activation blocker, not an account lock.
@MainActor
final class PackagedCorrectionHost: NSObject, WKNavigationDelegate {
  enum HostError: Error { case missingPackagedUI, unsupportedProvider, invalidDocument }
  private static let handlerName = "bexCorrection"
  private let documentURL: URL
  private let webView: WKWebView
  private let presenter: NativeCorrectionConsentPresenter
  private var coordinator: NativeCorrectionCoordinator?
  private var allowedInitialNavigation = false
  private var committed = false
  private var closed = false
  var view: NSView { webView }

  // A weak relay avoids WKUserContentController -> host -> WKWebView cycles.
  @MainActor private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var owner: PackagedCorrectionHost?
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
      owner?.receive(message)
    }
  }

  /// No arbitrary URL/bundle/development-server initializer is exposed.
  static func make(window: NSWindow, factory: ProviderClientFactory,
                   destination: OutboundDestination, effort: ReasoningEffort) async throws
    -> PackagedCorrectionHost {
    guard destination.provider != .openAICodex else { throw HostError.unsupportedProvider }
    guard let resources = Bundle.main.resourceURL else { throw HostError.missingPackagedUI }
    let root = resources.appendingPathComponent("BexWebUI", isDirectory: true)
    let document = root.appendingPathComponent("native.html", isDirectory: false)
    // Reject symlink escape as well as absent/nonregular assets before creating WebKit.
    guard root.resolvingSymlinksInPath().standardizedFileURL == root.standardizedFileURL,
      document.resolvingSymlinksInPath().standardizedFileURL == document.standardizedFileURL,
      (try? document.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { throw HostError.missingPackagedUI }
    let rules = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "BexPackagedCorrectionNoNetwork-v1",
      encodedContentRuleList: Self.networkRules)
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
      destination: destination, effort: effort, document: document, configuration: config)
    relay.owner = host
    host.webView.navigationDelegate = host
    host.webView.loadFileURL(document, allowingReadAccessTo: root)
    return host
  }

  private init(window: NSWindow, factory: ProviderClientFactory,
               destination: OutboundDestination, effort: ReasoningEffort,
               document: URL, configuration: WKWebViewConfiguration) throws {
    documentURL = document
    webView = WKWebView(frame: .zero, configuration: configuration)
    presenter = try NativeCorrectionConsentPresenter(window: window,
      providerName: destination.provider.displayName,
      destinationDescription: destination.disclosureTarget, model: destination.model)
    super.init()
    let provider = NativeStructuredCorrectionProvider(factory: factory,
      destination: destination, effort: effort)
    coordinator = try NativeCorrectionCoordinator(providerName: destination.provider.displayName,
      consent: presenter, provider: provider, emit: { [weak self] json in self?.emit(json) })
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
  func close() {
    guard !closed else { return }
    closed = true
    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
    committed = false
    coordinator?.close()
    presenter.close()
    webView.stopLoading()
    webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
  }

  /// Required before account/provider/destination replacement. Do not mutate stores
  /// first: ProviderClientFactory captures stores, not immutable credential identity.
  func closeAndWait() async {
    close()
    await coordinator?.closeAndWait()
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
