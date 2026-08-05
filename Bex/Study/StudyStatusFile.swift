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
  struct Status: Codable, Equatable, Sendable {
    let dueCount: Int
    /// ISO-8601 write time, so a reader can tell a genuine zero from a count left behind
    /// by a Bex that hasn't run in days.
    let updatedAt: String
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
  static func write(dueCount: Int, now: Date, to url: URL = defaultURL) {
    let status = Status(
      dueCount: dueCount,
      updatedAt: ISO8601DateFormatter().string(from: now)
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
