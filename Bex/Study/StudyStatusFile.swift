import Foundation

/// Publishes the current Study due count to a small JSON file so external status bars
/// can render it without reimplementing any of Bex's logic.
///
/// This exists because the owner's menu bar is SketchyBar, which stands in for the native
/// one — so the `NSStatusItem` badge Bex draws lives in a bar that is usually hidden, and
/// a count nobody sees applies no pressure. A SketchyBar plugin is a shell script, and
/// the alternative to this file would be re-deriving "how many cards are due" in bash:
/// re-parsing the learning log, re-applying the case-only/no-op card filters, and
/// re-implementing the Leitner due check. That duplicate would drift from
/// `StudyCardBuilder`/`StudyScheduler` the moment either changed. Publishing the number
/// Bex already computed keeps exactly one implementation of the rules.
///
/// Written on every badge refresh (each correction, each answer, hourly), including when
/// the count is zero — the reader needs "nothing due" stated, not inferred from a missing
/// file.
enum StudyStatusFile {
  /// The card the bar should currently be offering, so a SketchyBar popup can render
  /// its two choices as clickable rows without ever talking to `StudyCardBuilder` or
  /// `StudyDailyPlan` itself. `choices` is passed through verbatim (same order as
  /// `StudyCard.choices`) because that order is exactly what `bex://answer?index=N`'s
  /// index refers to — see `AppDelegate`'s answer handler.
  /// Deliberately excludes the card's `reason` (unlike `LastResult` below): this is
  /// shown BEFORE the owner answers, and the reason explains why the correct choice is
  /// correct — publishing it here would hand him the answer alongside the question.
  struct NextCard: Codable, Equatable, Sendable {
    let id: String
    let prompt: String
    let choices: [String]
  }

  /// The outcome of the most recently answered card, so the bar can flash "Correct" /
  /// "Wrong, it was X" right after a click, even though that click already caused a
  /// new `nextCard` to be published. Absent until the first answer of the app's
  /// lifetime; present and unchanging thereafter until the next answer replaces it.
  struct LastResult: Codable, Equatable, Sendable {
    let wasCorrect: Bool
    let correctAnswer: String
    /// The answered card's `StudyCard.reason` — the "Fixed:" line's explanation of WHY
    /// the correction is right, e.g. "this is the correct preposition for this
    /// meaning", so the bar can show more than a bare verdict. `""` when the source log
    /// line carried no reason. Field name is new, unlike `wasCorrect`/`correctAnswer`
    /// (kept exactly as-is — a shell plugin and tests parse those names), so an older
    /// plugin that ignores unknown JSON keys keeps working unchanged.
    let reason: String
  }

  struct Status: Codable, Equatable, Sendable {
    let dueCount: Int
    /// ISO-8601 write time, so a reader can tell a genuine zero from a count left behind
    /// by a Bex that hasn't run in days.
    let updatedAt: String
    /// `StudyDueCount.StudySeverity`'s raw value, so a SketchyBar plugin can color the
    /// indicator (e.g. yellow/red) once genuinely behind, without reimplementing the
    /// overdue-days math itself — see `StudyDueCount.severity` for why that escalation
    /// is reserved for `behind`/`late` rather than firing on any non-zero count.
    let severity: String
    /// The card the bar should show next, or `nil` when nothing is due. `Optional`
    /// fields are omitted from the JSON entirely when `nil` (Swift's synthesized
    /// `Codable` uses `encodeIfPresent`/`decodeIfPresent` for `Optional`-typed stored
    /// properties automatically) so the plugin can distinguish "no card" from a
    /// malformed one rather than parsing an explicit `null`.
    let nextCard: NextCard?
    /// The result of the last `bex://answer` click, or `nil` before any answer has
    /// been recorded this run. See `nextCard` above for why absence (not `null`)
    /// is how "nothing to show" is represented.
    let lastResult: LastResult?
  }

  static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Bex/study-status.json")

  /// Encodes `status` to `url`. Pure except for the write itself, and `updatedAt` is
  /// supplied by the caller rather than read from the clock here, so the encoding is
  /// unit-testable on fixed input.
  static func encode(_ status: Status) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(status)
  }

  /// Best-effort publish, matching `LearningLogStore.append`'s posture: a status file
  /// that fails to write must never disturb the app. Owner-only (0o600) like the rest of
  /// Bex's on-disk learning data; the reader runs as the same user.
  static func write(
    dueCount: Int,
    severity: StudyDueCount.StudySeverity,
    nextCard: NextCard?,
    lastResult: LastResult?,
    now: Date,
    to url: URL = defaultURL
  ) {
    let status = Status(
      dueCount: dueCount,
      updatedAt: ISO8601DateFormatter().string(from: now),
      severity: severity.rawValue,
      nextCard: nextCard,
      lastResult: lastResult
    )
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try encode(status).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      // Fire-and-forget: intentionally ignored, see doc comment above.
    }
  }
}
