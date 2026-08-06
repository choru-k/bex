import Foundation

enum PromptClient: String, Codable, CaseIterable, Identifiable, Sendable {
  case claudeCode = "claude"
  case codex
  case ohMyPi = "omp"

  var id: String { rawValue }
}

enum HookProtocolConstants {
  static let version = 1
  static let maximumMessageBytes = 1_048_576
  static let reviewPath = "/v1/review"
  static let acknowledgmentPath = "/v1/ack"
  static let rendezvousFileName = "rendezvous.json"
  static let helperName = "bex-hook"
  static let promptGateCapability = "prompt-gate-v1"
}

/// Recognizes a prompt written in Korean, which Bex has nothing useful to say about.
///
/// Two shapes have to be told apart, and counting characters cannot do it — measured on
/// 422 real prompts, every ratio metric overlaps:
///
///   - `rebase 하고 나서 deploy 해줘` is Korean. The English words are English words, not
///     the user's English. Only 33% of its letters are Hangul.
///   - `Fix the 권한 문제.` is English with a Korean noun the user did not know. 40% of its
///     letters are Hangul — *more* than the Korean sentence above.
///
/// What actually separates them is which language frames the sentence: Korean marks its
/// frame with particles (`prod 랑`, `au 는?`) and verb-final endings (`…해줘`, `…않아?`),
/// and an English sentence borrowing a Korean noun has neither.
///
/// ponytail: a hand-listed set of endings and particles, not a language model or
/// `NLLanguageRecognizer` — it scores 54/55 on the real corpus, and the one miss
/// (`변경 폐기 후 pull`, a verbless noun phrase) merely gets reviewed as if it were
/// English. Widen the lists if real misses show up.
enum KoreanPrompt {
  /// Korean verb-final endings, taken from what the real corpus ends sentences with.
  private static let endings = [
    "줘", "줄래", "래", "해", "봐", "돼", "되", "야", "어", "아", "지", "네", "죠",
    "까", "잖아", "구나", "군요", "세요", "어요", "아요", "예요", "합니다", "습니다",
    "니다", "겠네", "겠어", "겠지", "더라", "자", "해서", "부터", "까지", "하고", "이고",
  ]

  /// Particles. These attach to any word, including English ones, and are the only
  /// Korean signal in a prompt with no verb at all ("prod eu, uw1, au 는?").
  private static let particles = [
    "은", "는", "이", "가", "을", "를", "에", "에서", "으로", "로", "와", "과",
    "랑", "이랑", "도", "만", "부터", "까지", "보다", "처럼", "의", "께", "한테",
  ]

  /// A run of this many consecutive plain English words means the user wrote English
  /// here, whatever else surrounds it, so the prompt must still be reviewed. Without
  /// this, a Korean instruction followed by an English draft — "slack draft 을 작성해줘.
  /// ---- i have talked with jachan…" — would be skipped in full.
  private static let englishRunLimit = 5

  static func isMainlyKorean(_ text: String) -> Bool {
    guard text.unicodeScalars.contains(where: isHangul) else { return false }
    if longestEnglishRun(in: text) >= englishRunLimit { return false }
    return hasKoreanGrammar(text) || hangulShare(text) >= 0.8
  }

  private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
    (0xAC00...0xD7A3).contains(scalar.value)  // syllables
      || (0x1100...0x11FF).contains(scalar.value)  // jamo
      || (0x3130...0x318F).contains(scalar.value)  // compatibility jamo
  }

  private static func tokens(_ text: String) -> [String] {
    text.split(whereSeparator: \.isWhitespace).map {
      $0.trimmingCharacters(in: CharacterSet(charactersIn: "?!.,;:()[]{}\"'…~>=/-"))
    }
  }

  private static func hasKoreanGrammar(_ text: String) -> Bool {
    for token in tokens(text) {
      guard token.unicodeScalars.contains(where: isHangul) else { continue }
      if endings.contains(where: token.hasSuffix) { return true }
      let tail = String(token.unicodeScalars.filter(isHangul).map(Character.init))
      if particles.contains(tail) { return true }
      if tail.count <= 3, particles.contains(where: tail.hasSuffix) { return true }
    }
    return false
  }

  /// Longest run of consecutive plain English words. A Hangul token breaks the run;
  /// numbers, URLs and identifiers neither extend nor break it.
  private static func longestEnglishRun(in text: String) -> Int {
    var best = 0
    var run = 0
    for token in tokens(text) {
      if token.count > 1, token.allSatisfy({ $0.isASCII && $0.isLetter }) {
        run += 1
        best = max(best, run)
      } else if token.unicodeScalars.contains(where: isHangul) {
        run = 0
      }
    }
    return best
  }

  /// Hangul weighted 2.5x (one syllable carries about that many Latin letters' worth),
  /// averaged with the share of whole tokens that are Korean. Only decides prompts with
  /// no grammatical marker at all, e.g. a bare noun list.
  private static func hangulShare(_ text: String) -> Double {
    var hangul = 0
    var latin = 0
    for scalar in text.unicodeScalars {
      if isHangul(scalar) {
        hangul += 1
      } else if ("a"..."z").contains(String(scalar)) || ("A"..."Z").contains(String(scalar)) {
        latin += 1
      }
    }
    guard hangul + latin > 0 else { return 0 }
    let weighted = Double(hangul) * 2.5 / (Double(hangul) * 2.5 + Double(latin))

    var koreanTokens = 0
    var englishTokens = 0
    for token in tokens(text) {
      if token.unicodeScalars.contains(where: isHangul) {
        koreanTokens += 1
      } else if token.contains(where: { $0.isASCII && $0.isLetter }) {
        englishTokens += 1
      }
    }
    let total = koreanTokens + englishTokens
    let byToken = total > 0 ? Double(koreanTokens) / Double(total) : 0
    return (weighted + byToken) / 2
  }
}

/// Recognizes an acknowledgement — `yes`, `ok`, `go ahead` — which there is nothing to
/// correct in and nothing to learn from. Like `KoreanPrompt`, these pass straight through
/// instead of costing a round trip and a gate window.
///
/// A closed list, not a length rule. Short prompts are where some of the owner's best
/// study material comes from: `check status` → `check the status` and `make commit` → `make
/// a commit` are two words each. Anything that trims the deck by size would throw those
/// away, so this only skips words whose whole purpose is to say "continue".
enum TrivialPrompt {
  /// Matched after lowercasing and stripping surrounding punctuation, so `Yes.`, `ok!`,
  /// and `y` all land here.
  private static let acknowledgements: Set<String> = [
    "y", "n", "yes", "yeah", "yep", "yup", "no", "nope", "ok", "okay", "k", "sure",
    "go", "go ahead", "goahead", "next", "continue", "proceed", "do it", "done",
    "stop", "wait", "thanks", "thank you", "thx", "ty", "please", "good", "nice",
    "great", "perfect", "cool", "right", "correct", "agree", "agreed",
  ]

  static func isTrivial(_ text: String) -> Bool {
    let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;:\"'“”‘’-–— \t\n"))
    guard !stripped.isEmpty else { return true }
    let collapsed = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return acknowledgements.contains(collapsed)
  }
}

struct HookInput: Decodable, Sendable {
  let hookEventName: String
  let prompt: String
  let sessionID: String
  let cwd: String
  let promptID: String?
  let integrationID: String?
  let turnID: String?
  let transcriptPath: String?

  private enum CodingKeys: String, CodingKey {
    case hookEventName = "hook_event_name"
    case prompt
    case sessionID = "session_id"
    case cwd
    case promptID = "prompt_id"
    case turnID = "turn_id"
    case integrationID = "integration_id"
    case transcriptPath = "transcript_path"
  }
}

enum ClaudePromptSource {
  /// Determines whether the current `UserPromptSubmit` prompt is machine-generated rather than
  /// something the user actually typed — a slash-command wrapper (`<command-name>`,
  /// `<local-command-stdout>`, `<local-command-caveat>`), a background task-notification, a
  /// sub-agent ("sidechain") prompt, or other injected/meta content. Only genuine typed prompts
  /// should reach the gate.
  ///
  /// This gates on a positive human signal rather than a denylist of machine markers: in real
  /// Claude Code transcripts, user-typed entries carry `origin.kind == "human"` (with
  /// `promptSource` "typed"/"suggestion_accepted"), while every injected/command/meta/sidechain
  /// entry lacks it. Keying on the absence of that human signal is what lets us skip command
  /// wrappers that carry no distinguishing machine marker at all.
  ///
  /// Per the README, Bex's Claude Code integration is a review aid that may fail open: it errs
  /// toward gating (`false`, "review it") whenever it cannot confidently match this prompt to a
  /// transcript entry, so a read failure or identity mismatch never silently skips a real prompt.
  static func isNonInteractivePrompt(_ input: HookInput) -> Bool {
    // Fast path — classify by prompt text, no transcript needed. Some machine-injected prompts
    // (task-notifications especially) fire the hook but are NOT recorded as a matchable
    // transcript entry in current Claude Code, so the transcript lookup below can never classify
    // them and would fall through to gating. They always arrive with a recognizable wrapper
    // prefix, so recognize them directly. A genuine typed prompt never starts with these tags.
    let trimmed = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let injectedPrefixes = [
      "<task-notification>",
      "<command-name>",
      "<command-message>",
      "<local-command-stdout>",
      "<local-command-caveat>",
      "<system-reminder>",
    ]
    if injectedPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
      return true
    }

    guard let transcriptPath = input.transcriptPath,
      !transcriptPath.isEmpty,
      let transcriptTail = try? readTranscriptTail(at: URL(fileURLWithPath: transcriptPath))
    else {
      return false
    }

    for line in transcriptTail.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
      guard let entry = try? JSONDecoder().decode(ClaudeTranscriptEntry.self, from: Data(line))
      else {
        continue
      }
      guard entry.type == "user" else { continue }

      guard entry.sessionID == input.sessionID,
        entry.message?.role == "user",
        entry.message?.content == input.prompt
      else {
        return false
      }
      if let promptID = input.promptID, entry.promptID != promptID {
        return false
      }
      // Sub-agent prompts live on a sidechain and are never the interactive user.
      if entry.isSidechain == true {
        return true
      }
      // Gate only genuine human-typed prompts; skip everything else Claude Code records as a
      // "user" entry (command wrappers, command output, task-notifications, meta injections).
      let isHumanTyped =
        entry.origin?.kind == "human"
        || entry.promptSource == "typed"
        || entry.promptSource == "suggestion_accepted"
      return !isHumanTyped
    }

    return false
  }

  private static func readTranscriptTail(at url: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let endOffset = try handle.seekToEnd()
    let maximumTailBytes = UInt64(HookProtocolConstants.maximumMessageBytes + 65_536)
    try handle.seek(toOffset: endOffset > maximumTailBytes ? endOffset - maximumTailBytes : 0)
    return try handle.readToEnd() ?? Data()
  }
}

private struct ClaudeTranscriptEntry: Decodable {
  let type: String?
  let sessionID: String?
  let promptID: String?
  let promptSource: String?
  let origin: Origin?
  let message: Message?
  let isSidechain: Bool?

  private enum CodingKeys: String, CodingKey {
    case type
    case sessionID = "sessionId"
    case promptID = "promptId"
    case promptSource
    case origin
    case message
    case isSidechain
  }

  struct Origin: Decodable {
    let kind: String?
  }

  struct Message: Decodable {
    let role: String?
    let content: String?

    private enum CodingKeys: String, CodingKey {
      case role
      case content
    }

    private struct Block: Decodable {
      let type: String?
      let text: String?
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      role = try? container.decode(String.self, forKey: .role)
      // Claude Code stores message content either as a plain string or as an array of blocks;
      // reconstruct the text of the text blocks so identity matching works in both shapes.
      if let string = try? container.decode(String.self, forKey: .content) {
        content = string
      } else if let blocks = try? container.decode([Block].self, forKey: .content) {
        let text = blocks.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        content = text.isEmpty ? nil : text
      } else {
        content = nil
      }
    }
  }
}
struct OMPPromptGateInput: Decodable, Sendable {
  let version: Int
  let event: String
  let integrationID: String
  let text: String
  let images: [OMPImageMetadata]
  let sessionID: String
  let cwd: String
  let profile: String
  let source: String

  struct OMPImageMetadata: Decodable, Sendable {}

  private enum CodingKeys: String, CodingKey {
    case version
    case event
    case integrationID = "integration_id"
    case text
    case images
    case sessionID = "session_id"
    case cwd
    case profile
    case source
  }
}

enum OMPPromptGateFrame {
  static func allow(integrationID: String) throws -> Data {
    try encoded([
      "decision": "allow",
      "event": HookProtocolConstants.promptGateCapability,
      "integration_id": integrationID,
      "version": HookProtocolConstants.version,
    ])
  }

  static func block(integrationID: String, reason: String) throws -> Data {
    try encoded([
      "decision": "block",
      "event": HookProtocolConstants.promptGateCapability,
      "integration_id": integrationID,
      "reason": reason,
      "version": HookProtocolConstants.version,
    ])
  }

  static func stageApproved(
    integrationID: String,
    text: String,
    deliveryToken: String
  ) throws -> Data {
    try encoded([
      "delivery_token": deliveryToken,
      "event": "stage_approved",
      "integration_id": integrationID,
      "text": text,
      "version": HookProtocolConstants.version,
    ])
  }

  private static func encoded(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
  }
}

struct HookReviewRequest: Codable, Equatable, Sendable {
  let requestID: UUID
  let client: PromptClient
  let integrationID: String?
  let prompt: String
  let sessionID: String
  let cwd: String
  let helperPID: Int32
  let promptID: String?
  let turnID: String?
  let sourcePID: Int32?
  let sourceBundleID: String?

  init(
    requestID: UUID = UUID(),
    client: PromptClient,
    integrationID: String? = nil,
    prompt: String,
    sessionID: String,
    cwd: String,
    helperPID: Int32,
    promptID: String? = nil,
    turnID: String? = nil,
    sourcePID: Int32? = nil,
    sourceBundleID: String? = nil
  ) {
    self.requestID = requestID
    self.client = client
    self.integrationID = integrationID
    self.prompt = prompt
    self.sessionID = sessionID
    self.cwd = cwd
    self.helperPID = helperPID
    self.promptID = promptID
    self.turnID = turnID
    self.sourcePID = sourcePID
    self.sourceBundleID = sourceBundleID
  }
}

enum HookReviewOutcome: String, Codable, Sendable {
  case approved
  case bypassed
  case cancelled
  case failed
}

struct HookRendezvous: Codable, Sendable {
  let version: Int
  let port: UInt16
  let authenticationToken: String
  let serverPID: Int32
  let createdAt: Date
}

struct HookReviewEnvelope: Codable, Sendable {
  let version: Int
  let authenticationToken: String
  let request: HookReviewRequest
}

struct HookReviewResponseEnvelope: Codable, Sendable {
  let version: Int
  let outcome: HookReviewOutcome
  let acknowledgmentToken: String?
  let integrationID: String?
  let approvedPrompt: String?
  let deliveryToken: String?

  init(
    version: Int,
    outcome: HookReviewOutcome,
    acknowledgmentToken: String?,
    integrationID: String? = nil,
    approvedPrompt: String? = nil,
    deliveryToken: String? = nil
  ) {
    self.version = version
    self.outcome = outcome
    self.acknowledgmentToken = acknowledgmentToken
    self.integrationID = integrationID
    self.approvedPrompt = approvedPrompt
    self.deliveryToken = deliveryToken
  }
}

struct HookAcknowledgmentEnvelope: Codable, Sendable {
  let version: Int
  let authenticationToken: String
  let requestID: UUID
  let acknowledgmentToken: String
  let integrationID: String?
  let deliveryToken: String?
  let deliveryStatus: String?

  init(
    version: Int,
    authenticationToken: String,
    requestID: UUID,
    acknowledgmentToken: String,
    integrationID: String? = nil,
    deliveryToken: String? = nil,
    deliveryStatus: String? = nil
  ) {
    self.version = version
    self.authenticationToken = authenticationToken
    self.requestID = requestID
    self.acknowledgmentToken = acknowledgmentToken
    self.integrationID = integrationID
    self.deliveryToken = deliveryToken
    self.deliveryStatus = deliveryStatus
  }
}

struct HookBlockOutput: Equatable, Sendable {
  let client: PromptClient
  let reason: String

  init(client: PromptClient, reason: String) {
    self.client = client
    self.reason = reason
  }

  func encoded() throws -> Data {
    let object: [String: Any]
    switch client {
    case .claudeCode:
      object = [
        "decision": "block",
        "reason": reason,
      ]
    case .codex:
      object = [
        "decision": "block",
        "reason": reason,
      ]
    case .ohMyPi:
      object = [
        "decision": "block",
        "reason": reason,
      ]
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
  }
}

struct HookHeartbeat: Codable, Sendable {
  let version: Int
  let client: PromptClient
  let seenAt: Date
  let integrationID: String?

  init(version: Int, client: PromptClient, seenAt: Date, integrationID: String? = nil) {
    self.version = version
    self.client = client
    self.seenAt = seenAt
    self.integrationID = integrationID
  }
}
