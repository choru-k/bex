import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

/// Independently shipped service host, not embedded in or launched by Bex.app.
@main
struct BexAccessibilityMain {
  @MainActor
  static func main() {
    #if BEX_UI_TEST_ARTIFACT
      // This independently shipped host is not a UI fixture. Never start its
      // real agent/setup UI when someone builds it in the test configuration.
      return
    #else
    let app = NSApplication.shared
    if Array(CommandLine.arguments.dropFirst()) == ["--agent"] {
      app.setActivationPolicy(.prohibited)
      do {
        let server = try AccessibilityAgentServer(validatingIdentity: ())
        server.start()
        withExtendedLifetime(server) { app.run() }
      } catch {
        // Never downgrade to an unauthenticated listener or request OS permissions.
        return
      }
    } else if CommandLine.arguments.count == 1 {
      app.setActivationPolicy(.regular)
      let setup = AccessibilityAgentSetupWindow()
      withExtendedLifetime(setup) {
        setup.show()
        app.run()
      }
    }
    #endif
  }
}

@MainActor
private final class AccessibilityAgentSetupWindow: NSObject, NSWindowDelegate {
  private let service = SMAppService.agent(plistName: "com.bex.accessibility.agent.plist")
  private let window: NSWindow
  private let status = NSTextField(wrappingLabelWithString: "")
  private var busy = false

  override init() {
    window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    super.init()
    window.title = "Bex Accessibility"
    window.delegate = self
    let title = NSTextField(labelWithString: "Independent, read-only capture service")
    title.font = .boldSystemFont(ofSize: 16)
    let explanation = NSTextField(wrappingLabelWithString:
      "Enable this separately signed service only after installing it at /Applications/BexAccessibility.app and reviewing its release. It reads a focused field only when an authenticated Bex client explicitly asks. It cannot replace text, paste or submit. Bex UI updates never install or replace this app. The current Bex production path does not use this service yet.")
    let enable = NSButton(title: "Enable Capture Service", target: self, action: #selector(enableService))
    let disable = NSButton(title: "Disable Capture Service", target: self, action: #selector(disableService))
    let trust = NSButton(title: "Request Accessibility Permission", target: self, action: #selector(requestTrust))
    let refresh = NSButton(title: "Refresh Status", target: self, action: #selector(refreshStatus))
    let stack = NSStackView(views: [title, explanation, enable, disable, trust, refresh, status])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(stack)
    if let view = window.contentView {
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
        stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
        stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
      ])
    }
    refreshStatus()
  }

  func show() { window.center(); window.makeKeyAndOrderFront(nil) }
  func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

  private func requireReviewedInstallation() throws {
    try AccessibilityAgentIdentity.verifyOwnIdentity(as: .helper)
    guard Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path == "/Applications/BexAccessibility.app"
    else { throw AccessibilityAgentFailure.unavailable }
  }

  @objc private func enableService() {
    guard !busy else { return }
    do {
      try requireReviewedInstallation()
      // This user-click action can bootstrap the service. It is never called on launch,
      // from Bex UI, from an IPC message, from a test, or as an update side effect.
      try service.register()
      refreshStatus()
    } catch { status.stringValue = "Not enabled. A valid signed installation at the stable path is required. \(error.localizedDescription)" }
  }

  @objc private func disableService() {
    guard !busy else { return }
    busy = true
    Task { @MainActor [self] in
      defer { busy = false }
      do {
        try requireReviewedInstallation()
        try await service.unregister()
        refreshStatus()
      } catch { status.stringValue = "Could not disable the service: \(error.localizedDescription)" }
    }
  }

  @objc private func requestTrust() {
    guard !busy else { return }
    do {
      try requireReviewedInstallation()
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
      refreshStatus()
    } catch { status.stringValue = "Permission was not requested. A valid signed installation at the stable path is required." }
  }

  @objc private func refreshStatus() {
    let registration: String
    switch service.status {
    case .enabled: registration = "Service enabled."
    case .requiresApproval: registration = "Approve the background service in System Settings → General → Login Items."
    case .notRegistered: registration = "Service not enabled."
    case .notFound: registration = "Service files are unavailable."
    @unknown default: registration = "Service status is unavailable."
    }
    status.stringValue = registration + (AXIsProcessTrusted()
      ? " Accessibility is currently allowed for this process."
      : " Accessibility is not currently allowed for this process.")
  }
}
