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
  private var mainWindowController: NSWindowController?
  private var mainWindowModel: MainWindowModel?
  private var mainWindowPageCancellable: AnyCancellable?
  private var studyViewModel: StudyViewModel?
  /// Set by `AppDelegate` after construction so opening Learn can refresh the
  /// menu-bar badge it owns, without `WindowCoordinator` holding a reference back to it.
  var onLearningViewed: (() -> Void)?

  /// The one drill session, shared by the menu-bar hub and the Learn deck.
  ///
  /// Two instances would mean two queues over the same persisted state: a card cleared in
  /// the popover would still be sitting in the window's session, and the owner would be
  /// asked the same question twice. Sharing one makes "clear a card from the menu bar" and
  /// "keep going in the window" the same session, which is exactly what the redesign
  /// promises. Created on first use so launch does not read the learning log before
  /// anything has asked for a card.
  func studyDrill() -> StudyViewModel {
    if let studyViewModel { return studyViewModel }
    let viewModel = StudyViewModel(
      learningLog: services.learningLog,
      considerTaps: services.considerTaps,
      studyState: services.studyState
    )
    studyViewModel = viewModel
    return viewModel
  }
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

  /// The one window. Replaces the five separate configurations Bex used to keep — History,
  /// Learning, Study, Writing Styles and Settings each had their own frame, title and
  /// autosave name, which is five windows the owner had to find and arrange for one app.
  /// Sized to hold the widest page (Settings) next to a 196pt sidebar.
  static let mainWindowConfiguration = StandardWindowConfiguration(
    title: "Bex",
    defaultContentSize: NSSize(width: 920, height: 560),
    minimumContentSize: NSSize(width: 720, height: 440),
    frameAutosaveName: "Bex.MainWindow"
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
        mainWindowController?.close()
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

  /// Brings up the one window on `page`, building it the first time.
  ///
  /// Every former `showHistory()`/`showLearning()`/`showStudy()`/`showProfiles()` call
  /// site funnels through here, so "open Bex at Writing Styles" and "the owner clicked
  /// Writing Styles in the sidebar" are the same operation and cannot drift apart.
  func showMain(_ page: MainWindowPage) {
    quickCheckViewModel?.dismiss(.auxiliaryNavigation)
    if mainWindowController == nil {
      let model = MainWindowModel(
        page: page,
        study: studyDrill(),
        learning: LearningViewModel(
          learningLog: services.learningLog,
          considerTaps: services.considerTaps
        ),
        history: HistoryViewModel(
          data: services.data,
          useAsNewInput: { [weak self] text in
            self?.replaceQuickCheckDraftFromHistory(with: text)
          },
          openQuickCheck: { [weak self] in
            self?.mainWindowController?.close()
            self?.showQuickCheck()
          }
        ),
        profiles: ProfilesViewModel(
          data: services.data,
          preferences: services.preferences,
          grammar: services.grammar
        ),
        settings: makeSettingsViewModel()
      )
      mainWindowModel = model
      mainWindowController = Self.makeWindowController(
        configuration: Self.mainWindowConfiguration,
        rootView: BexMainWindow(
          model: model,
          openQuickCheck: { [weak self] in self?.showQuickCheck() }
        ),
        delegate: self
      )
      observeMainWindowPage(model)
    }
    mainWindowModel?.page = page
    show(mainWindowController)
  }

  /// Retitles the window for whichever page is showing, whether that page was routed to
  /// or picked in the sidebar.
  ///
  /// One window with four pages still needs to say which one it is — in the Window menu,
  /// in Mission Control, and to anything driving the app through accessibility. Titling it
  /// "Bex" throughout would make all four indistinguishable from outside.
  private func observeMainWindowPage(_ model: MainWindowModel) {
    mainWindowPageCancellable = model.$page
      .removeDuplicates()
      .sink { [weak self] page in
        self?.mainWindowController?.window?.title = page.title
        if page == .learn { self?.markLearningViewed() }
      }
  }

  /// Clears the ambient "new corrections" badge: landing on Learn counts as reviewing
  /// everything up to now. `Date()` belongs here only — never in the pure `LearningBadge`
  /// logic or its tests.
  private func markLearningViewed() {
    Task { [weak self] in
      guard let self else { return }
      await self.services.preferences.setLastLearningViewedAt(Date())
      self.onLearningViewed?()
    }
  }

  func showHistory() {
    showMain(.history)
  }

  func showLearning() {
    showMain(.learn)
  }

  /// The drill now lives in Learn's Deck tab, so "open Study" and "open Learning" land on
  /// the same page. Kept as a distinct entry point because the daily reminder
  /// notification and `bex://study` both mean "put a card in front of me", and that
  /// intent is worth keeping legible at the call site.
  func showStudy() {
    showMain(.learn)
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
    showMain(.writingStyles)
  }

  func showSettings(origin: SettingsSetupOrigin? = nil) {
    if origin == .fixAndSend {
      promptGatePanelController?.orderOut()
    }
    showMain(.settings)
    mainWindowModel?.settings.setSetupOrigin(origin)
  }

  private func makeSettingsViewModel() -> SettingsViewModel {
    SettingsViewModel(
      preferences: services.preferences,
      keychain: services.keychain,
      grammar: services.grammar,
      codexOAuth: services.codexOAuth,
      promptTarget: services.promptTarget,
      hookManager: services.hookManager,
      applyAppearance: { [weak self] appearance in
        self?.applyAppearance(appearance)
      },
      setupOrigin: nil,
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
  }

  private func handleSettingsRoute(_ intent: SettingsRouteIntent) {
    mainWindowController?.close()
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
    if window === mainWindowController?.window {
      mainWindowController = nil
      mainWindowModel = nil
      mainWindowPageCancellable = nil
      // `studyViewModel` deliberately survives: it is the session the menu-bar hub is
      // still showing, and closing the window is not finishing the drill.
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
