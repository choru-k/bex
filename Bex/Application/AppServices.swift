import AppKit
import Foundation
import UserNotifications


/// A test launch is a dependency choice, not an OS sandbox. Parse it before any
/// production services are constructed, including in Release (which rejects it).
enum AppLaunchMode: Equatable {
  case production
  case isolatedUITesting
  case manualSystemTargetTesting
  case rejectedUITesting

  static var isDebugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }

  static func resolve(
    arguments: [String], environment: [String: String],
    debugBuild: Bool = isDebugBuild
  ) -> Self {
    let requested = arguments.contains("--ui-testing")
      || arguments.contains("--ui-testing-system-target")
      || environment.keys.contains { $0 == "BEX_UI_TESTING" || $0.hasPrefix("BEX_UI_TEST_") }
    guard requested else { return .production }
    guard debugBuild,
      environment["BEX_UI_TESTING"].map({ $0 == "1" }) ?? true,
      arguments.contains("--ui-testing") || environment["BEX_UI_TESTING"] == "1"
    else { return .rejectedUITesting }
    let realTarget = environment["BEX_UI_TEST_REAL_TARGET"] == "1"
    let manualTarget = arguments.contains("--ui-testing-system-target")
    guard realTarget == manualTarget else { return .rejectedUITesting }
    return manualTarget ? .manualSystemTargetTesting : .isolatedUITesting
  }
}

/// The few app-lifecycle/UI effects that are not part of the data/provider services.
/// Closures defer system access until used. Fixture composition supplies inert edges
/// instead of relying on HOME, process environment, or a shared provider mock.
@MainActor
struct AppRuntimeEffects {
  let configureStudyNotifications: @MainActor (any UNUserNotificationCenterDelegate) -> StudyNotificationScheduler?
  let publishStudyStatus: @MainActor (Int, StudyDueCount.StudySeverity, StudyStatusFile.NextCard?, StudyStatusFile.LastResult?, Date) -> Void
  let makeHotKey: @MainActor () -> GlobalHotKey
  let openAuthorizationURL: @MainActor (URL) -> Bool
  let activateExternalApplication: @MainActor (pid_t) -> Void
  let permitsExternalFocus: Bool
  let persistsWindowFrames: Bool
  let usesUITestingCommands: Bool
  let settingsWorkingDirectory: String?
  let settingsOMPExecutablePath: String?

  static func production() -> Self {
    Self(
      configureStudyNotifications: { delegate in
        UNUserNotificationCenter.current().delegate = delegate
        return StudyNotificationScheduler()
      },
      publishStudyStatus: { dueCount, severity, nextCard, lastResult, now in
        StudyStatusFile.write(dueCount: dueCount, severity: severity, nextCard: nextCard,
          lastResult: lastResult, now: now)
      },
      makeHotKey: { GlobalHotKey() },
      openAuthorizationURL: { NSWorkspace.shared.open($0) },
      activateExternalApplication: { NSRunningApplication(processIdentifier: $0)?.activate() },
      permitsExternalFocus: true,
      persistsWindowFrames: true,
      usesUITestingCommands: false,
      settingsWorkingDirectory: nil,
      settingsOMPExecutablePath: nil
    )
  }
}

@MainActor
final class AppServices {
  let runtimeEffects: AppRuntimeEffects
  let preferences: PreferencesStore
  let keychain: KeychainStore
  let data: BexDataStore
  let learningLog: LearningLogStore
  let studyState: StudyStateStore
  let considerTaps: ConsiderTapStore
  let writerLevel: WriterLevelStore
  let studyPatterns: StudyPatternStore
  let grammar: any GrammarServicing
  let promptGrammar: any PromptGrammarServicing
  let pasteboard: any PasteboardWriting
  let promptTarget: any PromptTargetServicing
  let approvalStore: PromptApprovalStore
  let hookManager: any HookInstallationManaging
  let promptGateIPC: any PromptGateIPCServicing & HookReviewResponding
  let codexOAuth: CodexOAuthService
  /// One inert owner; the packaged correction open action remains disabled.
  let packagedCorrectionWindows: PackagedCorrectionWindowOwner

  init(
    preferences: PreferencesStore,
    keychain: KeychainStore,
    data: BexDataStore,
    learningLog: LearningLogStore,
    studyState: StudyStateStore,
    considerTaps: ConsiderTapStore,
    writerLevel: WriterLevelStore,
    studyPatterns: StudyPatternStore,
    grammar: any GrammarServicing,
    promptGrammar: any PromptGrammarServicing,
    pasteboard: any PasteboardWriting,
    promptTarget: any PromptTargetServicing,
    approvalStore: PromptApprovalStore,
    hookManager: any HookInstallationManaging,
    promptGateIPC: any PromptGateIPCServicing & HookReviewResponding,
    codexOAuth: CodexOAuthService,
    runtimeEffects: AppRuntimeEffects = .production()
  ) {
    self.runtimeEffects = runtimeEffects
    self.preferences = preferences
    self.keychain = keychain
    self.data = data
    self.learningLog = learningLog
    self.studyState = studyState
    self.considerTaps = considerTaps
    self.writerLevel = writerLevel
    self.studyPatterns = studyPatterns
    self.grammar = grammar
    self.promptGrammar = promptGrammar
    self.pasteboard = pasteboard
    self.promptTarget = promptTarget
    self.approvalStore = approvalStore
    self.hookManager = hookManager
    self.promptGateIPC = promptGateIPC
    self.codexOAuth = codexOAuth
    packagedCorrectionWindows = PackagedCorrectionWindowOwner(
      preferences: preferences, keychain: keychain
    )
  }

  static func production() -> AppServices {
    let preferences = PreferencesStore()
    let keychain = KeychainStore()
    let data = BexDataStore()
    let learningLog = LearningLogStore()
    let studyState = StudyStateStore()
    let considerTaps = ConsiderTapStore()
    let writerLevel = WriterLevelStore()
    let studyPatterns = StudyPatternStore()
    let transport = URLSessionTransport()
    let factory = ProviderClientFactory(
      preferences: preferences,
      keychain: keychain,
      transport: transport
    )
    let grammar = GrammarService(factory: factory, writerLevel: writerLevel)
    let pasteboard = SystemPasteboard()
    let promptGateIPC = PromptGateIPCServer()
    return AppServices(
      preferences: preferences,
      keychain: keychain,
      data: data,
      learningLog: learningLog,
      studyState: studyState,
      considerTaps: considerTaps,
      writerLevel: writerLevel,
      studyPatterns: studyPatterns,
      grammar: grammar,
      promptGrammar: grammar,
      pasteboard: pasteboard,
      promptTarget: PromptTargetService(
        pasteboardWriter: pasteboard
      ),
      approvalStore: PromptApprovalStore(),
      hookManager: HookInstallationManager(),
      promptGateIPC: promptGateIPC,
      codexOAuth: CodexOAuthService(
        keychain: keychain,
        transport: transport
      )
    )
  }
}
