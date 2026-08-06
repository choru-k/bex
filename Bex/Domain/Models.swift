import Foundation

public struct GrammarResult: Codable, Equatable, Sendable {
  public let corrected: String
  public let explanation: String

  public init(corrected: String, explanation: String) {
    self.corrected = corrected
    self.explanation = explanation
  }
}

public enum LLMProvider: String, Codable, CaseIterable, Sendable {
  case openAI = "openai"
  case openAICodex = "openai-codex"
  case claude
  case gemini
  case ollama

  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .openAICodex: "OpenAI Codex"
    case .claude: "Claude"
    case .gemini: "Gemini"
    case .ollama: "Ollama"
    }
  }

  public var defaultModel: String {
    switch self {
    case .openAI: "gpt-5.6-sol"
    // Measured on Bex's own grammar prompt: terra answers in ~2s spending no reasoning
    // tokens, against ~5s for sol and ~7s for luna, with identical corrections.
    case .openAICodex: "gpt-5.6-terra"
    case .claude: "claude-opus-4-8"
    case .gemini: "gemini-3.5-flash"
    case .ollama: "llama3.3"
    }
  }

  /// Reasoning effort to use when the user has not chosen one.
  ///
  /// ponytail: grammar checking does not need reasoning — on a 25-case eval, terra at
  /// `.low` scored the same as every higher setting while spending zero reasoning tokens.
  /// Only the provider that was actually measured drops to `.low`; lower the others once
  /// someone benchmarks them.
  public var defaultEffort: ReasoningEffort {
    switch self {
    case .openAICodex: .low
    case .openAI, .claude, .gemini, .ollama: .medium
    }
  }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
  case low
  case medium
  case high

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    }
  }

  var claudeThinkingBudgetTokens: Int? {
    switch self {
    case .low: nil
    case .medium: 1_024
    case .high: 4_096
    }
  }

  var geminiThinkingBudget: Int {
    switch self {
    case .low: 1_024
    case .medium: 4_096
    case .high: 8_192
    }
  }

  var enablesOllamaThinking: Bool {
    self != .low
  }
}

public struct ModelOption: Identifiable, Codable, Equatable, Sendable {
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public struct Profile: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var prompt: String

  public init(id: UUID, name: String, prompt: String) {
    self.id = id
    self.name = name
    self.prompt = prompt
  }
}

public struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public let original: String
  public var corrected: String
  public var explanation: String
  public let provider: LLMProvider
  public let model: String
  public let timestamp: Date
  public let profileName: String?

  public init(
    id: UUID,
    original: String,
    corrected: String,
    explanation: String,
    provider: LLMProvider,
    model: String,
    timestamp: Date,
    profileName: String?
  ) {
    self.id = id
    self.original = original
    self.corrected = corrected
    self.explanation = explanation
    self.provider = provider
    self.model = model
    self.timestamp = timestamp
    self.profileName = profileName
  }
}

public enum RewriteIntent: String, CaseIterable, Sendable {
  case formal
  case friendly
  case shorter

  public var label: String {
    switch self {
    case .formal: "More Formal"
    case .friendly: "Friendlier"
    case .shorter: "Shorter"
    }
  }

  public var instruction: String {
    switch self {
    case .formal: "Rewrite to a more formal and professional tone."
    case .friendly: "Rewrite to sound warmer and friendlier."
    case .shorter: "Rewrite to be shorter and more concise."
    }
  }
}

public struct ProfileContext: Equatable, Sendable {
  public var role: String
  public var audience: String
  public var tone: String
  public var formality: String
  public var domain: String
  public var notes: String

  public init(
    role: String = "",
    audience: String = "",
    tone: String = "",
    formality: String = "",
    domain: String = "",
    notes: String = ""
  ) {
    self.role = role
    self.audience = audience
    self.tone = tone
    self.formality = formality
    self.domain = domain
    self.notes = notes
  }

  public var hasContent: Bool {
    [role, audience, tone, formality, domain, notes]
      .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
}

public enum AppearancePreference: String, Codable, CaseIterable, Sendable {
  case system
  case light
  case dark

  public var displayName: String {
    rawValue.capitalized
  }
}

public struct CodexSession: Codable, Equatable, Sendable {
  public let accessToken: String
  public let refreshToken: String
  public let expiresAt: Date
  public let accountID: String

  public init(accessToken: String, refreshToken: String, expiresAt: Date, accountID: String) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
    self.accountID = accountID
  }
}
