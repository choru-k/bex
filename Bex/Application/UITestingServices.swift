#if DEBUG
  import Foundation

  actor UITestingGrammarService: GrammarServicing, PromptGrammarServicing {
    func check(
      text: String,
      provider: LLMProvider,
      model: String,
      profilePrompt: String?
    ) async throws -> GrammarResult {
      if text == "this are a test" {
        return GrammarResult(
          corrected: "this is a test",
          explanation: "Changed subject-verb agreement."
        )
      }
      return GrammarResult(corrected: text, explanation: "No changes needed.")
    }

    func checkPrompt(
      text: String,
      provider: LLMProvider,
      model: String
    ) async throws -> GrammarResult {
      if text == "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1" {
        return GrammarResult(
          corrected: "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1",
          explanation: "Corrected capitalization, agreement, and spelling."
        )
      }
      return GrammarResult(corrected: text, explanation: "No changes needed.")
    }

    func rewrite(
      text: String,
      intent: RewriteIntent,
      provider: LLMProvider,
      model: String
    ) async throws -> String {
      switch intent {
      case .formal:
        "This is a test."
      case .friendly:
        "This is a friendly test."
      case .shorter:
        "A test."
      }
    }

    func generateProfile(
      context: ProfileContext,
      provider: LLMProvider,
      model: String
    ) async throws -> String {
      "Keep the writing concise and appropriate for the stated audience."
    }

    func fetchModels(for provider: LLMProvider) async throws -> [ModelOption] {
      [ModelOption(id: provider.defaultModel, name: provider.defaultModel)]
    }
  }

  @MainActor
  final class UITestingPasteboard: PasteboardWriting {
    private let fileURL: URL

    init() {
      if let path = ProcessInfo.processInfo.environment["BEX_UI_TEST_PASTEBOARD_PATH"] {
        fileURL = URL(fileURLWithPath: path)
      } else {
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
          "BexUITestingPasteboard-\(ProcessInfo.processInfo.processIdentifier).txt"
        )
      }
      try? FileManager.default.removeItem(at: fileURL)
    }

    func write(_ string: String) throws {
      do {
        try string.write(to: fileURL, atomically: true, encoding: .utf8)
      } catch {
        throw BexError.storageFailure("Bex could not copy the correction.")
      }
    }
  }

  @MainActor
  final class UITestingPromptTargetService: PromptTargetServicing {
    private let source: String
    private let sinkURL: URL
    var isAccessibilityTrusted = true

    init() {
      source = ProcessInfo.processInfo.environment["BEX_UI_TEST_PROMPT_SOURCE"] ?? ""
      let path = ProcessInfo.processInfo.environment["BEX_UI_TEST_PROMPT_TARGET_PATH"]
      sinkURL = path.map(URL.init(fileURLWithPath:))
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "BexUITestingPromptTarget-\(ProcessInfo.processInfo.processIdentifier).txt"
        )
      try? FileManager.default.removeItem(at: sinkURL)
    }

    func requestAccessibilityTrust() -> Bool {
      true
    }

    func captureFrontmostTarget() throws -> PromptCapture {
      let target = PromptTarget(
        kind: source.isEmpty ? .composerPaste : .capturedField,
        processID: 42,
        bundleID: "com.bex.ui-test-target",
        applicationName: "UI Test Target",
        guidance: source.isEmpty
          ? "Bex will paste the correction. Press Return in the target to submit."
          : "Bex will replace this exact field after approval."
      )
      return PromptCapture(
        draft: source,
        target: target,
        source: source.isEmpty ? .composer : .capturedField
      )
    }

    func target(for hookRequest: HookReviewRequest) throws -> PromptTarget {
      PromptTarget(
        kind: .copyOnly,
        applicationName: "UI Test Hook",
        guidance: "Replace the destination draft with this correction manually.",
        hookContext: PromptHookContext(
          requestID: hookRequest.requestID,
          sessionID: hookRequest.sessionID,
          cwd: hookRequest.cwd,
          helperPID: hookRequest.helperPID
        )
      )
    }

    func deliver(
      _ correctedText: String,
      to target: PromptTarget,
      pressReturn: Bool
    ) async throws -> PromptDeliveryOutcome {
      if ProcessInfo.processInfo.environment["BEX_UI_TEST_PROMPT_DELIVERY_ERROR"] == "1" {
        throw BexError.promptDeliveryFailed("Forced UI test delivery failure.")
      }
      try correctedText.write(to: sinkURL, atomically: true, encoding: .utf8)
      return pressReturn ? .submitted : target.kind == .copyOnly ? .copied : .pasted
    }

    func discard(_ target: PromptTarget) {}
  }

  actor UITestingHookManager: HookInstallationManaging {
    func status(for client: PromptClient) async -> HookInstallationStatus { .notInstalled }
    func install(_ client: PromptClient) async throws {}
    func uninstall(_ client: PromptClient) async throws {}
  }

  actor UITestingPromptGateIPC: PromptGateIPCServicing, HookReviewResponding {
    func setHandlers(
      onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
      onInvalidation: @escaping @Sendable (UUID) async -> Void
    ) async {}
    func start() async throws {}
    func stop() async {}
    func complete(
      requestID: UUID,
      outcome: HookReviewOutcome,
      awaitAcknowledgement: Bool
    ) async throws {}
  }

  @MainActor
  extension AppServices {
    static func uiTesting(seedCredential: Bool) async -> AppServices {
      let suite = "com.bex.desktop.ui-testing"
      let defaults = UserDefaults(suiteName: suite)!
      defaults.removePersistentDomain(forName: suite)
      let preferences = PreferencesStore(defaults: defaults)

      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BexUITesting-\(ProcessInfo.processInfo.processIdentifier)")
      try? FileManager.default.removeItem(at: directory)
      let data = BexDataStore(fileURL: directory.appendingPathComponent("data.json"))

      let keychain = KeychainStore(
        service: "com.bex.desktop.credentials.ui-testing",
        inMemory: true
      )
      if seedCredential {
        try? await keychain.saveAPIKey("ui-testing-key", for: .openAI)
      }

      let transport = URLSessionTransport()
      let grammar = UITestingGrammarService()
      let promptTarget: any PromptTargetServicing
      if ProcessInfo.processInfo.environment["BEX_UI_TEST_REAL_TARGET"] == "1" {
        await preferences.setPromptDeliveryMode(.pasteOnly)
        promptTarget = PromptTargetService()
      } else {
        promptTarget = UITestingPromptTargetService()
      }
      let hookManager = UITestingHookManager()
      let promptGateIPC = UITestingPromptGateIPC()
      return AppServices(
        preferences: preferences,
        keychain: keychain,
        data: data,
        grammar: grammar,
        promptGrammar: grammar,
        pasteboard: UITestingPasteboard(),
        promptTarget: promptTarget,
        approvalStore: PromptApprovalStore(
          directoryURL: directory.appendingPathComponent("receipts")
        ),
        hookManager: hookManager,
        promptGateIPC: promptGateIPC,
        codexOAuth: CodexOAuthService(keychain: keychain, transport: transport),
        autoDismissQuickCheck: false
      )
    }
  }
#endif
