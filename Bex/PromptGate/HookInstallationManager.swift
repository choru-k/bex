import CryptoKit
import Darwin
import Foundation
import Security

actor HookInstallationManager: HookInstallationManaging {
  private struct Manifest: Codable {
    struct Entry: Codable {
      let baseline: Data?
      let fileDidNotExist: Bool
      var postInstallDigest: String
      let mode: UInt16?
      var integrationID: String?
      var client: PromptClient?
      var destination: String?
      var helperPath: String?
      var helperDigest: String?
      var profile: String?
      var executablePath: String?
      var workingDirectory: String?
      var capabilityVersion: Int?
      var installedAt: Date?

      init(
        baseline: Data?,
        fileDidNotExist: Bool,
        postInstallDigest: String,
        mode: UInt16?,
        integrationID: String? = nil,
        client: PromptClient? = nil,
        destination: String? = nil,
        helperPath: String? = nil,
        helperDigest: String? = nil,
        profile: String? = nil,
        executablePath: String? = nil,
        workingDirectory: String? = nil,
        capabilityVersion: Int? = nil,
        installedAt: Date? = nil
      ) {
        self.baseline = baseline
        self.fileDidNotExist = fileDidNotExist
        self.postInstallDigest = postInstallDigest
        self.mode = mode
        self.integrationID = integrationID
        self.client = client
        self.destination = destination
        self.helperPath = helperPath
        self.helperDigest = helperDigest
        self.profile = profile
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.capabilityVersion = capabilityVersion
        self.installedAt = installedAt
      }
    }
    var version: Int?
    var entries: [String: Entry]
  }

  private struct PathIdentity: Equatable {
    let url: URL
    let device: UInt64
    let inode: UInt64
  }

  private struct PreparedWrite {
    let url: URL
    let before: Data?
    let after: Data?
    let mode: mode_t
  }

  private struct CommittedWrite {
    let write: PreparedWrite
    let installedIdentity: PathIdentity?
  }

  private struct PreparedTransaction {
    let review: HookInstallationReview
    let writes: [PreparedWrite]
    let ancestorIdentities: [PathIdentity]
    let targetIdentities: [String: PathIdentity]
  }

  private struct OMPCapabilityResponse: Decodable {
    let capabilities: [String]
    let profile: String
    let agentDir: String
    let gateDir: String
    let cwd: String

    private enum CodingKeys: String, CodingKey {
      case capabilities
      case profile
      case agentDir = "agent_dir"
      case gateDir = "gate_dir"
      case cwd
    }
  }

  private let fileManager: FileManager
  private let environment: [String: String]
  private let homeDirectory: URL
  private let embeddedHelperURL: URL
  private let supportDirectory: URL
  private let signatureVerifier: @Sendable (URL) throws -> Void
  private let transactionFaultInjector: @Sendable (Int, URL?) throws -> Void
  private var preparedTransactions: [UUID: PreparedTransaction] = [:]

  init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    embeddedHelperURL: URL = Bundle.main.bundleURL
      .appendingPathComponent("Contents/Helpers/bex-hook"),
    supportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex", isDirectory: true),
    signatureVerifier: @escaping @Sendable (URL) throws -> Void = HookInstallationManager.verifyHelperSignature,
    transactionFaultInjector: @escaping @Sendable (Int, URL?) throws -> Void = { _, _ in }
  ) {
    self.fileManager = fileManager
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.embeddedHelperURL = embeddedHelperURL
    self.supportDirectory = supportDirectory
    self.signatureVerifier = signatureVerifier
    self.transactionFaultInjector = transactionFaultInjector
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
    case .ohMyPi:
      return homeDirectory.appendingPathComponent(".omp/agent/prompt-gates/bex.json")
    }
  }

  func status(for client: PromptClient) async -> HookInstallationStatus {
    let manifest: Manifest
    do {
      manifest = try loadManifest()
    } catch {
      return .unavailable("The Bex ownership manifest is corrupt.")
    }
    if let entry = manifest.entries[client.rawValue],
      entry.helperPath != nil,
      let descriptor = await installedDescriptors().first(where: {
        $0.client == client && $0.id == client.rawValue
      })
    {
      return await status(for: descriptor.id)
    }
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

  func resolve(_ target: HookIntegrationTarget) async throws -> HookIntegrationDescriptor {
    let helper = try contentAddressedHelperURL()
    switch target {
    case .claudeCode:
      return HookIntegrationDescriptor(
        id: PromptClient.claudeCode.rawValue,
        client: .claudeCode,
        profile: "default",
        executableURL: nil,
        workingDirectory: nil,
        configurationURL: configuredPath(for: .claudeCode),
        gateURL: nil,
        helperURL: helper,
        capabilityVersion: nil,
        validation: .supported
      )
    case .codex:
      return HookIntegrationDescriptor(
        id: PromptClient.codex.rawValue,
        client: .codex,
        profile: "default",
        executableURL: nil,
        workingDirectory: nil,
        configurationURL: configuredPath(for: .codex),
        gateURL: nil,
        helperURL: helper,
        capabilityVersion: nil,
        validation: .supported
      )
    case let .ohMyPi(executable, profile, workingDirectory):
      let capability = try queryOMPCapability(
        executable: executable,
        profile: profile,
        workingDirectory: workingDirectory
      )
      let gateDirectory = try exactAbsoluteDirectoryURL(
        capability.gateDir,
        field: "gate_dir"
      )
      let gateURL = gateDirectory.appendingPathComponent("bex.json")
      let integrationID = "omp-\(Self.digest(Data(gateURL.path.utf8)).prefix(32))"
      let validation: HookIntegrationValidation =
        capability.capabilities.contains(HookProtocolConstants.promptGateCapability)
        ? .supported
        : .unavailable(
          "This Oh My Pi build does not advertise prompt-gate-v1. Install a compatible OMP release before enabling Bex."
        )
      return HookIntegrationDescriptor(
        id: integrationID,
        client: .ohMyPi,
        profile: capability.profile,
        executableURL: executable.standardizedFileURL,
        workingDirectory: try exactAbsoluteDirectoryURL(capability.cwd, field: "cwd"),
        configurationURL: gateURL,
        gateURL: gateURL,
        helperURL: helper,
        capabilityVersion: capability.capabilities.contains(HookProtocolConstants.promptGateCapability) ? 1 : nil,
        validation: validation
      )
    }
  }

  func installedDescriptors() async -> [HookIntegrationDescriptor] {
    guard let manifest = try? loadManifest() else { return [] }
    return manifest.entries.compactMap { key, entry in
      let client = entry.client ?? PromptClient(rawValue: key)
      guard let client else { return nil }
      let destination = entry.destination.map(URL.init(fileURLWithPath:))
        ?? (client == .ohMyPi ? nil : configuredPath(for: client))
      guard let destination else { return nil }
      let helperURL = entry.helperPath.map(URL.init(fileURLWithPath:)) ?? stableHelperURL
      return HookIntegrationDescriptor(
        id: entry.integrationID ?? (client == .ohMyPi ? key : client.rawValue),
        client: client,
        profile: entry.profile ?? "default",
        executableURL: entry.executablePath.map(URL.init(fileURLWithPath:)),
        workingDirectory: entry.workingDirectory.map(URL.init(fileURLWithPath:)),
        configurationURL: destination,
        gateURL: client == .ohMyPi ? destination : nil,
        helperURL: helperURL,
        capabilityVersion: entry.capabilityVersion,
        validation: client == .ohMyPi && entry.capabilityVersion != 1
          ? .unavailable("The installed OMP integration does not have a compatible prompt-gate-v1 contract.")
          : .supported
      )
    }.sorted { $0.id < $1.id }
  }

  func prepare(
    _ operation: HookInstallationOperation,
    for descriptor: HookIntegrationDescriptor
  ) async throws -> HookInstallationReview {
    try signatureVerifier(embeddedHelperURL)
    guard case .supported = descriptor.validation else {
      if case let .unavailable(reason) = descriptor.validation {
        throw BexError.storageFailure(reason)
      }
      throw BexError.storageFailure("This integration target is unavailable.")
    }
    let transaction = try makePreparedTransaction(operation: operation, descriptor: descriptor)
    preparedTransactions[transaction.review.id] = transaction
    return transaction.review
  }

  func apply(reviewID: UUID) async throws -> HookInstallationResult {
    guard let transaction = preparedTransactions.removeValue(forKey: reviewID) else {
      throw BexError.storageFailure("This integration review is stale or was already applied.")
    }
    try signatureVerifier(embeddedHelperURL)
    return try applyPreparedTransaction(transaction)
  }

  func cancel(reviewID: UUID) async {
    preparedTransactions.removeValue(forKey: reviewID)
  }

  func status(for integrationID: String) async -> HookInstallationStatus {
    let manifest: Manifest
    do {
      manifest = try loadManifest()
    } catch {
      return .unavailable("The Bex ownership manifest is corrupt.")
    }
    guard let descriptor = await installedDescriptors().first(where: { $0.id == integrationID }) else {
      if integrationID == PromptClient.claudeCode.rawValue {
        return await status(for: .claudeCode)
      }
      if integrationID == PromptClient.codex.rawValue {
        return await status(for: .codex)
      }
      return .notInstalled
    }
    guard case .supported = descriptor.validation else {
      if case let .unavailable(reason) = descriptor.validation { return .unavailable(reason) }
      return .unavailable("The integration target is unavailable.")
    }
    if descriptor.client == .ohMyPi {
      guard let executable = descriptor.executableURL,
        let workingDirectory = descriptor.workingDirectory
      else {
        return .needsRepair("The installed OMP target metadata is incomplete.")
      }
      do {
        let capability = try queryOMPCapability(
          executable: executable,
          profile: descriptor.profile,
          workingDirectory: workingDirectory
        )
        guard capability.capabilities.contains(HookProtocolConstants.promptGateCapability) else {
          return .unavailable("This OMP target no longer advertises prompt-gate-v1.")
        }
        let reportedGateURL = try exactAbsoluteDirectoryURL(
          capability.gateDir,
          field: "gate_dir"
        ).appendingPathComponent("bex.json")
        guard reportedGateURL == descriptor.configurationURL,
          capability.profile == descriptor.profile
        else {
          return .needsRepair(
            "The OMP target now resolves to profile \(capability.profile) at \(reportedGateURL.path), not the reviewed profile \(descriptor.profile) at \(descriptor.configurationURL.path)."
          )
        }
      } catch {
        return .unavailable(error.localizedDescription)
      }
    }
    guard let entry = manifest.entries[integrationID] else {
      return .needsRepair("The Bex ownership manifest does not contain this integration.")
    }
    guard let configuration = try? Data(contentsOf: descriptor.configurationURL),
      Self.digest(configuration) == entry.postInstallDigest
    else {
      return .needsRepair("The installed integration artifact no longer matches the reviewed bytes.")
    }
    guard let helper = try? Data(contentsOf: descriptor.helperURL),
      Self.digest(helper) == entry.helperDigest,
      fileManager.isExecutableFile(atPath: descriptor.helperURL.path)
    else {
      return .needsRepair("The immutable Bex hook helper is missing or has changed.")
    }
    do {
      try signatureVerifier(descriptor.helperURL)
    } catch {
      return .needsRepair("The immutable Bex hook helper signature is invalid.")
    }
    if let embedded = try? Data(contentsOf: embeddedHelperURL),
      Self.digest(embedded) != entry.helperDigest
    {
      return .updateAvailable
    }
    let heartbeat = heartbeatDate(for: descriptor.id)
    let hasCurrentHeartbeat =
      heartbeat.map {
        $0 >= (entry.installedAt ?? .distantPast)
          && $0 <= Date().addingTimeInterval(300)
      } ?? false
    if descriptor.client == .codex, !hasCurrentHeartbeat {
      return .awaitingCodexTrust
    }
    if let heartbeat, hasCurrentHeartbeat {
      return .active(lastSeen: heartbeat)
    }
    return .installedUnconfirmed
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
    client: PromptClient,
    helperURL: URL? = nil
  ) throws {
    let installedHelperURL = helperURL ?? stableHelperURL
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
    guard !mutableHandlers.contains(where: {
      isBexHandler($0, client: client, helperURL: installedHelperURL)
    }) else {
      return
    }
    switch client {
    case .claudeCode:
      mutableHandlers.append([
        "hooks": [[
          "type": "command",
          "command": installedHelperURL.path,
          "args": ["claude"],
          "timeout": 3600,
          "statusMessage": "Bex is reviewing this prompt…",
        ]]
      ])
    case .codex:
      mutableHandlers.append([
        "hooks": [[
          "type": "command",
          "command": "exec \(Self.shellQuote(installedHelperURL.path)) codex",
          "timeout": 3600,
          "async": false,
          "statusMessage": "Bex is reviewing this prompt…",
        ]]
      ])
    case .ohMyPi:
      throw BexError.storageFailure("OMP integrations require a resolved native gate descriptor.")
    }
    mutableHooks["UserPromptSubmit"] = mutableHandlers
    root["hooks"] = mutableHooks
  }

  private func removeBexHandler(
    from root: inout [String: Any],
    client: PromptClient,
    helperURL: URL? = nil
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
    hooks["UserPromptSubmit"] = handlers.filter {
      !isBexHandler($0, client: client, helperURL: helperURL)
    }
    root["hooks"] = hooks
  }

  private func containsBexHandler(
    in root: [String: Any],
    client: PromptClient,
    helperURL: URL? = nil
  ) -> Bool {
    guard let hooks = root["hooks"] as? [String: Any],
      let handlers = hooks["UserPromptSubmit"] as? [[String: Any]]
    else {
      return false
    }
    return handlers.contains { isBexHandler($0, client: client, helperURL: helperURL) }
  }

  private func isBexHandler(
    _ handler: [String: Any],
    client: PromptClient,
    helperURL: URL? = nil
  ) -> Bool {
    let installedHelperURL = helperURL ?? stableHelperURL
    switch client {
    case .claudeCode:
      guard let nested = handler["hooks"] as? [[String: Any]] else { return false }
      return nested.contains {
        $0["command"] as? String == installedHelperURL.path
          && ($0["args"] as? [String]) == ["claude"]
      }
    case .codex:
      guard let nested = handler["hooks"] as? [[String: Any]] else { return false }
      return nested.contains {
        $0["type"] as? String == "command"
          && $0["command"] as? String
            == "exec \(Self.shellQuote(installedHelperURL.path)) codex"
      }
    case .ohMyPi:
      return false
    }
  }

  private func contentAddressedHelperURL() throws -> URL {
    guard fileManager.fileExists(atPath: embeddedHelperURL.path) else {
      throw BexError.storageFailure("The embedded Bex hook helper is missing.")
    }
    let digest = Self.digest(try Data(contentsOf: embeddedHelperURL))
    return supportDirectory
      .appendingPathComponent("bin/\(digest)", isDirectory: true)
      .appendingPathComponent(HookProtocolConstants.helperName)
  }

  private func exactAbsoluteDirectoryURL(_ path: String, field: String) throws -> URL {
    guard path.hasPrefix("/"),
      path == "/" || (!path.hasSuffix("/") && !path.contains("//")),
      !path.split(separator: "/", omittingEmptySubsequences: true)
        .contains(where: { $0 == "." || $0 == ".." })
    else {
      throw BexError.storageFailure("OMP returned a non-canonical absolute \(field) path.")
    }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private func queryOMPCapability(
    executable: URL,
    profile: String?,
    workingDirectory: URL
  ) throws -> OMPCapabilityResponse {
    guard executable.path.hasPrefix("/"), try isRegularNonSymlink(executable) else {
      throw BexError.storageFailure("The selected OMP executable must be an absolute regular file.")
    }
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = ["capabilities", "--json"]
    process.currentDirectoryURL = workingDirectory
    var processEnvironment = environment
    if let profile {
      processEnvironment["OMP_PROFILE"] = profile
    }
    process.environment = processEnvironment
    process.standardOutput = standardOutput
    process.standardError = standardError
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    try process.run()
    guard completion.wait(timeout: .now() + 3) == .success else {
      process.terminate()
      if completion.wait(timeout: .now() + 0.25) != .success {
        kill(process.processIdentifier, SIGKILL)
        _ = completion.wait(timeout: .now() + 0.25)
      }
      throw BexError.storageFailure("The OMP capability query timed out.")
    }
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
    guard output.count <= 64 * 1024, errorOutput.count <= 64 * 1024 else {
      throw BexError.storageFailure("The OMP capability response was too large.")
    }
    guard process.terminationStatus == 0,
      let response = try? JSONDecoder().decode(OMPCapabilityResponse.self, from: output)
    else {
      let detail = String(data: errorOutput, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw BexError.storageFailure(
        detail?.isEmpty == false
          ? "OMP capability query failed: \(detail!)"
          : "The selected OMP build does not expose machine-readable capabilities."
      )
    }
    return response
  }

  private func loadManifest() throws -> Manifest {
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      return Manifest(version: nil, entries: [:])
    }
    do {
      return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    } catch {
      throw BexError.storageFailure("The Bex hook installation manifest is corrupt.")
    }
  }

  private func makePreparedTransaction(
    operation: HookInstallationOperation,
    descriptor: HookIntegrationDescriptor
  ) throws -> PreparedTransaction {
    let helperData = try Data(contentsOf: embeddedHelperURL)
    let helperDigest = Self.digest(helperData)
    var manifest = try loadManifest()
    let existingEntry = manifest.entries[descriptor.id]
    let resolvedHelperURL = try contentAddressedHelperURL()
    let acceptsLegacyUninstall =
      operation == .uninstall
      && existingEntry?.helperPath == nil
      && descriptor.helperURL == stableHelperURL
    guard descriptor.helperURL == resolvedHelperURL || acceptsLegacyUninstall else {
      throw BexError.storageFailure("The resolved helper changed; resolve the integration again.")
    }
    let configExists = fileManager.fileExists(atPath: descriptor.configurationURL.path)
    let currentConfig = configExists ? try Data(contentsOf: descriptor.configurationURL) : nil
    let currentMode = UInt16(try fileMode(at: descriptor.configurationURL, fallback: 0o600))
    var writes: [PreparedWrite] = []
    var proposedConfig: Data?

    switch operation {
    case .install, .update, .repair:
      switch descriptor.client {
      case .ohMyPi:
        proposedConfig = try renderOMPGate(descriptor: descriptor, helperDigest: helperDigest)
      case .claudeCode, .codex:
        var root = try decodeRoot(currentConfig ?? Data("{}".utf8))
        if let existingEntry {
          let oldHelperURL = existingEntry.helperPath.map(URL.init(fileURLWithPath:))
            ?? stableHelperURL
          try removeBexHandler(
            from: &root,
            client: descriptor.client,
            helperURL: oldHelperURL
          )
        }
        try addBexHandler(to: &root, client: descriptor.client, helperURL: descriptor.helperURL)
        proposedConfig = try encodedJSONObject(root)
      }
      guard let proposedConfig else {
        throw BexError.storageFailure("Bex could not render the integration artifact.")
      }
      let baseline = existingEntry?.baseline ?? currentConfig
      let entry = Manifest.Entry(
        baseline: baseline,
        fileDidNotExist: existingEntry?.fileDidNotExist ?? !configExists,
        postInstallDigest: Self.digest(proposedConfig),
        mode: existingEntry?.mode ?? currentMode,
        integrationID: descriptor.id,
        client: descriptor.client,
        destination: descriptor.configurationURL.path,
        helperPath: descriptor.helperURL.path,
        helperDigest: helperDigest,
        profile: descriptor.profile,
        executablePath: descriptor.executableURL?.path,
        workingDirectory: descriptor.workingDirectory?.path,
        capabilityVersion: descriptor.capabilityVersion,
        installedAt: Date()
      )
      manifest.version = 2
      manifest.entries[descriptor.id] = entry
      let existingHelper = fileManager.fileExists(atPath: descriptor.helperURL.path)
        ? try Data(contentsOf: descriptor.helperURL)
        : nil
      writes.append(
        PreparedWrite(url: descriptor.helperURL, before: existingHelper, after: helperData, mode: 0o755)
      )
      writes.append(
        PreparedWrite(
          url: descriptor.configurationURL,
          before: currentConfig,
          after: proposedConfig,
          mode: mode_t(currentMode)
        )
      )
      writes.append(
        PreparedWrite(
          url: manifestURL,
          before: fileManager.fileExists(atPath: manifestURL.path)
            ? try Data(contentsOf: manifestURL)
            : nil,
          after: try encodedManifest(manifest),
          mode: 0o600
        )
      )

    case .uninstall:
      guard let entry = existingEntry else {
        throw BexError.storageFailure("Bex does not own this integration.")
      }
      switch descriptor.client {
      case .ohMyPi:
        guard currentConfig.map(Self.digest) == entry.postInstallDigest else {
          throw BexError.storageFailure("The OMP gate changed after installation; repair ownership before uninstalling.")
        }
        proposedConfig = nil
      case .claudeCode, .codex:
        if currentConfig.map(Self.digest) == entry.postInstallDigest {
          proposedConfig = entry.fileDidNotExist ? nil : entry.baseline
        } else {
          guard let currentConfig else {
            throw BexError.storageFailure("The owned hook configuration is missing.")
          }
          var root = try decodeRoot(currentConfig)
          let ownedHelperURL = entry.helperPath.map(URL.init(fileURLWithPath:)) ?? descriptor.helperURL
          guard containsBexHandler(
            in: root,
            client: descriptor.client,
            helperURL: ownedHelperURL
          ) else {
            throw BexError.storageFailure("The Bex-owned hook fragment changed and cannot be removed safely.")
          }
          try removeBexHandler(
            from: &root,
            client: descriptor.client,
            helperURL: ownedHelperURL
          )
          proposedConfig = try encodedJSONObject(root)
        }
      }
      writes.append(
        PreparedWrite(
          url: descriptor.configurationURL,
          before: currentConfig,
          after: proposedConfig,
          mode: mode_t(entry.mode ?? currentMode)
        )
      )
      manifest.version = 2
      manifest.entries.removeValue(forKey: descriptor.id)
      writes.append(
        PreparedWrite(
          url: manifestURL,
          before: fileManager.fileExists(atPath: manifestURL.path)
            ? try Data(contentsOf: manifestURL)
            : nil,
          after: try encodedManifest(manifest),
          mode: 0o600
        )
      )
      let helperStillReferenced = manifest.entries.values.contains {
        let helperPath = $0.helperPath ?? stableHelperURL.path
        return helperPath == descriptor.helperURL.path
      }
      if !helperStillReferenced {
        writes.append(
          PreparedWrite(
            url: descriptor.helperURL,
            before: fileManager.fileExists(atPath: descriptor.helperURL.path)
              ? try Data(contentsOf: descriptor.helperURL)
              : nil,
            after: nil,
            mode: 0o755
          )
        )
      }
    }

    if let existingEntry,
      existingEntry.helperPath == nil,
      descriptor.helperURL != stableHelperURL,
      !manifest.entries.values.contains(where: { $0.helperPath == nil }),
      fileManager.fileExists(atPath: stableHelperURL.path)
    {
      writes.append(
        PreparedWrite(
          url: stableHelperURL,
          before: try Data(contentsOf: stableHelperURL),
          after: nil,
          mode: 0o755
        )
      )
    }

    let reviewID = UUID()
    let actions = try installationActions(for: writes)
    let review = HookInstallationReview(
      id: reviewID,
      operation: operation,
      descriptor: descriptor,
      trustGuidance: trustGuidance(for: descriptor.client),
      limitations: limitations(for: descriptor.client),
      signer: Self.helperSignerDescription(embeddedHelperURL),
      currentText: currentConfig.flatMap { String(data: $0, encoding: .utf8) },
      proposedText: proposedConfig.flatMap { String(data: $0, encoding: .utf8) },
      actions: actions
    )
    let ancestorIdentities = try snapshotAncestorIdentities(for: writes.map(\.url))
    var targetIdentities: [String: PathIdentity] = [:]
    for write in writes {
      if let identity = try pathIdentity(at: write.url, expectedDirectory: false) {
        targetIdentities[write.url.path] = identity
      }
    }
    return PreparedTransaction(
      review: review,
      writes: writes,
      ancestorIdentities: ancestorIdentities,
      targetIdentities: targetIdentities
    )
  }

  private func applyPreparedTransaction(
    _ transaction: PreparedTransaction
  ) throws -> HookInstallationResult {
    try validateIdentities(transaction.ancestorIdentities)
    for write in transaction.writes {
      try validateNoSymlinkAncestors(write.url)
      try validateTargetIdentity(
        for: write,
        expected: transaction.targetIdentities[write.url.path]
      )
      let current = fileManager.fileExists(atPath: write.url.path)
        ? try Data(contentsOf: write.url)
        : nil
      guard current == write.before else {
        throw BexError.storageFailure("Nothing changed because \(write.url.path) changed after review.")
      }
    }

    var committed: [CommittedWrite] = []
    var createdDirectories: [URL] = []
    var runtimeAncestorIdentities = transaction.ancestorIdentities
    var completed: [String] = []
    do {
      for (writeIndex, write) in transaction.writes.enumerated() {
        try transactionFaultInjector(writeIndex, committed.last?.write.url)
        try validateIdentities(runtimeAncestorIdentities)
        try validateNoSymlinkAncestors(write.url)
        try validateTargetIdentity(
          for: write,
          expected: transaction.targetIdentities[write.url.path]
        )
        let missingDirectories = missingParentDirectories(for: write.url)
        for directory in missingDirectories {
          try validateIdentities(runtimeAncestorIdentities)
          guard
            let parentIdentity = runtimeAncestorIdentities.first(where: {
              $0.url.path == directory.deletingLastPathComponent().path
            })
          else {
            throw BexError.storageFailure(
              "The reviewed integration parent directory is unavailable."
            )
          }
          try safeCreateDirectory(
            directory,
            parentIdentity: parentIdentity
          ) { identity in
            createdDirectories.append(directory)
            runtimeAncestorIdentities.append(identity)
          }
        }
        try validateIdentities(runtimeAncestorIdentities)
        let parentIdentity = runtimeAncestorIdentities.first {
          $0.url.path == write.url.deletingLastPathComponent().path
        }
        guard let parentIdentity else {
          throw BexError.storageFailure("The reviewed integration parent directory is unavailable.")
        }
        let expectedIdentity = transaction.targetIdentities[write.url.path]
        let installedIdentity: PathIdentity?
        if let after = write.after {
          installedIdentity = try safeWrite(
            after,
            to: write.url,
            expected: write.before,
            expectedIdentity: expectedIdentity,
            expectedParentIdentity: parentIdentity,
            mode: write.mode,
            requiresAbsentWhenExpectedNil: write.before == nil,
            createParents: false
          )
        } else if let before = write.before {
          try safeRemove(
            write.url,
            expected: before,
            expectedIdentity: expectedIdentity,
            expectedParentIdentity: parentIdentity
          )
          installedIdentity = nil
        } else {
          installedIdentity = nil
        }
        committed.append(
          CommittedWrite(write: write, installedIdentity: installedIdentity)
        )
        completed.append(write.url.path)
      }
      return HookInstallationResult(completed: completed, restored: [], failed: [])
    } catch {
      var restored: [String] = []
      var failed: [String] = []
      for committedWrite in committed.reversed() {
        let write = committedWrite.write
        do {
          try validateIdentities(runtimeAncestorIdentities)
          guard let parentIdentity = runtimeAncestorIdentities.first(where: {
            $0.url.path == write.url.deletingLastPathComponent().path
          }) else {
            throw BexError.storageFailure("The reviewed integration parent directory is unavailable.")
          }
          if let before = write.before {
            try safeWrite(
              before,
              to: write.url,
              expected: write.after,
              expectedIdentity: committedWrite.installedIdentity,
              expectedParentIdentity: parentIdentity,
              mode: write.mode,
              createParents: false
            )
          } else if let after = write.after {
            try safeRemove(
              write.url,
              expected: after,
              expectedIdentity: committedWrite.installedIdentity,
              expectedParentIdentity: parentIdentity
            )
          }
          restored.append(write.url.path)
        } catch {
          failed.append(write.url.path)
        }
      }
      for directory in createdDirectories.reversed() {
        do {
          guard
            let identity = runtimeAncestorIdentities.first(where: { $0.url.path == directory.path }),
            let parentIdentity = runtimeAncestorIdentities.first(where: {
              $0.url.path == directory.deletingLastPathComponent().path
            })
          else {
            throw BexError.storageFailure("A created integration directory lost its reviewed identity.")
          }
          try safeRemoveDirectory(identity, parentIdentity: parentIdentity)
          runtimeAncestorIdentities.removeAll { $0.url.path == directory.path }
          restored.append(directory.path)
        } catch {
          failed.append(directory.path)
        }
      }
      if failed.isEmpty {
        throw error
      }
      return HookInstallationResult(
        completed: completed,
        restored: restored,
        failed: failed
      )
    }
  }

  private func renderOMPGate(
    descriptor: HookIntegrationDescriptor,
    helperDigest: String
  ) throws -> Data {
    try encodedJSONObject([
      "version": HookProtocolConstants.version,
      "event": HookProtocolConstants.promptGateCapability,
      "integration_id": descriptor.id,
      "command": [descriptor.helperURL.path, PromptClient.ohMyPi.rawValue, descriptor.id],
      "command_sha256": helperDigest,
      "first_decision_timeout_ms": 5_000,
      "on_error": "block",
    ])
  }

  private func encodedJSONObject(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(
      withJSONObject: object,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
  }

  private func encodedManifest(_ manifest: Manifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(manifest)
    data.append(0x0A)
    return data
  }

  private func installationActions(
    for writes: [PreparedWrite]
  ) throws -> [HookInstallationAction] {
    var actions: [HookInstallationAction] = []
    var plannedDirectories = Set<String>()
    for write in writes {
      var missing: [URL] = []
      var parent = write.url.deletingLastPathComponent()
      while parent.path != "/" && !fileManager.fileExists(atPath: parent.path) {
        missing.append(parent)
        parent.deleteLastPathComponent()
      }
      for directory in missing.reversed() where plannedDirectories.insert(directory.path).inserted {
        actions.append(
          HookInstallationAction(
            id: "directory:\(directory.path)",
            path: directory.path,
            kind: .directory,
            change: .create,
            before: HookArtifactSnapshot(exists: false, mode: nil, sha256: nil),
            after: HookArtifactSnapshot(exists: true, mode: 0o700, sha256: nil)
          )
        )
      }
      let before = HookArtifactSnapshot(
        exists: write.before != nil,
        mode: write.before == nil ? nil : UInt16(try fileMode(at: write.url, fallback: write.mode)),
        sha256: write.before.map(Self.digest)
      )
      let after = HookArtifactSnapshot(
        exists: write.after != nil,
        mode: write.after == nil ? nil : UInt16(write.mode),
        sha256: write.after.map(Self.digest)
      )
      let change: HookArtifactChange
      switch (write.before, write.after) {
      case (nil, .some): change = .create
      case (.some, nil): change = .delete
      case let (.some(beforeData), .some(afterData)):
        change = beforeData == afterData ? .keep : .replace
      case (nil, nil): change = .keep
      }
      actions.append(
        HookInstallationAction(
          id: "file:\(write.url.path)",
          path: write.url.path,
          kind: .file,
          change: change,
          before: before,
          after: after
        )
      )
    }
    return actions
  }

  private func pathIdentity(
    at url: URL,
    expectedDirectory: Bool
  ) throws -> PathIdentity? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
      if errno == ENOENT { return nil }
      throw BexError.storageFailure("Bex could not inspect integration path identity: \(url.path)")
    }
    let kind = metadata.st_mode & S_IFMT
    let expectedKind = expectedDirectory ? S_IFDIR : S_IFREG
    guard kind == expectedKind else {
      throw BexError.storageFailure(
        "Integration path has an unexpected type or is a symbolic link: \(url.path)"
      )
    }
    return PathIdentity(
      url: url,
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
  }

  private func snapshotAncestorIdentities(for targets: [URL]) throws -> [PathIdentity] {
    var identities: [String: PathIdentity] = [:]
    for target in targets {
      var directory = target.deletingLastPathComponent()
      while true {
        if let identity = try pathIdentity(at: directory, expectedDirectory: true) {
          identities[directory.path] = identity
        }
        if directory.path == "/" { break }
        directory.deleteLastPathComponent()
      }
    }
    return identities.values.sorted { $0.url.path < $1.url.path }
  }

  private func validateIdentities(_ identities: [PathIdentity]) throws {
    for expected in identities {
      guard
        let current = try pathIdentity(
          at: expected.url,
          expectedDirectory: true
        ),
        current.device == expected.device,
        current.inode == expected.inode
      else {
        throw BexError.storageFailure(
          "Nothing changed because ancestor identity changed after review: \(expected.url.path)"
        )
      }
    }
  }

  private func validateTargetIdentity(
    for write: PreparedWrite,
    expected: PathIdentity?
  ) throws {
    let current = try pathIdentity(at: write.url, expectedDirectory: false)
    guard current == expected else {
      throw BexError.storageFailure(
        "Nothing changed because \(write.url.path) changed after review."
      )
    }
  }

  private func missingParentDirectories(for url: URL) -> [URL] {
    var missing: [URL] = []
    var directory = url.deletingLastPathComponent()
    while directory.path != "/", !fileManager.fileExists(atPath: directory.path) {
      missing.append(directory)
      directory.deleteLastPathComponent()
    }
    return missing.reversed()
  }

  private func createParentDirectories(for url: URL) throws {
    let parent = url.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func validateNoSymlinkAncestors(_ url: URL) throws {
    var current = url.deletingLastPathComponent()
    while current.path != "/" {
      if fileManager.fileExists(atPath: current.path) {
        let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw BexError.storageFailure(
            "Integration path contains a non-directory or symbolic link: \(current.path) for \(url.path)"
          )
        }
      }
      current.deleteLastPathComponent()
    }
    if fileManager.fileExists(atPath: url.path) {
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw BexError.storageFailure("Integration artifact must be a regular non-symlink file: \(url.path)")
      }
    }
  }

  private func isRegularNonSymlink(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private func trustGuidance(for client: PromptClient) -> String {
    switch client {
    case .claudeCode:
      "Claude Code /hooks is inspection-only; Bex installation remains explicit."
    case .codex:
      "After Apply, inspect the exact command in Codex /hooks and approve it there."
    case .ohMyPi:
      "OMP uses the selected profile's native prompt-gate-v1 file and must be restarted."
    }
  }

  private func limitations(for client: PromptClient) -> String {
    switch client {
    case .ohMyPi:
      "Text only. Integrity status is a point-in-time check; edited corrections require a new review."
    case .claudeCode, .codex:
      "Text prompts only. Host-native trust and Bex review are separate controls."
    }
  }

  static func verifyHelperSignature(_ url: URL) throws {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      throw BexError.storageFailure("Bex could not inspect the embedded hook signature.")
    }
    guard SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
      throw BexError.storageFailure("The embedded Bex hook signature is invalid.")
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    ) == errSecSuccess,
      let dictionary = information as? [String: Any]
    else {
      throw BexError.storageFailure("The embedded hook signer identity does not match Bex.")
    }
    let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
    let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    if identifier == HookProtocolConstants.helperName, teamID == "ESURPGU29C" {
      return
    }

    #if DEBUG
      guard isBundledAdHocDebugHelper(url, helperInformation: dictionary) else {
        throw BexError.storageFailure("The embedded hook signer identity does not match Bex.")
      }
    #else
      throw BexError.storageFailure("The embedded hook signer identity does not match Bex.")
    #endif
  }

  private static func helperSignerDescription(_ url: URL) -> String {
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode,
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
      ) == errSecSuccess,
      let dictionary = information as? [String: Any]
    else {
      return HookProtocolConstants.helperName
    }
    if let teamID = dictionary[kSecCodeInfoTeamIdentifier as String] as? String {
      return "\(HookProtocolConstants.helperName) · \(teamID)"
    }
    #if DEBUG
      return "\(HookProtocolConstants.helperName) · local debug signature"
    #else
      return HookProtocolConstants.helperName
    #endif
  }

  #if DEBUG
    private static func isBundledAdHocDebugHelper(
      _ url: URL,
      helperInformation: [String: Any]
    ) -> Bool {
      guard let identifier = helperInformation[kSecCodeInfoIdentifier as String] as? String,
        identifier == HookProtocolConstants.helperName
          || identifier.hasPrefix("\(HookProtocolConstants.helperName)-"),
        helperInformation[kSecCodeInfoTeamIdentifier as String] == nil,
        Bundle.main.bundleIdentifier == "com.bex.desktop",
        url.standardizedFileURL.path
          == Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(HookProtocolConstants.helperName)")
            .standardizedFileURL.path
      else {
        return false
      }
      var processCode: SecCode?
      guard SecCodeCopySelf([], &processCode) == errSecSuccess, let processCode else {
        return false
      }
      var processStaticCode: SecStaticCode?
      guard
        SecCodeCopyStaticCode(processCode, [], &processStaticCode) == errSecSuccess,
        let processStaticCode
      else {
        return false
      }
      var processInformation: CFDictionary?
      return SecCodeCopySigningInformation(
        processStaticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &processInformation
      )
        == errSecSuccess
        && (processInformation as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] == nil
    }
  #endif

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

  private func heartbeatDate(for integrationID: String) -> Date? {
    let filename = Self.filenameSafeIdentity(integrationID)
    let canonicalURL = supportDirectory.appendingPathComponent(
      "PromptGate/heartbeats/\(filename).json"
    )
    let legacyClient = PromptClient(rawValue: integrationID)
    let candidates = [canonicalURL] + (legacyClient.map {
      [supportDirectory.appendingPathComponent("PromptGate/heartbeats/\($0.rawValue).json")]
    } ?? [])
    for url in candidates {
      guard let data = try? Data(contentsOf: url),
        let heartbeat = try? JSONDecoder().decode(HookHeartbeat.self, from: data),
        heartbeat.version == HookProtocolConstants.version
      else {
        continue
      }
      let identity = heartbeat.integrationID
        ?? (heartbeat.client == PromptClient.ohMyPi ? nil : heartbeat.client.rawValue)
      if identity == integrationID { return heartbeat.seenAt }
    }
    return nil
  }

  private static func filenameSafeIdentity(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
  }

  private var manifestURL: URL {
    supportDirectory.appendingPathComponent("PromptGate/install-manifest.json")
  }

  private func manifest() -> Manifest {
    guard let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
    else {
      return Manifest(version: nil, entries: [:])
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

  private func openVerifiedDirectory(_ expected: PathIdentity) throws -> Int32 {
    let descriptor = open(expected.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw BexError.storageFailure("The reviewed integration directory is unavailable.")
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      UInt64(metadata.st_dev) == expected.device,
      UInt64(metadata.st_ino) == expected.inode
    else {
      close(descriptor)
      throw BexError.storageFailure(
        "Nothing changed because ancestor identity changed after review: \(expected.url.path)"
      )
    }
    return descriptor
  }

  private func readRelativeFile(
    directoryDescriptor: Int32,
    name: String,
    url: URL
  ) throws -> (data: Data, identity: PathIdentity) {
    let descriptor = openat(directoryDescriptor, name, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw BexError.storageFailure("The integration artifact changed while Bex was editing it.")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
      try? handle.close()
      throw BexError.storageFailure("The integration artifact is not a regular file.")
    }
    let data = try handle.readToEnd() ?? Data()
    try handle.close()
    return (
      data,
      PathIdentity(
        url: url,
        device: UInt64(metadata.st_dev),
        inode: UInt64(metadata.st_ino)
      )
    )
  }

  private func identitiesMatch(_ lhs: PathIdentity, _ rhs: PathIdentity?) -> Bool {
    guard let rhs else { return false }
    return lhs.device == rhs.device && lhs.inode == rhs.inode
  }

  private func safeCreateDirectory(
    _ url: URL,
    parentIdentity: PathIdentity,
    recordInstalled: (PathIdentity) -> Void
  ) throws {
    let parentDescriptor = try openVerifiedDirectory(parentIdentity)
    defer { close(parentDescriptor) }
    let temporaryName = ".bex-directory-\(UUID().uuidString).tmp"
    let directoryName = url.lastPathComponent
    guard mkdirat(parentDescriptor, temporaryName, 0o700) == 0 else {
      throw BexError.storageFailure(
        "Bex could not create the reviewed integration directory: \(url.path)"
      )
    }
    let descriptor = openat(
      parentDescriptor,
      temporaryName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    var metadata = stat()
    let prepared =
      descriptor >= 0
      && fchmod(descriptor, 0o700) == 0
      && fstat(descriptor, &metadata) == 0
      && metadata.st_mode & S_IFMT == S_IFDIR
      && fsync(descriptor) == 0
    if descriptor >= 0 { close(descriptor) }
    guard prepared else {
      unlinkat(parentDescriptor, temporaryName, AT_REMOVEDIR)
      throw BexError.storageFailure(
        "Bex could not prepare the reviewed integration directory: \(url.path)"
      )
    }
    let identity = PathIdentity(
      url: url,
      device: UInt64(metadata.st_dev),
      inode: UInt64(metadata.st_ino)
    )
    guard
      renameatx_np(
        parentDescriptor,
        temporaryName,
        parentDescriptor,
        directoryName,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      unlinkat(parentDescriptor, temporaryName, AT_REMOVEDIR)
      throw BexError.storageFailure(
        "Nothing changed because the reviewed integration directory appeared during Apply: \(url.path)"
      )
    }
    recordInstalled(identity)
    let installedDescriptor = openat(
      parentDescriptor,
      directoryName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    var installedMetadata = stat()
    let installedMatches =
      installedDescriptor >= 0
      && fstat(installedDescriptor, &installedMetadata) == 0
      && UInt64(installedMetadata.st_dev) == identity.device
      && UInt64(installedMetadata.st_ino) == identity.inode
    if installedDescriptor >= 0 { close(installedDescriptor) }
    guard installedMatches else {
      throw BexError.storageFailure(
        "The created integration directory changed unexpectedly and could not be safely removed during rollback: \(url.path)"
      )
    }
    _ = fsync(parentDescriptor)
  }

  private func safeRemoveDirectory(
    _ expected: PathIdentity,
    parentIdentity: PathIdentity
  ) throws {
    let parentDescriptor = try openVerifiedDirectory(parentIdentity)
    defer { close(parentDescriptor) }
    let directoryName = expected.url.lastPathComponent
    let displacedName = ".bex-directory-\(UUID().uuidString).tmp"
    guard
      renameatx_np(
        parentDescriptor,
        directoryName,
        parentDescriptor,
        displacedName,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      throw BexError.storageFailure("A created integration directory changed during rollback.")
    }
    let displacedDescriptor = openat(
      parentDescriptor,
      displacedName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW
    )
    var metadata = stat()
    let identityMatches =
      displacedDescriptor >= 0
      && fstat(displacedDescriptor, &metadata) == 0
      && UInt64(metadata.st_dev) == expected.device
      && UInt64(metadata.st_ino) == expected.inode
    if displacedDescriptor >= 0 { close(displacedDescriptor) }
    guard identityMatches else {
      guard
        renameatx_np(
          parentDescriptor,
          displacedName,
          parentDescriptor,
          directoryName,
          UInt32(RENAME_EXCL)
        ) == 0
      else {
        throw BexError.storageFailure(
          "Directory rollback failed and the displaced directory was retained."
        )
      }
      throw BexError.storageFailure("A created integration directory changed during rollback.")
    }
    guard unlinkat(parentDescriptor, displacedName, AT_REMOVEDIR) == 0 else {
      guard
        renameatx_np(
          parentDescriptor,
          displacedName,
          parentDescriptor,
          directoryName,
          UInt32(RENAME_EXCL)
        ) == 0
      else {
        throw BexError.storageFailure(
          "Directory rollback failed and the displaced directory was retained."
        )
      }
      throw BexError.storageFailure("Bex could not remove a created integration directory.")
    }
    _ = fsync(parentDescriptor)
  }

  private func safeRemove(
    _ url: URL,
    expected: Data,
    expectedIdentity: PathIdentity? = nil,
    expectedParentIdentity: PathIdentity? = nil
  ) throws {
    let directory = url.deletingLastPathComponent()
    let parentIdentity =
      try expectedParentIdentity
      ?? pathIdentity(at: directory, expectedDirectory: true)
    guard let parentIdentity else {
      throw BexError.storageFailure("The reviewed integration parent directory is unavailable.")
    }
    let directoryDescriptor = try openVerifiedDirectory(parentIdentity)
    defer { close(directoryDescriptor) }
    let targetName = url.lastPathComponent
    let displacedName = ".bex-remove-\(UUID().uuidString).tmp"
    guard
      renameatx_np(
        directoryDescriptor,
        targetName,
        directoryDescriptor,
        displacedName,
        UInt32(RENAME_EXCL)
      ) == 0
    else {
      throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
    }
    let displacedURL = directory.appendingPathComponent(displacedName)
    let displaced = try? readRelativeFile(
      directoryDescriptor: directoryDescriptor,
      name: displacedName,
      url: displacedURL
    )
    guard displaced?.data == expected,
      expectedIdentity == nil || identitiesMatch(displaced!.identity, expectedIdentity)
    else {
      guard
        renameatx_np(
          directoryDescriptor,
          displacedName,
          directoryDescriptor,
          targetName,
          UInt32(RENAME_EXCL)
        ) == 0
      else {
        throw BexError.storageFailure(
          "The hook configuration changed and rollback failed; the displaced file is retained at \(displacedURL.path)."
        )
      }
      throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
    }
    guard unlinkat(directoryDescriptor, displacedName, 0) == 0 else {
      throw BexError.storageFailure("Bex could not remove the reviewed integration artifact.")
    }
    _ = fsync(directoryDescriptor)
  }

  @discardableResult
  private func safeWrite(
    _ data: Data,
    to url: URL,
    expected: Data?,
    expectedIdentity: PathIdentity? = nil,
    expectedParentIdentity: PathIdentity? = nil,
    mode: mode_t = 0o600,
    requiresAbsentWhenExpectedNil: Bool = false,
    createParents: Bool = true
  ) throws -> PathIdentity {
    let directory = url.deletingLastPathComponent()
    if createParents {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let parentIdentity =
      try expectedParentIdentity
      ?? pathIdentity(at: directory, expectedDirectory: true)
    guard let parentIdentity else {
      throw BexError.storageFailure("The reviewed integration parent directory is unavailable.")
    }
    let directoryDescriptor = try openVerifiedDirectory(parentIdentity)
    defer { close(directoryDescriptor) }
    let targetName = url.lastPathComponent
    let temporaryName = ".bex-\(UUID().uuidString).tmp"
    let descriptor = openat(
      directoryDescriptor,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
      mode
    )
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
    var temporaryMetadata = stat()
    if fsync(descriptor) != 0 || fstat(descriptor, &temporaryMetadata) != 0 {
      failure = true
    }
    close(descriptor)
    guard !failure else {
      unlinkat(directoryDescriptor, temporaryName, 0)
      throw BexError.storageFailure("Bex could not write the hook configuration.")
    }
    let installedIdentity = PathIdentity(
      url: url,
      device: UInt64(temporaryMetadata.st_dev),
      inode: UInt64(temporaryMetadata.st_ino)
    )
    let temporaryURL = directory.appendingPathComponent(temporaryName)

    if let expected {
      guard
        renameatx_np(
          directoryDescriptor,
          temporaryName,
          directoryDescriptor,
          targetName,
          UInt32(RENAME_SWAP)
        ) == 0
      else {
        unlinkat(directoryDescriptor, temporaryName, 0)
        throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
      }
      let replaced = try? readRelativeFile(
        directoryDescriptor: directoryDescriptor,
        name: temporaryName,
        url: temporaryURL
      )
      guard replaced?.data == expected,
        expectedIdentity == nil || identitiesMatch(replaced!.identity, expectedIdentity)
      else {
        guard
          renameatx_np(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            targetName,
            UInt32(RENAME_SWAP)
          ) == 0
        else {
          throw BexError.storageFailure(
            "The hook configuration changed and rollback failed; the displaced file is retained at \(temporaryURL.path)."
          )
        }
        unlinkat(directoryDescriptor, temporaryName, 0)
        throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
      }
      unlinkat(directoryDescriptor, temporaryName, 0)
    } else if requiresAbsentWhenExpectedNil {
      guard
        renameatx_np(
          directoryDescriptor,
          temporaryName,
          directoryDescriptor,
          targetName,
          UInt32(RENAME_EXCL)
        ) == 0
      else {
        unlinkat(directoryDescriptor, temporaryName, 0)
        throw BexError.storageFailure("The hook configuration changed while Bex was editing it.")
      }
    } else if renameat(
      directoryDescriptor,
      temporaryName,
      directoryDescriptor,
      targetName
    ) != 0 {
      unlinkat(directoryDescriptor, temporaryName, 0)
      throw BexError.storageFailure("Bex could not write the hook configuration.")
    }

    let installedDescriptor = openat(directoryDescriptor, targetName, O_RDONLY | O_NOFOLLOW)
    guard installedDescriptor >= 0 else {
      throw BexError.storageFailure("Bex could not verify the installed integration artifact.")
    }
    var installedMetadata = stat()
    let installedMatches =
      fstat(installedDescriptor, &installedMetadata) == 0
      && UInt64(installedMetadata.st_dev) == installedIdentity.device
      && UInt64(installedMetadata.st_ino) == installedIdentity.inode
      && fchmod(installedDescriptor, mode) == 0
      && fsync(installedDescriptor) == 0
    close(installedDescriptor)
    guard installedMatches else {
      throw BexError.storageFailure("The installed integration artifact changed unexpectedly.")
    }
    _ = fsync(directoryDescriptor)
    return installedIdentity
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
