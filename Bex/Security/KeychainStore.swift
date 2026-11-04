import Foundation
import Security

actor KeychainStore {
  private enum Account {
    static let openAI = "openai.apiKey"
    static let openAICodex = "openaiCodex.session"
    static let claude = "claude.apiKey"
    static let gemini = "gemini.apiKey"
  }

  typealias CodexOperationToken = AccountMutationCoordinator.CredentialOperationToken

  struct CodexSessionSnapshot: Sendable {
    let session: CodexSession
    let token: CodexOperationToken
  }

  private let service: String
  private let backing: KeychainBacking
  private let coordinator = AccountMutationCoordinator.shared

  init(
    service: String? = nil,
    inMemory: Bool = false
  ) {
    // Explicit equal service names share the synthetic domain. Omitted service
    // preserves isolated no-host fixtures without changing the real default.
    let service = service ?? (inMemory ? "bex.memory.\(UUID().uuidString)" : "com.bex.desktop.credentials")
    self.service = service
    self.backing = KeychainBacking(service: service, inMemory: inMemory)
  }

  func apiKey(for provider: LLMProvider) throws -> String? {
    guard let account = apiKeyAccount(for: provider) else { return nil }
    guard let data = try backing.read(account: account) else { return nil }
    guard let value = String(data: data, encoding: .utf8) else {
      throw BexError.storageFailure("Bex could not read the stored credential.")
    }
    return value
  }

  func saveAPIKey(_ apiKey: String, for provider: LLMProvider) async throws {
    guard let account = apiKeyAccount(for: provider) else {
      throw BexError.missingSetup(provider)
    }
    try await coordinator.replaceCredential(domain: service) { [backing] in
      try backing.write(Data(apiKey.utf8), account: account)
    }
  }

  func deleteAPIKey(for provider: LLMProvider) async throws {
    guard let account = apiKeyAccount(for: provider) else { return }
    try await coordinator.replaceCredential(domain: service) { [backing] in
      try backing.delete(account: account)
    }
  }

  // Reads intentionally do not acquire the mutation barrier. Draining work may
  // need to read credentials to finish; making it wait for its own drain deadlocks.
  func codexSession() throws -> CodexSession? {
    try Self.decodeSession(backing.read(account: Account.openAICodex))
  }

  func codexSessionSnapshot() async throws -> CodexSessionSnapshot? {
    let snapshot = try await coordinator.credentialSnapshot(domain: service) { [backing] in
      try Self.decodeSession(backing.read(account: Account.openAICodex))
    }
    guard let snapshot else { return nil }
    return CodexSessionSnapshot(session: snapshot.value, token: snapshot.token)
  }

  func beginCodexLogin() async -> CodexOperationToken {
    await coordinator.beginCredentialOperation(domain: service)
  }

  @discardableResult
  func cancelCodexLogin(_ token: CodexOperationToken) async -> Bool {
    await coordinator.cancelCredentialOperation(token, domain: service)
  }

  func invalidateCodexOperations() async {
    await coordinator.invalidateCredentialOperations(domain: service)
  }

  func saveCodexSession(_ session: CodexSession) async throws {
    try await coordinator.replaceCredential(domain: service) { [backing] in
      try backing.write(Self.encodeSession(session), account: Account.openAICodex)
    }
  }

  /// A network completion must use this overload, never the unconditional setter.
  @discardableResult
  func saveCodexSession(
    _ session: CodexSession,
    ifCurrent token: CodexOperationToken
  ) async throws -> Bool {
    try await coordinator.commitCredential(domain: service, token: token) { [backing] in
      try backing.write(Self.encodeSession(session), account: Account.openAICodex)
    }
  }

  func deleteCodexSession() async throws {
    try await coordinator.replaceCredential(domain: service) { [backing] in
      try backing.delete(account: Account.openAICodex)
    }
  }

  func hasSetup(for provider: LLMProvider) throws -> Bool {
    switch provider {
    case .openAICodex:
      return try codexSession() != nil
    case .ollama:
      return true
    default:
      return try apiKey(for: provider).map { !$0.isEmpty } ?? false
    }
  }

  private func apiKeyAccount(for provider: LLMProvider) -> String? {
    switch provider {
    case .openAI: Account.openAI
    case .claude: Account.claude
    case .gemini: Account.gemini
    case .openAICodex, .ollama: nil
    }
  }

  private nonisolated static func decodeSession(_ data: Data?) throws -> CodexSession? {
    guard let data else { return nil }
    do { return try JSONDecoder().decode(CodexSession.self, from: data) }
    catch { throw BexError.storageFailure("Bex could not read the stored OpenAI Codex session.") }
  }

  private nonisolated static func encodeSession(_ session: CodexSession) throws -> Data {
    do { return try JSONEncoder().encode(session) }
    catch { throw BexError.storageFailure("Bex could not save the OpenAI Codex session.") }
  }
}

/// Security framework operations are synchronous/thread-safe. Instance fields
/// are immutable; the synthetic backing dictionary is protected by its own lock.
/// No lock is held across an await, and no actor-isolation cast is used.
private final class KeychainBacking: @unchecked Sendable {
  private let service: String
  private let inMemory: Bool
  private static let memory = KeychainMemoryBacking()

  init(service: String, inMemory: Bool) {
    self.service = service
    self.inMemory = inMemory
  }

  private func query(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  func read(account: String) throws -> Data? {
    if inMemory {
      return Self.memory.read(service: service, account: account)
    }
    var query = query(account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else {
        throw BexError.storageFailure("Bex could not read the stored credential.")
      }
      return data
    case errSecItemNotFound:
      return nil
    default:
      throw BexError.storageFailure("Bex could not access the Keychain.")
    }
  }

  func write(_ data: Data, account: String) throws {
    if inMemory {
      Self.memory.write(data, service: service, account: account)
      return
    }
    let query = query(account: account)
    let update: [CFString: Any] = [kSecValueData: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw BexError.storageFailure("Bex could not save the credential in Keychain.")
    }

    var item = query
    item[kSecValueData] = data
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw BexError.storageFailure("Bex could not save the credential in Keychain.")
    }
  }

  func delete(account: String) throws {
    if inMemory {
      Self.memory.delete(service: service, account: account)
      return
    }
    let status = SecItemDelete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw BexError.storageFailure("Bex could not remove the credential from Keychain.")
    }
  }
}

/// Shared by service, just like real Keychain storage. Tests must use a fresh
/// service name when they want isolation; separate store instances are not a
/// separate backing domain. The lock covers every dictionary access.
private final class KeychainMemoryBacking: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: [String: Data]] = [:]

  func read(service: String, account: String) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return values[service]?[account]
  }

  func write(_ data: Data, service: String, account: String) {
    lock.lock()
    defer { lock.unlock() }
    values[service, default: [:]][account] = data
  }

  func delete(service: String, account: String) {
    lock.lock()
    defer { lock.unlock() }
    values[service]?[account] = nil
    if values[service]?.isEmpty == true { values[service] = nil }
  }
}
