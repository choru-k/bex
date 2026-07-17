#if DEBUG
  import Foundation

  actor UITestingGrammarService: GrammarServicing {
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
      return AppServices(
        preferences: preferences,
        keychain: keychain,
        data: data,
        grammar: UITestingGrammarService(),
        pasteboard: UITestingPasteboard(),
        codexOAuth: CodexOAuthService(keychain: keychain, transport: transport),
        autoDismissQuickCheck: false
      )
    }
  }
#endif
