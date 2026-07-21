import CryptoKit
import Darwin
import Foundation

actor HookInstallationManager: HookInstallationManaging {
  private struct Manifest: Codable {
    struct Entry: Codable {
      let baseline: Data?
      let fileDidNotExist: Bool
      var postInstallDigest: String
      let mode: UInt16?
    }
    var entries: [String: Entry]
  }

  private let fileManager: FileManager
  private let environment: [String: String]
  private let homeDirectory: URL
  private let embeddedHelperURL: URL
  private let supportDirectory: URL

  init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    embeddedHelperURL: URL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/bex-hook"),
    supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex", isDirectory: true)
  ) {
    self.fileManager = fileManager
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.embeddedHelperURL = embeddedHelperURL
    self.supportDirectory = supportDirectory
  }

  var stableHelperURL: URL {
    supportDirectory.appendingPathComponent("bin/bex-hook")
  }

  func configuredPath(for client: PromptClient) -> URL {
    switch client {
    case .claudeCode:
      let root = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
        ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
      return root.appendingPathComponent("settings.json")
    case .codex:
      let root = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
        ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
      return root.appendingPathComponent("hooks.json")
    }
  }

  func status(for client: PromptClient) async -> HookInstallationStatus {
    let configURL = configuredPath(for: client)
    guard fileManager.fileExists(atPath: configURL.path) else { return .notInstalled }
    guard let root = try? readRoot(at: configURL) else {
      return .needsRepair("The hook configuration is not valid JSON.")
    }
    guard containsBexHandler(in: root, client: client) else {
      return .notInstalled
    }
    guard fileManager.isExecutableFile(atPath: stableHelperURL.path) else {
      return .needsRepair("The Bex hook helper is missing or is not executable.")
    }
    guard helperProtocolMatches() else {
      return .needsRepair("The Bex hook helper protocol does not match this app.")
    }
    guard manifestEntry(for: client) != nil else {
      return .needsRepair("The Bex hook installation manifest is missing.")
    }
    if let heartbeat = heartbeatDate(for: client) {
      return .active(lastSeen: heartbeat)
    }
    return client == .codex ? .awaitingCodexTrust : .installedUnconfirmed
  }

  func install(_ client: PromptClient) async throws {
    try refreshHelper()
    let url = configuredPath(for: client)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try mutateConfig(client: client, install: true)
  }

  func uninstall(_ client: PromptClient) async throws {
    let url = configuredPath(for: client)
    if let entry = manifestEntry(for: client),
      let current = try? Data(contentsOf: url),
      Self.digest(current) == entry.postInstallDigest
    {
      if entry.fileDidNotExist {
        try? fileManager.removeItem(at: url)
      } else if let baseline = entry.baseline {
        try safeWrite(
          baseline,
          to: url,
          expected: current,
          mode: mode_t(entry.mode ?? 0o600)
        )
      }
    } else if fileManager.fileExists(atPath: url.path) {
      try mutateConfig(client: client, install: false)
    }
    removeManifestEntry(for: client)

    let other: PromptClient = client == .claudeCode ? .codex : .claudeCode
    if case .notInstalled = await status(for: other) {
      try? fileManager.removeItem(at: stableHelperURL)
    }
  }

  func refreshInstalledHelper() async throws {
    let statuses = [
      await status(for: .claudeCode),
      await status(for: .codex),
    ]
    guard statuses.contains(where: {
      switch $0 {
      case .notInstalled, .unavailable: false
      default: true
      }
    }) else {
      return
    }
    try refreshHelper()
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func mutateConfig(client: PromptClient, install: Bool) throws {
    let url = configuredPath(for: client)
    for attempt in 0..<2 {
      let existed = fileManager.fileExists(atPath: url.path)
      let before = existed ? try Data(contentsOf: url) : Data("{}".utf8)
      let metadata = try metadataSnapshot(at: url)
      let mode = try fileMode(at: url, fallback: 0o600)
      var root = try decodeRoot(before)
      if install, containsBexHandler(in: root, client: client) {
        guard manifestEntry(for: client) != nil else {
          throw BexError.storageFailure(
            "The hook configuration already contains the Bex handler, but its installation manifest is missing."
          )
        }
        return
      }
      if install {
        try addBexHandler(to: &root, client: client)
      } else {
        try removeBexHandler(from: &root, client: client)
      }
      let encoder = JSONSerialization.WritingOptions([.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      var output = try JSONSerialization.data(withJSONObject: root, options: encoder)
      output.append(0x0A)
      if output == before {
        if install, manifestEntry(for: client) == nil {
          throw BexError.storageFailure(
            "The hook configuration already contains the Bex handler, but its installation manifest is missing."
          )
        }
        return
      }

      let currentMetadata = try metadataSnapshot(at: url)
      guard currentMetadata == metadata else {
        if attempt == 0 { continue }
        throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
      }
      try retainRollback(existed ? before : nil, for: client)
      try safeWrite(
        output,
        to: url,
        expected: existed ? before : nil,
        mode: mode,
        requiresAbsentWhenExpectedNil: !existed
      )
      if install {
        try recordInstall(
          client: client,
          baseline: existed ? before : nil,
          fileDidNotExist: !existed,
          postDigest: Self.digest(output),
          mode: UInt16(mode)
        )
      }
      return
    }
  }

  private func addBexHandler(
    to root: inout [String: Any],
    client: PromptClient
  ) throws {
    let hooks: [String: Any]
    if let existing = root["hooks"] {
      guard let object = existing as? [String: Any] else {
        throw BexError.storageFailure(
          "The hook configuration has an invalid \"hooks\" value; expected a JSON object."
        )
      }
      hooks = object
    } else {
      hooks = [:]
    }
    var mutableHooks = hooks
    let handlers: [[String: Any]]
    if let existing = hooks["UserPromptSubmit"] {
      guard let array = existing as? [[String: Any]] else {
        throw BexError.storageFailure(
          "The hook configuration has an invalid \"UserPromptSubmit\" value; expected an array of hook objects."
        )
      }
      handlers = array
    } else {
      handlers = []
    }
    var mutableHandlers = handlers
    guard !mutableHandlers.contains(where: { isBexHandler($0, client: client) }) else {
      return
    }
    switch client {
    case .claudeCode:
      mutableHandlers.append([
        "hooks": [[
          "type": "command",
          "command": stableHelperURL.path,
          "args": ["claude"],
          "timeout": 3600,
          "statusMessage": "Bex is reviewing this prompt…",
        ]]
      ])
    case .codex:
      mutableHandlers.append([
        "hooks": [[
          "type": "command",
          "command": "exec \(Self.shellQuote(stableHelperURL.path)) codex",
          "timeout": 3600,
          "async": false,
          "statusMessage": "Bex is reviewing this prompt…",
        ]]
      ])
    }
    mutableHooks["UserPromptSubmit"] = mutableHandlers
    root["hooks"] = mutableHooks
  }

  private func removeBexHandler(
    from root: inout [String: Any],
    client: PromptClient
  ) throws {
    guard let existingHooks = root["hooks"] else { return }
    guard var hooks = existingHooks as? [String: Any] else {
      throw BexError.storageFailure(
        "The hook configuration has an invalid \"hooks\" value; expected a JSON object."
      )
    }
    guard let existingHandlers = hooks["UserPromptSubmit"] else { return }
    guard let handlers = existingHandlers as? [[String: Any]] else {
      throw BexError.storageFailure(
        "The hook configuration has an invalid \"UserPromptSubmit\" value; expected an array of hook objects."
      )
    }
    hooks["UserPromptSubmit"] = handlers.filter { !isBexHandler($0, client: client) }
    root["hooks"] = hooks
  }

  private func containsBexHandler(in root: [String: Any], client: PromptClient) -> Bool {
    guard let hooks = root["hooks"] as? [String: Any],
      let handlers = hooks["UserPromptSubmit"] as? [[String: Any]]
    else {
      return false
    }
    return handlers.contains { isBexHandler($0, client: client) }
  }

  private func isBexHandler(_ handler: [String: Any], client: PromptClient) -> Bool {
    switch client {
    case .claudeCode:
      guard let nested = handler["hooks"] as? [[String: Any]] else { return false }
      return nested.contains {
        $0["command"] as? String == stableHelperURL.path
          && ($0["args"] as? [String]) == ["claude"]
      }
    case .codex:
      guard let nested = handler["hooks"] as? [[String: Any]] else { return false }
      return nested.contains {
        $0["type"] as? String == "command"
          && $0["command"] as? String
            == "exec \(Self.shellQuote(stableHelperURL.path)) codex"
      }
    }
  }

  private func readRoot(at url: URL) throws -> [String: Any] {
    try decodeRoot(Data(contentsOf: url))
  }

  private func decodeRoot(_ data: Data) throws -> [String: Any] {
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BexError.storageFailure("The hook configuration root must be a JSON object.")
    }
    return root
  }

  private func refreshHelper() throws {
    guard fileManager.fileExists(atPath: embeddedHelperURL.path) else {
      throw BexError.storageFailure("The embedded Bex hook helper is missing.")
    }
    let directory = stableHelperURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    let data = try Data(contentsOf: embeddedHelperURL)
    try safeWrite(data, to: stableHelperURL, expected: nil, mode: 0o755)
  }

  private func helperProtocolMatches() -> Bool {
    let process = Process()
    let output = Pipe()
    process.executableURL = stableHelperURL
    process.arguments = ["--self-check"]
    process.standardOutput = output
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      guard process.terminationStatus == 0,
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        return false
      }
      return object["protocolVersion"] as? Int == HookProtocolConstants.version
    } catch {
      return false
    }
  }

  private func heartbeatDate(for client: PromptClient) -> Date? {
    let url = supportDirectory.appendingPathComponent(
      "PromptGate/heartbeats/\(client.rawValue).json"
    )
    guard let data = try? Data(contentsOf: url),
      let heartbeat = try? JSONDecoder().decode(HookHeartbeat.self, from: data),
      heartbeat.version == HookProtocolConstants.version,
      heartbeat.client == client
    else {
      return nil
    }
    return heartbeat.seenAt
  }

  private var manifestURL: URL {
    supportDirectory.appendingPathComponent("PromptGate/install-manifest.json")
  }

  private func manifest() -> Manifest {
    guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
    else {
      return Manifest(entries: [:])
    }
    return manifest
  }

  private func manifestEntry(for client: PromptClient) -> Manifest.Entry? {
    manifest().entries[client.rawValue]
  }

  private func recordInstall(
    client: PromptClient,
    baseline: Data?,
    fileDidNotExist: Bool,
    postDigest: String,
    mode: UInt16
  ) throws {
    var manifest = manifest()
    if let existing = manifest.entries[client.rawValue] {
      manifest.entries[client.rawValue] = Manifest.Entry(
        baseline: existing.baseline,
        fileDidNotExist: existing.fileDidNotExist,
        postInstallDigest: postDigest,
        mode: existing.mode ?? mode
      )
    } else {
      manifest.entries[client.rawValue] = Manifest.Entry(
        baseline: baseline,
        fileDidNotExist: fileDidNotExist,
        postInstallDigest: postDigest,
        mode: mode
      )
    }
    try writeManifest(manifest)
  }

  private func removeManifestEntry(for client: PromptClient) {
    var manifest = manifest()
    manifest.entries.removeValue(forKey: client.rawValue)
    try? writeManifest(manifest)
  }

  private func writeManifest(_ manifest: Manifest) throws {
    let directory = manifestURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    try safeWrite(try JSONEncoder().encode(manifest), to: manifestURL, expected: nil)
  }

  private func retainRollback(_ data: Data?, for client: PromptClient) throws {
    let url = supportDirectory.appendingPathComponent(
      "PromptGate/rollback-\(client.rawValue).json"
    )
    if let data {
      try safeWrite(data, to: url, expected: nil)
    } else {
      try? fileManager.removeItem(at: url)
    }
  }

  private func safeWrite(
    _ data: Data,
    to url: URL,
    expected: Data?,
    mode: mode_t = 0o600,
    requiresAbsentWhenExpectedNil: Bool = false
  ) throws {
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    if let expected {
      guard let current = try? Data(contentsOf: url), current == expected else {
        throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
      }
    } else if requiresAbsentWhenExpectedNil, fileManager.fileExists(atPath: url.path) {
      throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
    }
    let temporary = directory.appendingPathComponent(".bex-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode)
    guard descriptor >= 0 else {
      throw BexError.storageFailure("Bex could not create a hook configuration update.")
    }
    var failure = false
    data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
        guard count > 0 else {
          failure = true
          break
        }
        offset += count
      }
    }
    if fsync(descriptor) != 0 { failure = true }
    close(descriptor)
    if failure || rename(temporary.path, url.path) != 0 {
      unlink(temporary.path)
      throw BexError.storageFailure("Bex could not write the hook configuration.")
    }
    chmod(url.path, mode)
  }

  private func fileMode(at url: URL, fallback: mode_t) throws -> mode_t {
    guard fileManager.fileExists(atPath: url.path) else { return fallback }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
      return fallback
    }
    return mode_t(permissions.uint16Value)
  }

  private func metadataSnapshot(at url: URL) throws -> String {
    guard fileManager.fileExists(atPath: url.path) else { return "missing" }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let data = try Data(contentsOf: url)
    return "\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? Date.distantPast)|\(Self.digest(data))"
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
