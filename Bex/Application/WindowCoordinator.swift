import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate {
  private let services: AppServices
  static let currentWelcomeVersion = 1
  private var promptGatePanelController: PromptGatePanelController?
  private var promptGateViewModel: PromptGateViewModel?
  private var promptGatePhaseCancellable: AnyCancellable?
  private var pendingPromptGateSession: PromptGateSession?
  private var pendingManualFixAndSendDraft: String?
  private var welcomeWindowController: NSWindowController?
  private var mainWindowController: NSWindowController?
  private var mainWindowModel: MainWindowModel?
  private var mainWindowPageCancellable: AnyCancellable?
  private var studyViewModel: StudyViewModel?
  private var microDrillPanelController: StudyMicroDrillPanelController?
  /// Set by `AppDelegate` after construction so opening Learn can refresh the
  /// menu-bar badge it owns, without `WindowCoordinator` holding a reference back to it.
  var onLearningViewed: (() -> Void)?
  /// Set by `AppDelegate`, which owns the hourly timer — Settings' "Run now" calls the same
  /// gated pass rather than a second copy of it that could drift from the timer's rules.
  var onRunBackgroundAgent: (() -> Void)?

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
    } catch BexError.unsupportedPromptTarget {
      showStandaloneFixAndSend()
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
      pendingPromptGateSession = newSession
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
    guard pendingPromptGateSession != nil else { return }
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self,
        let pendingPromptGateSession,
        promptGateViewModel?.phase == .closed
      else { return }
      self.pendingPromptGateSession = nil
      _ = showPromptGate(session: pendingPromptGateSession)
    }
  }

  /// Offers one card in the corner after a prompt ships, and only if something is already
  /// due (design 1f).
  ///
  /// "Only when due" is doing real work here: a drill that appeared after *every* send
  /// would be a toll on shipping, and non-negotiable 2 forbids that. The card comes from
  /// the same shared session as the hub and the deck, so answering it here is not extra
  /// work on top of today's stack — it is today's stack, cleared at the cheapest moment
  /// in the day.
  private func showMicroDrillIfDue(targetName: String) {
    Task { [weak self] in
      guard let self else { return }
      let study = studyDrill()
      await study.loadIfNeeded()
      guard study.currentCard != nil else { return }
      // Rebuilt per delivery rather than reused: the header names the app the prompt went
      // to, and a cached panel would keep announcing the previous one.
      microDrillPanelController?.close()
      let controller = StudyMicroDrillPanelController(
        rootView: AnyView(
          StudyMicroDrillView(
            viewModel: study,
            targetName: targetName,
            makeKey: { [weak self] in
              self?.microDrillPanelController?.activateForAnswering()
            },
            dismiss: { [weak self] in self?.microDrillPanelController?.close() }
          )
        )
      )
      microDrillPanelController = controller
      controller.show()
    }
  }

  func showWelcome() {
    if welcomeWindowController == nil {
      welcomeWindowController = Self.makeWindowController(
        configuration: Self.welcomeWindowConfiguration,
        rootView: WelcomeView(
          dismiss: { [weak self] in
            self?.welcomeWindowController?.close()
          },
          openFixAndSend: { [weak self] in
            self?.welcomeWindowController?.close()
            self?.showStandaloneFixAndSend()
          },
          setUpProvider: { [weak self] in
            self?.welcomeWindowController?.close()
            self?.showSettings(origin: .fixAndSend)
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
    if mainWindowController == nil {
      let model = MainWindowModel(
        page: page,
        study: studyDrill(),
        learning: LearningViewModel(
          learningLog: services.learningLog,
          considerTaps: services.considerTaps,
          writerLevel: services.writerLevel
        ),
        askThread: makeAskThread(),
        history: HistoryViewModel(
          data: services.data,
          useAsNewInput: { [weak self] text in
            self?.showStandaloneFixAndSend(draft: text, usesDraftPersistence: false)
          },
          openFixAndSend: { [weak self] in
            self?.showStandaloneFixAndSend(draft: "")
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
          openFixAndSend: { [weak self] in self?.showStandaloneFixAndSend() }
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

  func showStandaloneFixAndSend(
    draft: String = "",
    usesDraftPersistence: Bool = true
  ) {
    let session = PromptGateSession(
      initialDraft: draft,
      target: PromptTarget(
        kind: .copyOnly,
        applicationName: "Bex",
        guidance: "Fix & Send will copy the approved correction for use wherever you need it."
      ),
      source: .standalone,
      usesDraftPersistence: usesDraftPersistence
    )
    guard let promptGateViewModel, promptGateViewModel.phase != .closed else {
      mainWindowController?.close()
      _ = showPromptGate(session: session)
      return
    }
    guard confirmFixAndSendReplacement() else {
      promptGatePanelController?.show()
      return
    }
    mainWindowController?.close()
    pendingPromptGateSession = session
    promptGateViewModel.cancel()
    if promptGateViewModel.showsDiscardConfirmation {
      promptGateViewModel.confirmDiscard()
    }
  }

  private func confirmFixAndSendReplacement() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Replace the current Fix & Send draft?"
    alert.informativeText =
      "Fix & Send has work in progress. Keep it, or replace it with this History entry."
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

  /// A fresh ask thread. One per hosting surface, not one shared: a question about a Fix &
  /// Send correction has nothing to do with a question about a drill card, and merging them
  /// would put replies next to text they do not refer to.
  private func makeAskThread() -> AskThreadViewModel {
    AskThreadViewModel(
      grammar: services.grammar,
      preferences: services.preferences,
      learningLog: services.learningLog
    )
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
        if let viewModel = self?.promptGateViewModel, viewModel.usesDraftPersistence {
          await viewModel.deleteSavedDraft()
        } else {
          await preferences.deleteSavedDraft()
        }
      },
      onClearHistory: { [data = services.data] in
        try await data.clearHistory()
      },
      onSetupRoute: { [weak self] intent in
        self?.handleSettingsRoute(intent)
      },
      onRunBackgroundAgent: { [weak self] in
        self?.onRunBackgroundAgent?()
      }
    )
  }

  private func handleSettingsRoute(_ intent: SettingsRouteIntent) {
    mainWindowController?.close()
    switch intent {
    case .returnToFixAndSendTarget:
      guard let promptGateViewModel, let session = promptGateViewModel.session else {
        showStandaloneFixAndSend()
        return
      }
      if session.source == .standalone || session.hookRequestID != nil {
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
      Task { [weak promptGateViewModel] in
        await promptGateViewModel?.refreshWritingStyles()
      }
    }
  }

  @discardableResult
  private func showPromptGate(session: PromptGateSession) -> Bool {
    if promptGatePanelController == nil {
      let viewModel = PromptGateViewModel(
        preferences: services.preferences,
        keychain: services.keychain,
        promptGrammar: services.promptGrammar,
        grammar: services.grammar,
        data: services.data,
        targetService: services.promptTarget,
        approvalStore: services.approvalStore,
        hookManager: services.hookManager,
        hookResponder: services.promptGateIPC,
        learningLog: services.learningLog,
        considerTaps: services.considerTaps,
        onClose: { [weak self] in self?.closePromptGate() },
        onOpenSettings: { [weak self] in self?.showSettings(origin: .fixAndSend) },
        onOpenWritingStyles: { [weak self] in self?.showProfiles() },
        onDelivered: { [weak self] targetName in
          self?.showMicroDrillIfDue(targetName: targetName)
        }
      )
      promptGateViewModel = viewModel
      promptGatePanelController = PromptGatePanelController(
        rootView: AnyView(
          PromptGateView(viewModel: viewModel, askThread: makeAskThread())
        ),
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
    // The root view carries the window's size, as an *ideal* rather than a maximum.
    //
    // A root view that wants to fill (`maxHeight: .infinity`, `Spacer()`s inside) has no
    // opinion about how big it should be, so whatever hosts it picks an extreme: the window
    // opened at the full height of the display. The two obvious levers both misfire —
    // `sizingOptions = []` stops the host resizing the view *with* the window, so the view
    // keeps a taller layout and gets clipped (this is what silently pushed the drill's top bar
    // off the top edge and its progress dots off the bottom, while the centred card still
    // looked right), and an `NSHostingView` resolves the same fill to the largest size on
    // offer. Stating min and ideal here gives the layout the one thing it was missing — a
    // preferred size — while leaving it free to grow when the owner resizes.
    let sizedRootView = rootView.frame(
      minWidth: configuration.minimumContentSize.width,
      idealWidth: configuration.defaultContentSize.width,
      minHeight: configuration.minimumContentSize.height,
      idealHeight: configuration.defaultContentSize.height
    )
    let hostingController = NSHostingController(rootView: sizedRootView)
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

}
