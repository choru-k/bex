import Foundation

/// What the last hourly pass did, so the owner can check the claim rather than take it.
struct BackgroundRunSummary: Equatable, Sendable {
  let finishedAt: Date
  /// Corrections read out of the local learning log.
  let correctionsRead: Int
  /// Cards the pass labelled with the English rule they exemplify.
  let cardsGrouped: Int
}

/// One thing the background agent may read.
///
/// Sources are listed even when Bex cannot use them yet. Showing "Bex could read this, and
/// does not" is the honest version of a privacy surface; a list that quietly omits the
/// sources under consideration tells the owner less than a disabled row does.
enum BackgroundSource: String, CaseIterable, Identifiable, Sendable {
  case bexHistory
  case claudeCodeSessions
  case codexSessions

  var id: String { rawValue }

  var title: String {
    switch self {
    case .bexHistory: return "Bex History"
    case .claudeCodeSessions: return "Claude Code sessions"
    case .codexSessions: return "Codex sessions"
    }
  }

  var detail: String {
    switch self {
    case .bexHistory:
      return "~/Library/Application Support/Bex — already local · no new consent needed"
    case .claudeCodeSessions:
      return "~/.claude/projects — your prompts only, never replies"
    case .codexSessions:
      return "~/.codex/sessions — your prompts only, never replies"
    }
  }

  /// Whether Bex actually reads this source today.
  ///
  /// The two session sources are `false` on purpose, and the reason is non-negotiable 8:
  /// capturing them is a new corpus, and the rule is to measure that the signal exists in
  /// real data before designing for it. `docs/purpose.md` records the same rule killing two
  /// features after measurement, and the one corpus gate Bex *has* run (2026-08-05) was run
  /// on the learning log, not on these. Until that measurement happens these stay off and
  /// inert rather than shipping as a switch that quietly widens what leaves the Mac.
  var isAvailable: Bool {
    self == .bexHistory
  }

  var unavailableReason: String? {
    guard !isAvailable else { return nil }
    return "Not read yet — capturing a new corpus needs the signal measured in real data first."
  }
}
