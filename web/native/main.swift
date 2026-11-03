import AppKit
import WebKit

// Development-only shell. No AX access, Keychain access, file bridge, hook installer,
// production Bex services, or script-message handlers. Never ship this as Bex.app.
@MainActor
final class WebLabDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
  private var window: NSWindow?
  private let origin = URL(string: "http://127.0.0.1:5179")!

  func applicationDidFinishLaunching(_ notification: Notification) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
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
    else { decisionHandler(.cancel); return }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    let alert = NSAlert()
    alert.messageText = "The Bex web development server is unavailable."
    alert.informativeText = "Close this window and run node scripts/bex-web.mjs desktop again."
    if let window { alert.beginSheetModal(for: window) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = WebLabDelegate()
app.delegate = delegate
app.run()
