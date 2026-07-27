import Darwin
import Foundation

extension Notification.Name {
  static let bexLearningLogDidChange = Notification.Name("com.bex.desktop.learningLogDidChange")
}

/// Append-only local log of successful Prompt Gate corrections (Claude Code / Codex
/// terminal prompts). Kept separate from history/data.json per the learning-mode plan
/// (docs/learning-mode-plan.md, v6.1): this is prompt text on disk, so it stays
/// owner-only and out of the history schema entirely.
actor LearningLogStore {
  struct Entry: Codable, Equatable, Sendable {
    let timestamp: String
    let client: String
    let original: String
    let corrected: String
    let explanation: String
    let provider: String
    let model: String
  }

  private let directoryURL: URL
  private let fileURL: URL
  private let now: @Sendable () -> Date

  init(
    directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/LearningLog", isDirectory: true),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL
    self.fileURL = directoryURL.appendingPathComponent("learning-log.jsonl")
    self.now = now
  }

  /// Records one correction as a JSON line. Fire-and-forget: any failure is swallowed
  /// so a logging problem can never block or fail the correction flow that called it.
  ///
  // ponytail: append-only, no rotation or size cap. Fine for one person's terminal
  // prompts; revisit with a rotation/trim policy if the file ever grows enough to matter.
  func append(
    client: String,
    original: String,
    corrected: String,
    explanation: String,
    provider: String,
    model: String
  ) {
    do {
      try ensureDirectory()
      let entry = Entry(
        timestamp: ISO8601DateFormatter().string(from: now()),
        client: client,
        original: original,
        corrected: corrected,
        explanation: explanation,
        provider: provider,
        model: model
      )
      var line = try JSONEncoder().encode(entry)
      line.append(0x0A)
      try appendToFile(line)
      NotificationCenter.default.post(name: .bexLearningLogDidChange, object: nil)
    } catch {
      // Fire-and-forget: intentionally ignored, see doc comment above.
    }
  }

  /// Reads every entry currently on disk, oldest first. Never throws: a missing file
  /// yields `[]`, and malformed or blank lines are skipped rather than failing the
  /// whole read — this log is best-effort, read-only tooling, not a source of truth
  /// that must round-trip perfectly.
  func readAll() -> [Entry] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    let decoder = JSONDecoder()
    return data.split(separator: 0x0A).compactMap { line in
      guard !line.isEmpty else { return nil }
      return try? decoder.decode(Entry.self, from: Data(line))
    }
  }

  private func ensureDirectory() throws {
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directoryURL.path, 0o700)
  }

  private func appendToFile(_ data: Data) throws {
    let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    defer { close(descriptor) }
    chmod(fileURL.path, 0o600)

    var writeError: Error?
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        if result <= 0 {
          writeError = CocoaError(.fileWriteUnknown)
          break
        }
        offset += result
      }
    }
    if let writeError { throw writeError }
  }
}
