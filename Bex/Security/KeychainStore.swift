import Foundation
import Security

actor KeychainStore {
  private enum Account {
    static let openAI = "openai.apiKey"
    static let openAICodex = "openaiCodex.session"
    static let claude = "claude.apiKey"
    static let gemini = "gemini.apiKey"
  }

  private let service: String
  private let inMemory: Bool
  private var memory: [String: Data] = [:]

  init(
    service: String = "com.bex.desktop.credentials",
    inMemory: Bool = false
  ) {
    self.service = service
    self.inMemory = inMemory
  }

  func apiKey(for provider: LLMProvider) throws -> String? {
    guard let account = apiKeyAccount(for: provider) else { return nil }
    guard let data = try read(account: account) else { return nil }
    guard let value = String(data: data, encoding: .utf8) else {
      throw BexError.storageFailure("Bex could not read the stored credential.")
    }
    return value
  }

  func saveAPIKey(_ apiKey: String, for provider: LLMProvider) throws {
    guard let account = apiKeyAccount(for: provider) else {
      throw BexError.missingSetup(provider)
    }
    try write(Data(apiKey.utf8), account: account)
  }

  func deleteAPIKey(for provider: LLMProvider) throws {
    guard let account = apiKeyAccount(for: provider) else { return }
    try delete(account: account)
  }

  func codexSession() throws -> CodexSession? {
    guard let data = try read(account: Account.openAICodex) else { return nil }
    do {
      return try JSONDecoder().decode(CodexSession.self, from: data)
    } catch {
      throw BexError.storageFailure("Bex could not read the stored OpenAI Codex session.")
    }
  }

  func saveCodexSession(_ session: CodexSession) throws {
    do {
      let data = try JSONEncoder().encode(session)
      try write(data, account: Account.openAICodex)
    } catch let error as BexError {
      throw error
    } catch {
      throw BexError.storageFailure("Bex could not save the OpenAI Codex session.")
    }
  }

  func deleteCodexSession() throws {
    try delete(account: Account.openAICodex)
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

  private func query(account: String) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }

  private func read(account: String) throws -> Data? {
    if inMemory {
      return memory[account]
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

  private func write(_ data: Data, account: String) throws {
    if inMemory {
      memory[account] = data
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

  private func delete(account: String) throws {
    if inMemory {
      memory.removeValue(forKey: account)
      return
    }
    let status = SecItemDelete(query(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw BexError.storageFailure("Bex could not remove the credential from Keychain.")
    }
  }
}
