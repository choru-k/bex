#if DEBUG
  import Foundation

  enum UITestScenario: String, Codable, CaseIterable, Sendable {
    static let environmentKey = "BEX_UI_TEST_SCENARIO"

    case standard = "default"
    case welcome
    case freshConsent = "fresh-consent"
    case freshQuickCheck = "fresh-quick-check"
    case configuredProvider = "configured-provider"
    case permissionDenied = "permission-denied"
    case permissionTrusted = "permission-trusted"
    case hookProvidedClient = "hook-provided-client"
    case hookSkipsOutboundConfirmation = "hook-skips-outbound-confirmation"
    case hookCheckInFlight = "hook-check-in-flight"
    case hotKeyConflict = "hotkey-conflict"
    case quickCheckGrammarInFlight = "quick-check-grammar-in-flight"
    case promptDeliveryInFlight = "prompt-delivery-in-flight"
    case deliveryFailureEffect = "delivery-failure-effect"
    case dirtyEditorResume = "dirty-editor-resume"
    case setupResume = "setup-resume"
    case historyEmpty = "history-empty"
    case historyPopulated = "history-populated"
    case profilesEmpty = "profiles-empty"
    case profilesPopulated = "profiles-populated"
    case integrations

    static func parse(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
      guard let value = environment[environmentKey], let scenario = Self(rawValue: value) else {
        return .standard
      }
      return scenario
    }

    static var current: Self {
      parse()
    }

    var configuration: UITestFixtureConfiguration {
      var configuration = UITestFixtureConfiguration()
      switch self {
      case .standard, .welcome:
        break
      case .freshConsent:
        configuration.preferences.draftRetentionChoice = .undecided
        configuration.preferences.historyRetentionChoice = .undecided
        configuration.target.source = "A fresh consent UI test draft."
        configuration.launchDestination = .promptGate
      case .freshQuickCheck:
        configuration.preferences.selectedProvider = .claude
        configuration.preferences.selectedModel = LLMProvider.claude.defaultModel
        configuration.preferences.selectedEffort = .high
        configuration.preferences.draftRetentionChoice = .undecided
        configuration.preferences.historyRetentionChoice = .undecided
        configuration.profiles = UITestFixtureConfiguration.populatedProfiles
        configuration.preferences.activeProfileID =
          UITestFixtureConfiguration.populatedProfiles.first?.id
        configuration.preferences.defaultProfileID =
          UITestFixtureConfiguration.populatedProfiles.first?.id
        configuration.credentialProvider = .claude
        configuration.launchDestination = .quickCheck
      case .configuredProvider:
        configuration.preferences.selectedProvider = .claude
        configuration.preferences.selectedModel = LLMProvider.claude.defaultModel
        configuration.preferences.selectedEffort = .high
        configuration.preferences.draftRetentionChoice = .enabled
        configuration.preferences.historyRetentionChoice = .enabled
        configuration.preferences.acceptedOutboundDisclosureProvider = .claude
        configuration.credentialProvider = .claude
        configuration.launchDestination = .settings
      case .permissionDenied:
        configuration.target.isAccessibilityTrusted = false
        configuration.target.requestedAccessibilityTrust = false
        configuration.launchDestination = .settings
      case .permissionTrusted:
        configuration.target.isAccessibilityTrusted = true
        configuration.target.requestedAccessibilityTrust = true
        configuration.launchDestination = .settings
      case .hookProvidedClient:
        configuration.hook = .init(
          client: .codex,
          prompt: "Make this UI test prompt concise.",
          status: .active(lastSeen: UITestFixtureConfiguration.fixtureDate)
        )
        configuration.launchDestination = .hookPromptGate
      case .hookSkipsOutboundConfirmation:
        configuration.preferences.acceptedOutboundDisclosureProvider = .openAI
        configuration.preferences.confirmsHookOutboundPayloads = false
        configuration.hook = .init(
          client: .codex,
          prompt: "Make this UI test prompt concise.",
          status: .active(lastSeen: UITestFixtureConfiguration.fixtureDate)
        )
        configuration.launchDestination = .hookPromptGate
      case .hookCheckInFlight:
        configuration.preferences.acceptedOutboundDisclosureProvider = .openAI
        configuration.preferences.confirmsHookOutboundPayloads = false
        configuration.hook = .init(
          client: .claudeCode,
          prompt: "Send this simple prompt without waiting for a correction.",
          status: .active(lastSeen: UITestFixtureConfiguration.fixtureDate)
        )
        configuration.grammarBehavior = .holdPromptCheck
        configuration.launchDestination = .hookPromptGate
      case .hotKeyConflict:
        configuration.hotKeyRegistration = .conflict
        configuration.launchDestination = .settings
      case .quickCheckGrammarInFlight:
        configuration.preferences.selectedProvider = .claude
        configuration.preferences.selectedModel = LLMProvider.claude.defaultModel
        configuration.preferences.draftRetentionChoice = .enabled
        configuration.preferences.historyRetentionChoice = .enabled
        configuration.preferences.quickDraft = "this are a test"
        configuration.preferences.acceptedOutboundDisclosureProvider = .claude
        configuration.credentialProvider = .claude
        configuration.grammarBehavior = .holdFirstCheckThenFailSubsequent
        configuration.launchDestination = .quickCheck
      case .promptDeliveryInFlight:
        configuration.target.source =
          "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1"
        configuration.target.deliveryGate = .untilReleased
        configuration.launchDestination = .promptGate
      case .deliveryFailureEffect:
        configuration.target.source = "this are a test"
        configuration.target.deliveryFailureEffect = .pastedNotSubmitted
        configuration.launchDestination = .promptGate
      case .dirtyEditorResume:
        configuration.preservesStoredState = true
        configuration.preferences.draftRetentionChoice = .enabled
        configuration.preferences.quickDraft = "A saved UI test draft with unsent changes."
        configuration.launchDestination = .quickCheck
      case .setupResume:
        configuration.preservesStoredState = true
        configuration.preferences.selectedProvider = .gemini
        configuration.preferences.selectedModel = LLMProvider.gemini.defaultModel
        configuration.credentialProvider = nil
        configuration.launchDestination = .setup(.quickCheck)
      case .historyEmpty:
        configuration.history = []
        configuration.launchDestination = .history
      case .historyPopulated:
        configuration.preferences.historyRetentionChoice = .enabled
        configuration.history = UITestFixtureConfiguration.populatedHistory
        configuration.launchDestination = .history
      case .profilesEmpty:
        configuration.profiles = []
        configuration.launchDestination = .profiles
      case .profilesPopulated:
        configuration.profiles = UITestFixtureConfiguration.populatedProfiles
        configuration.preferences.activeProfileID =
          UITestFixtureConfiguration.populatedProfiles.first?.id
        configuration.preferences.defaultProfileID =
          UITestFixtureConfiguration.populatedProfiles.first?.id
        configuration.launchDestination = .profiles
      case .integrations:
        configuration.integrations = UITestFixtureConfiguration.integrationDescriptors
        configuration.integrationStatuses = [
          PromptClient.claudeCode.rawValue: .installedUnconfirmed,
          PromptClient.codex.rawValue: .awaitingCodexTrust,
          "omp-default": .installedUnconfirmed,
          "omp-team": .active(lastSeen: UITestFixtureConfiguration.fixtureDate),
        ]
        configuration.launchDestination = .settings
      }
      return configuration
    }
  }

  enum UITestLaunchDestination: Equatable, Sendable {
    case none
    case quickCheck
    case promptGate
    case hookPromptGate
    case settings
    case setup(SettingsSetupOrigin)
    case history
    case profiles
  }

  enum UITestHotKeyRegistration: Equatable, Sendable {
    case succeed
    case conflict
  }

  enum UITestGrammarBehavior: Equatable, Sendable {
    case immediate
    case holdFirstCheckThenFailSubsequent
    case holdPromptCheck
  }

  enum UITestDeliveryGate: Equatable, Sendable {
    case immediate
    case untilReleased
  }

  struct UITestPreferenceSeed: Equatable, Sendable {
    var selectedProvider: LLMProvider?
    var selectedModel: String?
    var selectedEffort: ReasoningEffort?
    var activeProfileID: UUID?
    var defaultProfileID: UUID?
    var draftRetentionChoice: RetentionChoice?
    var historyRetentionChoice: RetentionChoice?
    var quickDraft: String?
    var acceptedOutboundDisclosureProvider: LLMProvider?
    var confirmsHookOutboundPayloads: Bool?
  }

  struct UITestTargetSeed: Equatable, Sendable {
    var isAccessibilityTrusted = true
    var requestedAccessibilityTrust = true
    var source = ""
    var sinkPath: String?
    var deliveryFailureEffect: PromptDeliveryEffect?
    var usesRealTarget = false
    var deliveryEventsPath: String?
    var deliveryGate: UITestDeliveryGate = .immediate
  }

  struct UITestHookSeed: Equatable, Sendable {
    let client: PromptClient
    let prompt: String
    let status: HookInstallationStatus
  }

  struct UITestFixtureConfiguration: Equatable, Sendable {
    static let fixtureDate = Date(timeIntervalSince1970: 1_700_000_000)
    static let populatedProfiles = [
      Profile(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        name: "Product Writing",
        prompt: "Use concise, direct language for a product team."
      ),
      Profile(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        name: "Customer Reply",
        prompt: "Be warm, specific, and action oriented."
      ),
    ]
    static let populatedHistory = [
      HistoryEntry(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        original: "this are a test",
        corrected: "this is a test",
        explanation: "Changed subject-verb agreement.",
        provider: .openAI,
        model: LLMProvider.openAI.defaultModel,
        timestamp: fixtureDate,
        profileName: "Product Writing"
      ),
      HistoryEntry(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        original: "please send the report",
        corrected: "Please send the report.",
        explanation: "Corrected capitalization and punctuation.",
        provider: .claude,
        model: LLMProvider.claude.defaultModel,
        timestamp: fixtureDate.addingTimeInterval(-3_600),
        profileName: nil
      ),
    ]
    static let integrationDescriptors = [
      HookIntegrationDescriptor(
        id: "omp-default",
        client: .ohMyPi,
        profile: "default",
        executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/omp"),
        workingDirectory: URL(fileURLWithPath: "/Users/ui/project", isDirectory: true),
        configurationURL: URL(
          fileURLWithPath: "/Users/ui/.omp/agent/prompt-gates/default/bex.json"
        ),
        gateURL: URL(fileURLWithPath: "/Users/ui/.omp/agent/prompt-gates/default/bex.json"),
        helperURL: URL(
          fileURLWithPath:
            "/Users/ui/Library/Application Support/Bex/bin/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bex-hook"
        ),
        capabilityVersion: 1,
        validation: .supported
      ),
      HookIntegrationDescriptor(
        id: "omp-team",
        client: .ohMyPi,
        profile: "team",
        executableURL: URL(fileURLWithPath: "/usr/local/bin/omp"),
        workingDirectory: URL(fileURLWithPath: "/Users/ui/team-project", isDirectory: true),
        configurationURL: URL(
          fileURLWithPath: "/Users/ui/.omp/team/prompt-gates/bex.json"
        ),
        gateURL: URL(fileURLWithPath: "/Users/ui/.omp/team/prompt-gates/bex.json"),
        helperURL: URL(
          fileURLWithPath:
            "/Users/ui/Library/Application Support/Bex/bin/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bex-hook"
        ),
        capabilityVersion: 1,
        validation: .supported
      ),
    ]

    var preservesStoredState = false
    var preferences = UITestPreferenceSeed()
    var profiles: [Profile]?
    var history: [HistoryEntry]?
    var credentialProvider: LLMProvider? = .openAI
    var target = UITestTargetSeed()
    var hook: UITestHookSeed?
    var hotKeyRegistration: UITestHotKeyRegistration = .succeed
    var grammarBehavior: UITestGrammarBehavior = .immediate
    var pasteboardPath: String?
    var integrations: [HookIntegrationDescriptor] = []
    var integrationStatuses: [String: HookInstallationStatus] = [:]
    var integrationTranscriptPath: String?
    var injectDriftIntegrationID: String?
    var partialFailureIntegrationID: String?
    var launchDestination: UITestLaunchDestination = .none

    static func resolve(environment: [String: String]) -> Self {
      var configuration = UITestScenario.parse(environment: environment).configuration
      configuration.target.source =
        environment["BEX_UI_TEST_PROMPT_SOURCE"]
        ?? configuration.target.source
      configuration.target.sinkPath =
        environment["BEX_UI_TEST_PROMPT_TARGET_PATH"]
        ?? configuration.target.sinkPath
      configuration.target.deliveryEventsPath =
        environment["BEX_UI_TEST_PROMPT_DELIVERY_EVENTS_PATH"]
        ?? configuration.target.deliveryEventsPath
      configuration.pasteboardPath =
        environment["BEX_UI_TEST_PASTEBOARD_PATH"]
        ?? configuration.pasteboardPath
      configuration.integrationTranscriptPath =
        environment["BEX_UI_TEST_INTEGRATION_TRANSCRIPT_PATH"]
        ?? configuration.integrationTranscriptPath
      configuration.injectDriftIntegrationID =
        environment["BEX_UI_TEST_INJECT_DRIFT_ID"]
        ?? configuration.injectDriftIntegrationID
      configuration.partialFailureIntegrationID =
        environment["BEX_UI_TEST_PARTIAL_FAILURE_ID"]
        ?? configuration.partialFailureIntegrationID
      if environment["BEX_UI_TEST_PROMPT_DELIVERY_ERROR"] == "1" {
        configuration.target.deliveryFailureEffect = PromptDeliveryEffect.none
      }
      if environment["BEX_UI_TEST_REAL_TARGET"] == "1" {
        configuration.target.usesRealTarget = true
      }
      return configuration
    }

    func seed(preferences store: PreferencesStore, data: BexDataStore) async throws {
      if let provider = preferences.selectedProvider {
        await store.setSelectedProvider(provider)
        if let model = preferences.selectedModel {
          await store.setSelectedModel(model, for: provider)
        }
        if let effort = preferences.selectedEffort {
          await store.setSelectedEffort(effort, for: provider)
        }
      }
      if let choice = preferences.draftRetentionChoice {
        await store.setDraftRetentionChoice(choice)
      }
      if let choice = preferences.historyRetentionChoice {
        await store.setHistoryRetentionChoice(choice)
      }
      if let draft = preferences.quickDraft {
        await store.setQuickDraft(draft)
      }
      if let id = preferences.activeProfileID {
        await store.setActiveProfileID(id)
      }
      if let id = preferences.defaultProfileID {
        await store.setDefaultProfileID(id)
      }
      if let confirms = preferences.confirmsHookOutboundPayloads {
        await store.setConfirmsHookOutboundPayloads(confirms)
      }
      if let provider = preferences.acceptedOutboundDisclosureProvider {
        let endpoint: String?
        if provider == .ollama {
          endpoint = await store.ollamaURL()
        } else {
          endpoint = nil
        }
        let destination = try OutboundDestination(
          provider: provider,
          model: preferences.selectedModel ?? provider.defaultModel,
          ollamaEndpoint: endpoint
        )
        await store.acceptCurrentOutboundDisclosure(for: destination)
      }

      if let profiles {
        for profile in try await data.loadProfiles() {
          try await data.deleteProfile(id: profile.id)
        }
        for profile in profiles {
          try await data.saveProfile(profile)
        }
      }
      if let history {
        try await data.clearHistory()
        for entry in history.reversed() {
          try await data.appendHistory(entry)
        }
      }
    }
  }

  actor UITestingContinuationGate {
    private var isReleased = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      guard !isReleased else { return }
      await withCheckedContinuation { continuation in
        continuations.append(continuation)
      }
    }

    func release() {
      guard !isReleased else { return }
      isReleased = true
      let pending = continuations
      continuations.removeAll(keepingCapacity: false)
      for continuation in pending {
        continuation.resume()
      }
    }
  }

  struct UITestDeliveryEvent: Codable, Equatable, Sendable {
    enum Effect: String, Codable, Sendable {
      case none
      case copied
      case pastedNotSubmitted
      case submitted
      case unknown
    }

    let sequence: Int
    let effect: Effect
  }

  @MainActor
  final class UITestingHotKeyRegistrationBackend: HotKeyRegistrationBackend {
    private let behavior: UITestHotKeyRegistration
    private var nextToken: UInt = 1

    init(behavior: UITestHotKeyRegistration) {
      self.behavior = behavior
    }

    func start(owner: GlobalHotKey) throws {}

    func stop() {}

    func register(_ shortcut: Shortcut) throws -> HotKeyRegistrationToken {
      if behavior == .conflict {
        throw HotKeyRegistrationError.conflict(
          .chordAlreadyRegistered(chord: shortcut.chord, existingID: 9_999)
        )
      }
      defer { nextToken &+= 1 }
      return HotKeyRegistrationToken(rawValue: nextToken)
    }

    func unregister(_ token: HotKeyRegistrationToken) {}
  }

  actor UITestingGrammarService: GrammarServicing, PromptGrammarServicing {
    private let behavior: UITestGrammarBehavior
    private let checkGate = UITestingContinuationGate()
    private var checkRequestCount = 0

    init(behavior: UITestGrammarBehavior) {
      self.behavior = behavior
    }

    func releaseCheck() async {
      await checkGate.release()
    }

    func check(
      text: String,
      destination: OutboundDestination,
      profilePrompt: String?
    ) async throws -> GrammarResult {
      checkRequestCount += 1
      if behavior == .holdFirstCheckThenFailSubsequent {
        if checkRequestCount == 1 {
          await checkGate.wait()
        } else {
          throw BexError.connectionFailure("Forced UI test grammar failure.")
        }
      }
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
      destination: OutboundDestination
    ) async throws -> GrammarResult {
      if text == "this are a test" {
        return GrammarResult(
          corrected: "this is a test",
          explanation: "Changed subject-verb agreement."
        )
      }
      if text == "i has teh file /tmp/a.swift and use --dry-run at https://example.com/a?q=1" {
        return GrammarResult(
          corrected: "I have the file /tmp/a.swift and use --dry-run at https://example.com/a?q=1",
          explanation: "Corrected capitalization, agreement, and spelling."
        )
      }
      return GrammarResult(corrected: text, explanation: "No changes needed.")
    }

    func checkPrompt(
      protectedText: PromptTechnicalSpanProtector.ProtectedText,
      destination: OutboundDestination
    ) async throws -> GrammarResult {
      if behavior == .holdPromptCheck {
        await checkGate.wait()
      }
      var corrected = protectedText.masked
      if corrected == "this are a test" {
        corrected = "this is a test"
      } else if corrected.hasPrefix("i has teh file ") {
        corrected = corrected.replacingOccurrences(
          of: "i has teh file ",
          with: "I have the file ",
          options: [.anchored]
        )
      }
      return GrammarResult(
        corrected: try protectedText.restore(corrected),
        explanation: corrected == protectedText.masked
          ? "No changes needed."
          : "Corrected capitalization, agreement, and spelling."
      )
    }

    func rewrite(
      text: String,
      intent: RewriteIntent,
      destination: OutboundDestination
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

    func define(
      text: String,
      destination: OutboundDestination
    ) async throws -> DictionaryLookup {
      DictionaryLookup(
        english: "postpone",
        korean: "미루다",
        simple: "To move something to a later time.",
        example: "Let's postpone the review until Friday."
      )
    }

    /// UI tests never exercise the background classifier — it makes no network call here,
    /// so every card keeps its `GrammarCategory`-derived fallback pattern.
    func classifyStudyPatterns(
      cards: [StudyCard],
      destination: OutboundDestination
    ) async throws -> [String: StudyPattern.Verdict] {
      [:]
    }

    func generateProfile(
      context: ProfileContext,
      destination: OutboundDestination
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

    init(path: String?) {
      if let path {
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
    private let deliveryEventsURL: URL?
    private let requestedAccessibilityTrust: Bool
    private let deliveryFailureEffect: PromptDeliveryEffect?
    private let deliveryGate: UITestingContinuationGate?
    private let pasteboard: any PasteboardWriting
    var isAccessibilityTrusted: Bool

    init(
      configuration: UITestTargetSeed,
      pasteboard: any PasteboardWriting
    ) {
      source = configuration.source
      requestedAccessibilityTrust = configuration.requestedAccessibilityTrust
      deliveryFailureEffect = configuration.deliveryFailureEffect
      deliveryGate =
        configuration.deliveryGate == .untilReleased
        ? UITestingContinuationGate()
        : nil
      self.pasteboard = pasteboard
      isAccessibilityTrusted = configuration.isAccessibilityTrusted
      sinkURL =
        configuration.sinkPath.map(URL.init(fileURLWithPath:))
        ?? FileManager.default.temporaryDirectory.appendingPathComponent(
          "BexUITestingPromptTarget-\(ProcessInfo.processInfo.processIdentifier).txt"
        )
      deliveryEventsURL = configuration.deliveryEventsPath.map(URL.init(fileURLWithPath:))
      try? FileManager.default.removeItem(at: sinkURL)
      if let deliveryEventsURL {
        try? FileManager.default.removeItem(at: deliveryEventsURL)
      }
    }

    func releaseDelivery() async {
      await deliveryGate?.release()
    }

    func requestAccessibilityTrust() -> Bool {
      isAccessibilityTrusted = requestedAccessibilityTrust
      return requestedAccessibilityTrust
    }

    func captureFrontmostTarget() throws -> PromptCapture {
      let kind: PromptTargetKind
      if !isAccessibilityTrusted {
        kind = .copyOnly
      } else if source.isEmpty {
        kind = .composerPaste
      } else {
        kind = .capturedField
      }
      let target = PromptTarget(
        kind: kind,
        processID: kind == .copyOnly ? nil : 42,
        bundleID: "com.bex.ui-test-target",
        applicationName: "UI Test Target",
        guidance: kind == .copyOnly
          ? "Accessibility is required for manual capture and replacement. Bex will copy the approved correction."
          : source.isEmpty
            ? "Bex will paste the correction. Press Return in the target to submit."
            : "Bex will replace this exact field after approval."
      )
      return PromptCapture(
        draft: kind == .copyOnly ? "" : source,
        target: target,
        source: kind == .capturedField ? .capturedField : .composer
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
      await deliveryGate?.wait()
      if let effect = deliveryFailureEffect {
        if effect == .copied {
          try pasteboard.write(correctedText)
        } else if effect == .pastedNotSubmitted || effect == .submitted {
          try correctedText.write(to: sinkURL, atomically: true, encoding: .utf8)
        }
        try recordDelivery(effect: effect)
        throw PromptDeliveryFailure(
          effect: effect,
          underlyingError: BexError.promptDeliveryFailed("Forced UI test delivery failure.")
        )
      }

      let outcome: PromptDeliveryOutcome
      if target.kind == .copyOnly {
        try pasteboard.write(correctedText)
        outcome = .copied
      } else {
        try correctedText.write(to: sinkURL, atomically: true, encoding: .utf8)
        outcome = pressReturn ? .submitted : .pasted
      }
      try recordDelivery(effect: outcome.effect)
      return outcome
    }

    func discard(_ target: PromptTarget) {}

    private func recordDelivery(effect: PromptDeliveryEffect) throws {
      guard let deliveryEventsURL else { return }
      let existing: [UITestDeliveryEvent]
      if let data = try? Data(contentsOf: deliveryEventsURL) {
        existing = try JSONDecoder().decode([UITestDeliveryEvent].self, from: data)
      } else {
        existing = []
      }
      let eventEffect: UITestDeliveryEvent.Effect =
        switch effect {
        case .none: .none
        case .copied: .copied
        case .pastedNotSubmitted: .pastedNotSubmitted
        case .submitted: .submitted
        case .unknown: .unknown
        }
      let event = UITestDeliveryEvent(
        sequence: existing.count + 1,
        effect: eventEffect
      )
      let data = try JSONEncoder().encode(existing + [event])
      try data.write(to: deliveryEventsURL, options: .atomic)
    }
  }

  actor UITestingHookManager: HookInstallationManaging {
    private var clientStatuses: [PromptClient: HookInstallationStatus]
    private var integrationStatuses: [String: HookInstallationStatus]
    private var descriptors: [HookIntegrationDescriptor]
    private var prepared: [UUID: HookInstallationReview] = [:]
    private let transcriptURL: URL?
    private var driftIntegrationID: String?
    private var partialFailureIntegrationID: String?

    init(configuration: UITestFixtureConfiguration) {
      clientStatuses = configuration.hook.map { [$0.client: $0.status] } ?? [:]
      integrationStatuses = configuration.integrationStatuses
      descriptors = configuration.integrations
      transcriptURL = configuration.integrationTranscriptPath.map(URL.init(fileURLWithPath:))
      driftIntegrationID = configuration.injectDriftIntegrationID
      partialFailureIntegrationID = configuration.partialFailureIntegrationID
    }

    func status(for client: PromptClient) async -> HookInstallationStatus {
      integrationStatuses[client.rawValue] ?? clientStatuses[client] ?? .notInstalled
    }

    func status(for integrationID: String) async -> HookInstallationStatus {
      integrationStatuses[integrationID] ?? .notInstalled
    }

    func install(_ client: PromptClient) async throws {
      clientStatuses[client] = .installedUnconfirmed
      record("legacy-install:\(client.rawValue)")
    }

    func uninstall(_ client: PromptClient) async throws {
      clientStatuses[client] = .notInstalled
      integrationStatuses[client.rawValue] = .notInstalled
      record("legacy-uninstall:\(client.rawValue)")
    }

    func installedDescriptors() async -> [HookIntegrationDescriptor] {
      descriptors
    }

    func resolve(_ target: HookIntegrationTarget) async throws -> HookIntegrationDescriptor {
      let descriptor: HookIntegrationDescriptor
      switch target {
      case .claudeCode:
        descriptor = fixedDescriptor(for: .claudeCode)
      case .codex:
        descriptor = fixedDescriptor(for: .codex)
      case .ohMyPi(let executable, let profile, let workingDirectory):
        let normalizedProfile = profile?.isEmpty == false ? profile! : "default"
        descriptor =
          descriptors.first(where: {
            $0.client == .ohMyPi && $0.profile == normalizedProfile
          })
          ?? HookIntegrationDescriptor(
            id: "omp-\(normalizedProfile)",
            client: .ohMyPi,
            profile: normalizedProfile,
            executableURL: executable,
            workingDirectory: workingDirectory,
            configurationURL: URL(
              fileURLWithPath:
                "/Users/ui/.omp/\(normalizedProfile)/prompt-gates/bex.json"
            ),
            gateURL: URL(
              fileURLWithPath:
                "/Users/ui/.omp/\(normalizedProfile)/prompt-gates/bex.json"
            ),
            helperURL: URL(
              fileURLWithPath:
                "/Users/ui/Library/Application Support/Bex/bin/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/bex-hook"
            ),
            capabilityVersion: 1,
            validation: .supported
          )
      }
      record("resolve:\(descriptor.id)")
      return descriptor
    }

    func prepare(
      _ operation: HookInstallationOperation,
      for descriptor: HookIntegrationDescriptor
    ) async throws -> HookInstallationReview {
      let reviewID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
      let before = HookArtifactSnapshot(
        exists: operation != .install,
        mode: operation == .install ? nil : 0o600,
        sha256: operation == .install ? nil : String(repeating: "1", count: 64)
      )
      let after = HookArtifactSnapshot(
        exists: operation != .uninstall,
        mode: operation == .uninstall ? nil : 0o600,
        sha256: operation == .uninstall ? nil : String(repeating: "2", count: 64)
      )
      let action = HookInstallationAction(
        id: "\(reviewID.uuidString)-config",
        path: descriptor.configurationURL.path,
        kind: .file,
        change: operation == .install ? .create : operation == .uninstall ? .delete : .replace,
        before: before,
        after: after
      )
      let review = HookInstallationReview(
        id: reviewID,
        operation: operation,
        descriptor: descriptor,
        trustGuidance:
          descriptor.client == .codex
          ? "After Apply, approve Bex in Codex /hooks."
          : "Review the exact Bex-owned target before Apply.",
        limitations: "This deterministic fixture never mutates the real filesystem.",
        signer: "bex-hook · ESURPGU29C",
        currentText: operation == .install ? nil : "{\n  \"enabled\" : false\n}\n",
        proposedText: operation == .uninstall ? nil : "{\n  \"enabled\" : true\n}\n",
        actions: [action]
      )
      prepared[reviewID] = review
      record("prepare:\(operation.rawValue):\(descriptor.id):\(reviewID.uuidString)")
      return review
    }

    func apply(reviewID: UUID) async throws -> HookInstallationResult {
      guard let review = prepared.removeValue(forKey: reviewID) else {
        throw BexError.storageFailure("This integration review is stale or was already applied.")
      }
      if driftIntegrationID == review.descriptor.id {
        driftIntegrationID = nil
        record("drift:\(review.descriptor.id)")
        throw BexError.storageFailure(
          "Nothing changed because \(review.descriptor.configurationURL.path) changed after review."
        )
      }
      if partialFailureIntegrationID == review.descriptor.id {
        partialFailureIntegrationID = nil
        let completed = review.actions.map(\.path)
        let retained = review.descriptor.helperURL.path
        record("partial-failure:\(review.descriptor.id)")
        return HookInstallationResult(
          completed: completed,
          restored: [review.descriptor.configurationURL.path],
          failed: [retained]
        )
      }
      switch review.operation {
      case .uninstall:
        descriptors.removeAll { $0.id == review.descriptor.id }
        integrationStatuses[review.descriptor.id] = .notInstalled
      case .install, .update, .repair:
        if !descriptors.contains(where: { $0.id == review.descriptor.id }) {
          descriptors.append(review.descriptor)
        }
        integrationStatuses[review.descriptor.id] =
          review.descriptor.client == .codex ? .awaitingCodexTrust : .installedUnconfirmed
      }
      record("apply:\(review.operation.rawValue):\(review.descriptor.id):\(reviewID.uuidString)")
      return HookInstallationResult(
        completed: review.actions.map(\.path),
        restored: [],
        failed: []
      )
    }

    func cancel(reviewID: UUID) async {
      let review = prepared.removeValue(forKey: reviewID)
      record("cancel:\(review?.descriptor.id ?? "unknown"):\(reviewID.uuidString)")
    }

    private func fixedDescriptor(for client: PromptClient) -> HookIntegrationDescriptor {
      let config =
        client == .claudeCode
        ? "/Users/ui/.claude/settings.json"
        : "/Users/ui/.codex/hooks.json"
      return HookIntegrationDescriptor(
        id: client.rawValue,
        client: client,
        profile: "default",
        executableURL: nil,
        workingDirectory: nil,
        configurationURL: URL(fileURLWithPath: config),
        gateURL: nil,
        helperURL: URL(
          fileURLWithPath:
            "/Users/ui/Library/Application Support/Bex/bin/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bex-hook"
        ),
        capabilityVersion: nil,
        validation: .supported
      )
    }

    private func record(_ value: String) {
      guard let transcriptURL else { return }
      let existing =
        (try? Data(contentsOf: transcriptURL))
        .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
      try? FileManager.default.createDirectory(
        at: transcriptURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? JSONEncoder().encode(existing + [value]).write(to: transcriptURL, options: .atomic)
    }
  }

  actor UITestingPromptGateIPC: PromptGateIPCServicing, HookReviewResponding {
    private let hook: UITestHookSeed?
    private var onRequest: (@Sendable (HookReviewRequest) async -> Bool)?

    init(hook: UITestHookSeed?) {
      self.hook = hook
    }

    func setHandlers(
      onRequest: @escaping @Sendable (HookReviewRequest) async -> Bool,
      onInvalidation: @escaping @Sendable (UUID) async -> Void
    ) async {
      self.onRequest = onRequest
    }

    func start() async throws {
      guard let hook, let onRequest else { return }
      _ = await onRequest(
        HookReviewRequest(
          requestID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
          client: hook.client,
          prompt: hook.prompt,
          sessionID: "bex-ui-test-session",
          cwd: "/tmp/bex-ui-test",
          helperPID: 42
        )
      )
    }

    func stop() async {}

    func complete(
      requestID: UUID,
      outcome: HookReviewOutcome,
      awaitAcknowledgement: Bool,
      approvedPrompt: String?,
      integrationID: String?
    ) async throws {}
  }

  @MainActor
  extension AppServices {
    static func uiTesting(seedCredential: Bool) async -> AppServices {
      let environment = ProcessInfo.processInfo.environment
      let scenario = UITestScenario.parse(environment: environment)
      let configuration = UITestFixtureConfiguration.resolve(environment: environment)
      let suite =
        configuration.preservesStoredState
        ? "com.bex.desktop.ui-testing.\(scenario.rawValue)"
        : "com.bex.desktop.ui-testing"
      let defaults = UserDefaults(suiteName: suite)!
      if !configuration.preservesStoredState {
        defaults.removePersistentDomain(forName: suite)
      }
      let preferences = PreferencesStore(defaults: defaults)

      let directoryName =
        configuration.preservesStoredState
        ? "BexUITesting-\(scenario.rawValue)"
        : "BexUITesting-\(ProcessInfo.processInfo.processIdentifier)"
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(directoryName)
      if !configuration.preservesStoredState {
        try? FileManager.default.removeItem(at: directory)
      }
      let data = BexDataStore(fileURL: directory.appendingPathComponent("data.json"))
      try? await configuration.seed(preferences: preferences, data: data)
      let learningLogDirectory = directory.appendingPathComponent("LearningLog", isDirectory: true)
      let learningLog = LearningLogStore(directoryURL: learningLogDirectory)
      let studyState = StudyStateStore(directoryURL: learningLogDirectory)
      let considerTaps = ConsiderTapStore(directoryURL: learningLogDirectory)
      let studyPatterns = StudyPatternStore(directoryURL: learningLogDirectory)

      let keychain = KeychainStore(
        service: "com.bex.desktop.credentials.ui-testing",
        inMemory: true
      )
      if seedCredential, let provider = configuration.credentialProvider {
        try? await keychain.saveAPIKey("ui-testing-key", for: provider)
      }

      let transport = URLSessionTransport()
      let grammar = UITestingGrammarService(behavior: configuration.grammarBehavior)
      let pasteboard = UITestingPasteboard(path: configuration.pasteboardPath)
      let promptTarget: any PromptTargetServicing =
        configuration.target.usesRealTarget
        ? PromptTargetService()
        : UITestingPromptTargetService(
          configuration: configuration.target,
          pasteboard: pasteboard
        )
      let hookManager = UITestingHookManager(configuration: configuration)
      let promptGateIPC = UITestingPromptGateIPC(hook: configuration.hook)
      return AppServices(
        preferences: preferences,
        keychain: keychain,
        data: data,
        learningLog: learningLog,
        studyState: studyState,
        considerTaps: considerTaps,
        studyPatterns: studyPatterns,
        grammar: grammar,
        promptGrammar: grammar,
        pasteboard: pasteboard,
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
