import Foundation

@MainActor
final class AppServices {
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
    codexOAuth: CodexOAuthService
  ) {
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
        pasteboardWriter: pasteboard,
        pasteboardTransaction: pasteboard
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
