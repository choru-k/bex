import AppKit
import OSLog
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
  private let services: AppServices
  private static let signposter = OSSignposter(subsystem: "com.bex.desktop", category: "ui")
  private var quickCheckInterval: OSSignpostIntervalState?

  private var quickCheckPanelController: QuickCheckPanelController?
  private var quickCheckViewModel: QuickCheckViewModel?
  private var promptGatePanelController: PromptGatePanelController?
  private var promptGateViewModel: PromptGateViewModel?
  private var historyWindowController: NSWindowController?
  private var profilesWindowController: NSWindowController?
  private var settingsWindowController: NSWindowController?

  init(services: AppServices) {
    self.services = services
    super.init()
  }

  static func beginQuickCheckOpenInterval() -> OSSignpostIntervalState {
    signposter.beginInterval("QuickCheckOpen")
  }

  func showQuickCheck(
    draft: String? = nil,
    signpostInterval: OSSignpostIntervalState? = nil
  ) {
    beginQuickCheckSignpost(signpostInterval)
    if quickCheckPanelController == nil {
      let viewModel = QuickCheckViewModel(
        preferences: services.preferences,
        keychain: services.keychain,
        data: services.data,
        grammar: services.grammar,
        pasteboard: services.pasteboard,
        onClose: { [weak self] in
          self?.closeQuickCheck()
        }
      )
      quickCheckViewModel = viewModel
      let rootView = QuickCheckView(
        viewModel: viewModel,
        openSettings: { [weak self] in self?.showSettings() },
        openProfiles: { [weak self] in self?.showProfiles() },
        openHistory: { [weak self] in self?.showHistory() }
      )
      quickCheckPanelController = QuickCheckPanelController(
        rootView: AnyView(rootView),
        closeAction: { [weak viewModel] in
          viewModel?.panelDidClose()
        },
        focusAction: { [weak self] in
          self?.endQuickCheckSignpost()
        },
        copyAction: { [weak viewModel] in
          viewModel?.copy(closeAfter: false)
        },
        copyAndCloseAction: { [weak viewModel] in
          viewModel?.copy(closeAfter: true)
        },
        autoDismissOnDeactivate: services.autoDismissQuickCheck
      )
    }
    quickCheckPanelController?.show()
    if let quickCheckViewModel {
      Task {
        await quickCheckViewModel.loadContext()
        if let draft {
          quickCheckViewModel.replaceDraft(with: draft)
        }
      }
    }
  }

  func closeQuickCheck() {
    quickCheckPanelController?.closePanel()
  }

  func showPromptGate() {
    if let promptGateViewModel, promptGateViewModel.phase != .closed {
      promptGatePanelController?.show()
      return
    }
    do {
      let capture = try services.promptTarget.captureFrontmostTarget()
      let session = PromptGateSession(
        initialDraft: capture.draft,
        target: capture.target,
        source: capture.source
      )
      showPromptGate(session: session)
    } catch {
      let alert = NSAlert(error: error)
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
    }
  }

  func showPromptGate(hookRequest: HookReviewRequest) -> Bool {
    do {
      let target = try services.promptTarget.target(for: hookRequest)
      let session = PromptGateSession(
        initialDraft: hookRequest.prompt,
        target: target,
        knownClient: hookRequest.client,
        source: .hook(requestID: hookRequest.requestID)
      )
      return showPromptGate(session: session)
    } catch {
      return false
    }
  }

  func invalidatePromptGate(requestID: UUID) {
    promptGateViewModel?.invalidateHookRequest(id: requestID)
  }

  func closePromptGate() {
    promptGatePanelController?.orderOut()
  }

  func showHistory() {
    closeQuickCheck()
    if historyWindowController == nil {
      let viewModel = HistoryViewModel(
        data: services.data,
        useAsNewInput: { [weak self] text in
          self?.historyWindowController?.close()
          self?.showQuickCheck(draft: text)
        }
      )
      historyWindowController = makeWindowController(
        title: "History",
        size: NSSize(width: 760, height: 560),
        rootView: HistoryView(viewModel: viewModel)
      )
    }
    show(historyWindowController)
  }

  func showProfiles() {
    closeQuickCheck()
    if profilesWindowController == nil {
      let viewModel = ProfilesViewModel(
        data: services.data,
        preferences: services.preferences,
        grammar: services.grammar
      )
      profilesWindowController = makeWindowController(
        title: "Profiles",
        size: NSSize(width: 620, height: 520),
        rootView: ProfilesView(viewModel: viewModel)
      )
    }
    show(profilesWindowController)
  }

  func showSettings() {
    closeQuickCheck()
    if settingsWindowController == nil {
      let viewModel = SettingsViewModel(
        preferences: services.preferences,
        keychain: services.keychain,
        grammar: services.grammar,
        codexOAuth: services.codexOAuth,
        promptTarget: services.promptTarget,
        hookManager: services.hookManager,
        applyAppearance: { [weak self] appearance in
          self?.applyAppearance(appearance)
        }
      )
      settingsWindowController = makeWindowController(
        title: "Settings",
        size: NSSize(width: 640, height: 620),
        rootView: SettingsView(viewModel: viewModel)
      )
    }
    show(settingsWindowController)
  }

  func applyStoredAppearance() {
    Task { [weak self, preferences = services.preferences] in
      let appearance = await preferences.appearance()
      self?.applyAppearance(appearance)
    }
  }

  func applyAppearance(_ appearance: AppearancePreference) {
    Self.applyAppearance(appearance)
  }

  static func applyAppearance(_ appearance: AppearancePreference) {
    switch appearance {
    case .system:
      NSApp.appearance = nil
    case .light:
      NSApp.appearance = NSAppearance(named: .aqua)
    case .dark:
      NSApp.appearance = NSAppearance(named: .darkAqua)
    }
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === historyWindowController?.window {
      historyWindowController = nil
    } else if window === profilesWindowController?.window {
      profilesWindowController = nil
    } else if window === settingsWindowController?.window {
      settingsWindowController = nil
    }
  }

  @discardableResult
  private func showPromptGate(session: PromptGateSession) -> Bool {
    if promptGatePanelController == nil {
      let viewModel = PromptGateViewModel(
        preferences: services.preferences,
        keychain: services.keychain,
        promptGrammar: services.promptGrammar,
        targetService: services.promptTarget,
        approvalStore: services.approvalStore,
        hookManager: services.hookManager,
        hookResponder: services.promptGateIPC,
        onClose: { [weak self] in self?.closePromptGate() },
        onOpenSettings: { [weak self] in self?.showSettings() }
      )
      promptGateViewModel = viewModel
      promptGatePanelController = PromptGatePanelController(
        rootView: AnyView(PromptGateView(viewModel: viewModel)),
        cancelAction: { [weak viewModel] in viewModel?.cancel() }
      )
    }
    guard let promptGateViewModel else { return false }
    let began = promptGateViewModel.begin(session)
    promptGatePanelController?.show()
    return began
  }

  private func makeWindowController<Content: View>(
    title: String,
    size: NSSize,
    rootView: Content
  ) -> NSWindowController {
    let hostingController = NSHostingController(rootView: rootView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = title
    window.setContentSize(size)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    return NSWindowController(window: window)
  }

  private func show(_ controller: NSWindowController?) {
    guard let controller else { return }
    NSApp.activate(ignoringOtherApps: true)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }

  private func beginQuickCheckSignpost(_ interval: OSSignpostIntervalState?) {
    if let quickCheckInterval {
      Self.signposter.endInterval("QuickCheckOpen", quickCheckInterval)
    }
    quickCheckInterval = interval ?? Self.beginQuickCheckOpenInterval()
  }

  private func endQuickCheckSignpost() {
    guard let quickCheckInterval else { return }
    Self.signposter.endInterval("QuickCheckOpen", quickCheckInterval)
    self.quickCheckInterval = nil
  }
}
