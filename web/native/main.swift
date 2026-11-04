import AppKit
import Darwin
import WebKit

// These scripts are exercised verbatim by native-smoke.spec.ts. They expose no
// native API. Diagnostics are bounded and do not directly read editor/source fields.
// Error, alert and corrected-result text may still contain page-provided content.
private let smokeErrorCaptureScript = #"""
(() => {
  const errors = [];
  window.__bexWebLabSmokeErrors = errors;
  const record = value => {
    if (errors.length < 5) errors.push(String(value).slice(0, 500));
  };
  window.addEventListener('error', event => record(event.message || 'Page script/resource error'), true);
  window.addEventListener('unhandledrejection', event => {
    const reason = event.reason;
    record(reason && typeof reason.message === 'string' ? reason.message : 'Unhandled promise rejection');
  });
})();
"""#

private let smokeProbeScript = #"""
(shouldClick => {
  const root = document.querySelector('.shell');
  const button = document.querySelector('button.primary');
  const corrected = document.querySelector('[data-testid=corrected]')?.textContent || '';
  const alert = document.querySelector('[role=alert]')?.textContent || '';
  const errors = Array.isArray(window.__bexWebLabSmokeErrors) ? window.__bexWebLabSmokeErrors.slice(0, 5) : [];
  const ready = root?.getAttribute('data-lab-ready') === 'true';
  const state = root?.getAttribute('data-lab-state') || 'missing';
  let phase = 'waiting-ready';
  let clicked = false;
  if (errors.length || alert) phase = 'error';
  else if (corrected) phase = 'result';
  else if (ready) {
    if (state === 'pending') phase = 'pending';
    else if (!button || button.disabled) phase = 'waiting-button';
    else if (shouldClick && state === 'idle') {
      button.click();
      clicked = true;
      phase = 'click-dispatched';
    } else phase = 'idle';
  }
  return { phase, clicked, ready, state, corrected: corrected.slice(0, 200),
    alert: alert.slice(0, 500), errors, documentState: document.readyState,
    buttonPresent: !!button, buttonDisabled: button ? button.disabled : null };
})
"""#

// Development-only shell. No AX access, Keychain access, file bridge, hook installer,
// production Bex services, or script-message handlers. Never ship this as Bex.app.
@MainActor
final class WebLabDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
  private var window: NSWindow?
  private let smoke = ProcessInfo.processInfo.environment["BEX_WEB_LAB_SMOKE"] == "1"
  private var smokeClickRequested = false
  private var smokeStarted = false
  private var smokeLastPhase = "not-started"
  private var smokeLastSnapshot = "No page probe has completed."
  private let origin = URL(string: "http://127.0.0.1:5179")!

  func applicationDidFinishLaunching(_ notification: Notification) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    if smoke {
      configuration.userContentController.addUserScript(WKUserScript(
        source: smokeErrorCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
      ))
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    if #available(macOS 13.3, *) { webView.isInspectable = true }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 900),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    window.title = "Bex Web Lab — development samples only"
    window.minSize = NSSize(width: 430, height: 550)
    window.contentView = webView
    window.isReleasedWhenClosed = false
    window.center()
    self.window = window

    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Bex Web Lab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let editItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu
    menu.addItem(editItem)
    NSApp.mainMenu = menu

    if smoke {
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak webView] in
        print("BEX_WEB_LAB_SMOKE FAIL: timed out; URL=\(webView?.url?.absoluteString ?? "nil"), loading=\(webView?.isLoading ?? false), clickRequested=\(self?.smokeClickRequested ?? false)")
        print("BEX_WEB_LAB_SMOKE last snapshot: \(self?.smokeLastSnapshot ?? "delegate unavailable")")
        fflush(stdout)
        exit(1)
      }
    }
    webView.load(URLRequest(url: origin.appendingPathComponent("/")))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    // Restrict navigation, not a claim to be a network firewall. The web page has
    // no native privileges and no provider credentials, even during live reload.
    guard let url = action.request.url, url.scheme == origin.scheme,
      url.host == origin.host, url.port == origin.port,
      url.user == nil, url.password == nil, action.targetFrame?.isMainFrame == true
    else {
      if smoke { print("BEX_WEB_LAB_SMOKE navigation denied: \(action.request.url?.absoluteString ?? "nil")"); fflush(stdout) }
      decisionHandler(.cancel)
      return
    }
    if smoke { print("BEX_WEB_LAB_SMOKE navigation allowed: \(url.absoluteString)"); fflush(stdout) }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    if smoke {
      print("BEX_WEB_LAB_SMOKE FAIL: \(error.localizedDescription)")
      fflush(stdout)
      exit(1)
    }
    let alert = NSAlert()
    alert.messageText = "The Bex web development server is unavailable."
    alert.informativeText = "Close this window and run node scripts/bex-web.mjs desktop again."
    if let window { alert.beginSheetModal(for: window) }
  }

  // Automated smoke mode uses only the same fixed sample as the browser tests.
  // It adds no script-message handler or native capability to the page.
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard smoke, !smokeStarted else { return }
    smokeStarted = true
    print("BEX_WEB_LAB_SMOKE document loaded")
    fflush(stdout)
    pollSmoke(webView)
  }

  private func pollSmoke(_ webView: WKWebView) {
    let script = "JSON.stringify((\(smokeProbeScript))(\(smokeClickRequested ? "false" : "true")))"
    webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
      guard let self, let webView else { return }
      if let error {
        print("BEX_WEB_LAB_SMOKE FAIL: \(error.localizedDescription)")
        fflush(stdout)
        exit(1)
      }
      guard let snapshot = value as? String, let data = snapshot.data(using: .utf8),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let phase = object["phase"] as? String else {
        print("BEX_WEB_LAB_SMOKE FAIL: invalid page probe response")
        fflush(stdout)
        exit(1)
      }
      self.smokeLastSnapshot = snapshot
      if object["clicked"] as? Bool == true { self.smokeClickRequested = true }
      if phase != self.smokeLastPhase {
        self.smokeLastPhase = phase
        // A dispatched click is not evidence that React accepted the request.
        print("BEX_WEB_LAB_SMOKE phase=\(phase): \(snapshot)")
        fflush(stdout)
      }
      if phase == "error" {
        print("BEX_WEB_LAB_SMOKE FAIL: page reported an error; \(snapshot)")
        fflush(stdout)
        exit(1)
      }
      if phase == "result" {
        guard self.smokeClickRequested,
          object["corrected"] as? String == "Wouldn’t this make it harder to maintain?" else {
          print("BEX_WEB_LAB_SMOKE FAIL: unexpected corrected result; \(snapshot)")
          fflush(stdout)
          exit(1)
        }
        print("BEX_WEB_LAB_SMOKE PASS: React ready, click dispatched, corrected result rendered")
        fflush(stdout)
        exit(0)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak webView] in
        guard let self, let webView else { return }
        self.pollSmoke(webView)
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WebLabApplication {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = WebLabDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
