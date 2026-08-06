import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
  private let services: AppServices
  private static let signposter = OSSignposter(subsystem: "com.bex.desktop", category: "ui")
  static let currentWelcomeVersion = 1
  private var quickCheckInterval: OSSignpostIntervalState?

  private var quickCheckPanelController: QuickCheckPanelController?
  private var quickCheckViewModel: QuickCheckViewModel?
  private var promptGatePanelController: PromptGatePanelController?
  private var promptGateViewModel: PromptGateViewModel?
  private var promptGatePhaseCancellable: AnyCancellable?
  private var promptGateReinvokeCancellable: AnyCancellable?
  private var pendingManualFixAndSendDraft: String?
  private var welcomeWindowController: NSWindowController?
  private var historyWindowController: NSWindowController?
  private var learningWindowController: NSWindowController?
  private var studyWindowController: NSWindowController?
  private var profilesWindowController: NSWindowController?
  private var settingsWindowController: NSWindowController?
  private var settingsViewModel: SettingsViewModel?
  /// Set by `AppDelegate` after construction so opening Learning can refresh the
  /// menu-bar badge it owns, without `WindowCoordinator` holding a reference back to it.
  var onLearningViewed: (() -> Void)?
  struct StandardWindowConfiguration {
    let title: String
    let defaultContentSize: NSSize
    let minimumContentSize: NSSize
    let frameAutosaveName: String
  }

  static let welcomeWindowConfiguration = StandardWindowConfiguration(
    title: "Welcome to Bex",
    defaultContentSize: NSSize(width: 560, height: 420),
    minimumContentSize: NSSize(width: 500, height: 360),
    frameAutosaveName: "Bex.WelcomeWindow"
  )

  static let historyWindowConfiguration = StandardWindowConfiguration(
    title: "History",
    defaultContentSize: NSSize(width: 760, height: 560),
    minimumContentSize: NSSize(width: 620, height: 400),
    frameAutosaveName: "Bex.HistoryWindow"
  )
  static let learningWindowConfiguration = StandardWindowConfiguration(
    title: "Learning",
    defaultContentSize: NSSize(width: 620, height: 520),
    minimumContentSize: NSSize(width: 480, height: 360),
    frameAutosaveName: "Bex.LearningWindow"
  )
  static let studyWindowConfiguration = StandardWindowConfiguration(
    title: "Study",
    defaultContentSize: NSSize(width: 620, height: 520),
    minimumContentSize: NSSize(width: 480, height: 360),
    frameAutosaveName: "Bex.StudyWindow"
  )
  static let writingStylesWindowConfiguration = StandardWindowConfiguration(
    title: "Writing Styles",
    defaultContentSize: NSSize(width: 620, height: 520),
    minimumContentSize: NSSize(width: 580, height: 360),
    frameAutosaveName: "Bex.WritingStylesWindow"
  )
  static let settingsWindowConfiguration = StandardWindowConfiguration(
    title: "Settings",
    defaultContentSize: NSSize(width: 640, height: 620),
    minimumContentSize: NSSize(width: 520, height: 480),
    frameAutosaveName: "Bex.SettingsWindow"
  )

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
        learningLog: services.learningLog,
        onDismiss: { [weak self] reason in
          self?.closeQuickCheck(reason: reason)
        }
      )
      quickCheckViewModel = viewModel
      let rootView = QuickCheckView(
        viewModel: viewModel,
        openSettings: { [weak self] in self?.showSettings(origin: .quickCheck) },
        openWritingStyles: { [weak self] in self?.showProfiles() },
        openHistory: { [weak self] in self?.showHistory() }
      )
      quickCheckPanelController = QuickCheckPanelController(
        rootView: AnyView(rootView),
        dismissalAction: { [weak viewModel] reason in
          viewModel?.panelDidDismiss(reason)
        },
        showAction: { [weak viewModel] in
          viewModel?.sessionDidShow()
        },
        focusAction: { [weak self] in
          self?.endQuickCheckSignpost()
        },
        primaryAction: { [weak viewModel] in
          viewModel?.performPrimaryAction()
        },
        backAction: { [weak viewModel] in
          viewModel?.backToInput()
        },
        copyAction: { [weak viewModel] in
          viewModel?.copy(closeAfter: false)
        },
        autoDismissOnDeactivate: services.autoDismissQuickCheck
      )
    }
    if let draft, let quickCheckViewModel {
      Task { [weak self, weak quickCheckViewModel] in
        guard let self, let quickCheckViewModel else { return }
        await quickCheckViewModel.loadContext()
        guard !Task.isCancelled else { return }
        guard confirmQuickCheckReplacementIfNeeded(quickCheckViewModel) else {
          endQuickCheckSignpost()
          return
        }
        quickCheckViewModel.replaceDraft(with: draft)
        historyWindowController?.close()
        quickCheckPanelController?.show()
      }
    } else {
      quickCheckPanelController?.show()
      if let quickCheckViewModel {
        Task {
          await quickCheckViewModel.loadContext()
        }
      }
    }
  }

  func closeQuickCheck(reason: QuickCheckDismissalReason = .explicitCancel) {
    _ = reason
    quickCheckPanelController?.window?.orderOut(nil)
  }

  func showPromptGate() {
    if pendingManualFixAndSendDraft != nil {
      reinvokeManualFixAndSend()
      return
    }
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

  private func reinvokeManualFixAndSend() {
    guard let draft = pendingManualFixAndSendDraft else { return }
    do {
      let capture = try services.promptTarget.captureFrontmostTarget()
      let newSession = PromptGateSession(
        initialDraft: draft,
        target: capture.target,
        source: capture.source
      )
      pendingManualFixAndSendDraft = nil

      guard let promptGateViewModel, promptGateViewModel.phase != .closed else {
        _ = showPromptGate(session: newSession)
        return
      }
      promptGateReinvokeCancellable = promptGateViewModel.$phase
        .filter { $0 == .closed }
        .prefix(1)
        .sink { [weak self] _ in
          self?.promptGateReinvokeCancellable = nil
          _ = self?.showPromptGate(session: newSession)
        }
      promptGateViewModel.cancel()
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

  func showWelcome() {
    if welcomeWindowController == nil {
      welcomeWindowController = Self.makeWindowController(
        configuration: Self.welcomeWindowConfiguration,
        rootView: WelcomeView(
          dismiss: { [weak self] in
            self?.welcomeWindowController?.close()
          },
          openQuickCheck: { [weak self] in
            self?.welcomeWindowController?.close()
            self?.showQuickCheck()
          },
          setUpProvider: { [weak self] in
            self?.welcomeWindowController?.close()
            self?.showSettings(origin: .quickCheck)
          }
        ),
        delegate: self
      )
    }
    show(welcomeWindowController)
  }

  func showHistory() {
    quickCheckViewModel?.dismiss(.auxiliaryNavigation)
    if historyWindowController == nil {
      let viewModel = HistoryViewModel(
        data: services.data,
        useAsNewInput: { [weak self] text in
          self?.replaceQuickCheckDraftFromHistory(with: text)
        },
        openQuickCheck: { [weak self] in
          self?.historyWindowController?.close()
          self?.showQuickCheck()
        }
      )
      historyWindowController = Self.makeWindowController(
        configuration: Self.historyWindowConfiguration,
        rootView: HistoryView(viewModel: viewModel),
        delegate: self
      )
    }
    show(historyWindowController)
  }

  func showLearning() {
    quickCheckViewModel?.dismiss(.auxiliaryNavigation)
    if learningWindowController == nil {
      let viewModel = LearningViewModel(learningLog: services.learningLog)
      learningWindowController = Self.makeWindowController(
        configuration: Self.learningWindowConfiguration,
        rootView: LearningView(viewModel: viewModel),
        delegate: self
      )
    }
    show(learningWindowController)
    // Clears the ambient badge: opening the window counts as reviewing everything up to
    // now. `Date()` belongs here only — never in the pure `LearningBadge` logic/tests.
    Task { [weak self] in
      guard let self else { return }
      await self.services.preferences.setLastLearningViewedAt(Date())
      self.onLearningViewed?()
    }
  }

  /// Opens the Study drill window. Unlike `showLearning()`, there is no "viewed"
  /// badge to clear here — Study Mode has no ambient badge semantics of its own yet.
  func showStudy() {
    quickCheckViewModel?.dismiss(.auxiliaryNavigation)
    if studyWindowController == nil {
      let viewModel = StudyViewModel(learningLog: services.learningLog, studyState: services.studyState)
      studyWindowController = Self.makeWindowController(
        configuration: Self.studyWindowConfiguration,
        rootView: StudyView(viewModel: viewModel),
        delegate: self
      )
    }
    show(studyWindowController)
  }

  private func replaceQuickCheckDraftFromHistory(with text: String) {
    showQuickCheck(draft: text)
  }

  private func confirmQuickCheckReplacementIfNeeded(
    _ viewModel: QuickCheckViewModel
  ) -> Bool {
    guard viewModel.hasPreservedUserWork else { return true }
    let alert = NSAlert()
    alert.messageText = "Replace the current Quick Check?"
    alert.informativeText =
      "Quick Check has work in progress. Keep it, or replace it with this History entry."
    alert.addButton(withTitle: "Keep Current")
    alert.addButton(withTitle: "Replace")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertSecondButtonReturn
  }

  func showProfiles() {
    quickCheckViewModel?.dismiss(.auxiliaryNavigation)
    if profilesWindowController == nil {
      let viewModel = ProfilesViewModel(
        data: services.data,
        preferences: services.preferences,
        grammar: services.grammar
      )
      profilesWindowController = Self.makeWindowController(
        configuration: Self.writingStylesWindowConfiguration,
        rootView: ProfilesView(viewModel: viewModel),
        delegate: self
      )
    }
    show(profilesWindowController)
  }

  func showSettings(origin: SettingsSetupOrigin? = nil) {
    quickCheckViewModel?.dismiss(.auxiliaryNavigation)
    if origin == .fixAndSend {
      promptGatePanelController?.orderOut()
    }
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
        },
        setupOrigin: origin,
        onDeleteSavedDraft: { [weak self, preferences = services.preferences] in
          if let quickCheckViewModel = self?.quickCheckViewModel {
            await quickCheckViewModel.deletePersistedDraft()
          } else {
            await preferences.deleteSavedQuickDraft()
          }
        },
        onClearHistory: { [data = services.data] in
          try await data.clearHistory()
        },
        onSetupRoute: { [weak self] intent in
          self?.handleSettingsRoute(intent)
        }
      )
      settingsViewModel = viewModel
      settingsWindowController = Self.makeWindowController(
        configuration: Self.settingsWindowConfiguration,
        rootView: SettingsView(viewModel: viewModel),
        delegate: self
      )
    }
    settingsViewModel?.setSetupOrigin(origin)
    show(settingsWindowController)
  }

  private func handleSettingsRoute(_ intent: SettingsRouteIntent) {
    settingsWindowController?.close()
    switch intent {
    case .returnToQuickCheck:
      if let quickCheckViewModel {
        Task {
          await quickCheckViewModel.refreshConfiguration()
          showQuickCheck()
        }
      } else {
        showQuickCheck()
      }
    case .returnToFixAndSendTarget:
      guard let promptGateViewModel, let session = promptGateViewModel.session else { return }
      if session.hookRequestID != nil {
        Task {
          await promptGateViewModel.refreshConfigurationAfterSettings()
          promptGatePanelController?.show()
        }
        return
      }
      pendingManualFixAndSendDraft = promptGateViewModel.draft
      promptGateViewModel.cancel()
      if let processID = session.target.processID {
        NSRunningApplication(processIdentifier: processID)?.activate()
      }
    }
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
    if window === welcomeWindowController?.window {
      Task {
        await services.preferences.setWelcomeCompletedVersion(Self.currentWelcomeVersion)
      }
      welcomeWindowController = nil
      return
    }
    if window === historyWindowController?.window {
      historyWindowController = nil
    } else if window === learningWindowController?.window {
      learningWindowController = nil
    } else if window === studyWindowController?.window {
      studyWindowController = nil
    } else if window === profilesWindowController?.window {
      profilesWindowController = nil
    } else if window === settingsWindowController?.window {
      settingsWindowController = nil
      settingsViewModel = nil
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
        learningLog: services.learningLog,
        onClose: { [weak self] in self?.closePromptGate() },
        onOpenSettings: { [weak self] in self?.showSettings(origin: .fixAndSend) }
      )
      promptGateViewModel = viewModel
      promptGatePanelController = PromptGatePanelController(
        rootView: AnyView(PromptGateView(viewModel: viewModel)),
        cancelAction: { [weak viewModel] in viewModel?.cancel() }
      )
      promptGatePhaseCancellable = viewModel.$phase
        .removeDuplicates()
        .sink { [weak promptGatePanelController] phase in
          promptGatePanelController?.accommodate(phase)
        }
    }
    guard let promptGateViewModel else { return false }
    let began = promptGateViewModel.begin(session)
    promptGatePanelController?.show()
    return began
  }

  static func makeWindowController<Content: View>(
    configuration: StandardWindowConfiguration,
    rootView: Content,
    delegate: (any NSWindowDelegate)? = nil
  ) -> NSWindowController {
    let hostingController = NSHostingController(rootView: rootView)
    let window = NSWindow(contentViewController: hostingController)
    window.title = configuration.title
    window.setContentSize(configuration.defaultContentSize)
    window.contentMinSize = configuration.minimumContentSize
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.delegate = delegate
    let controller = NSWindowController(window: window)
    let restoredSavedFrame = window.setFrameUsingName(configuration.frameAutosaveName)
    _ = window.setFrameAutosaveName(configuration.frameAutosaveName)
    if !restoredSavedFrame {
      window.center()
    }
    return controller
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
