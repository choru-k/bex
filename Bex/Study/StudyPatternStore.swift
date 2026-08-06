import Darwin
import Foundation

extension Notification.Name {
  /// Posted when the background classifier has assigned patterns to new cards, so the
  /// menu-bar badge and status file pick up the regrouped batch without waiting for the
  /// next hourly refresh.
  static let bexStudyPatternsDidChange = Notification.Name(
    "com.bex.desktop.studyPatternsDidChange")
}

/// Persists which `StudyPattern` each card is an example of, keyed by `StudyCard.id`.
///
/// A separate file from `study-state.json` for the same reason that file is separate from
/// the append-only log: this is derived, disposable data. Deleting `study-patterns.json`
/// costs one background classification pass and nothing else — no review progress, no log
/// entries. Keeping it out of the review state also means a card's Leitner box survives
/// being reclassified, and a reclassification never rewrites scheduling.
///
/// Keyed by `StudyCard.id` rather than by the wrong/correct text because that id is
/// already the stable, reproducible key the rest of Study uses (see `StudyCard.id` on why
/// it is a composed string and not a hash) — so a pattern assigned today still matches
/// its card after the app restarts or the log is re-read.
///
/// Same owner-only posture as the rest of `LearningLog` (0o700 directory, 0o600 file):
/// this is inferred from the owner's own mistakes.
actor StudyPatternStore {
  private let directoryURL: URL
  private let fileURL: URL
  private var cached: [String: StudyPattern.Verdict]?

  init(
    directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/LearningLog", isDirectory: true)
  ) {
    self.directoryURL = directoryURL
    self.fileURL = directoryURL.appendingPathComponent("study-patterns.json")
  }

  func verdicts() -> [String: StudyPattern.Verdict] {
    loadIfNeeded()
    return cached ?? [:]
  }

  /// Merges newly classified cards in, overwriting any previous assignment for the same
  /// id. Posts only when something actually changed, so a pass that reclassifies nothing
  /// does not churn the badge.
  func assign(_ assignments: [String: StudyPattern.Verdict]) {
    loadIfNeeded()
    var merged = cached ?? [:]
    for (cardID, pattern) in assignments { merged[cardID] = pattern }
    guard merged != cached else { return }
    persist(merged)
    NotificationCenter.default.post(name: .bexStudyPatternsDidChange, object: nil)
  }

  /// Card ids in `cards` that have never been classified. This is what keeps the
  /// background pass cheap: it only ever sends the cards added since the last run, so a
  /// steady state costs nothing and a fresh install costs one call.
  func unclassifiedIDs(among cards: [StudyCard]) -> [String] {
    loadIfNeeded()
    let known = cached ?? [:]
    return cards.map(\.id).filter { known[$0] == nil }
  }

  func reset() {
    persist([:])
    NotificationCenter.default.post(name: .bexStudyPatternsDidChange, object: nil)
  }

  private func loadIfNeeded() {
    guard cached == nil else { return }
    cached = readFromDisk()
  }

  /// Best-effort, exactly like `StudyStateStore.readFromDisk`: a missing or corrupt file
  /// means "nothing classified yet", which degrades to grouping by `GrammarCategory` tag
  /// rather than failing.
  private func readFromDisk() -> [String: StudyPattern.Verdict] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    return (try? JSONDecoder().decode([String: StudyPattern.Verdict].self, from: data)) ?? [:]
  }

  private func persist(_ patterns: [String: StudyPattern.Verdict]) {
    cached = patterns
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      chmod(directoryURL.path, 0o700)
      try JSONEncoder().encode(patterns).write(to: fileURL, options: .atomic)
      chmod(fileURL.path, 0o600)
    } catch {
      // Fire-and-forget, same as StudyStateStore.persist: classification is a
      // convenience, and a write failure must never block the app.
    }
  }
}
