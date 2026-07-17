import CryptoKit
import Foundation
import Security

struct CodexOAuthFlow: Equatable, Sendable {
  let authorizationURL: URL
  let state: String
  let verifier: String
  let loopbackAvailable: Bool
}

actor CodexOAuthService {
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
  static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
  static let redirectURI = "http://localhost:1455/auth/callback"
  static let scope = "openid profile email offline_access"
  static let accountClaimKey = "https://api.openai.com/auth"

  private let keychain: KeychainStore
  private let transport: any HTTPTransport
  private let timeout: TimeInterval
  private var activeFlow: CodexOAuthFlow?
  private var listener: CodexLoopbackListener?

  init(keychain: KeychainStore, transport: any HTTPTransport, timeout: TimeInterval = 30) {
    self.keychain = keychain
    self.transport = transport
    self.timeout = timeout
  }

  func begin() async throws -> CodexOAuthFlow {
    if let listener {
      await listener.stop()
    }
    let listener = CodexLoopbackListener()
    let baseFlow = try Self.makeFlow(loopbackAvailable: false)
    do {
      try await listener.start()
      let flow = CodexOAuthFlow(
        authorizationURL: baseFlow.authorizationURL,
        state: baseFlow.state,
        verifier: baseFlow.verifier,
        loopbackAvailable: true
      )
      self.listener = listener
      activeFlow = flow
      return flow
    } catch BexError.cancellation {
      throw BexError.cancellation
    } catch {
      self.listener = nil
      activeFlow = baseFlow
      return baseFlow
    }
  }

  func waitForLoopbackCompletion() async throws -> CodexSession {
    guard let activeFlow, activeFlow.loopbackAvailable, let listener else {
      throw BexError.oauthFailure("OpenAI Codex callback is not listening.")
    }
    let callbackURL = try await listener.waitForCallback()
    let session = try await complete(flow: activeFlow, callbackURL: callbackURL)
    try await keychain.saveCodexSession(session)
    self.activeFlow = nil
    self.listener = nil
    return session
  }

  func completeManual(callbackURL: String) async throws -> CodexSession {
    guard let activeFlow else {
      throw BexError.oauthFailure("Start OpenAI Codex login again.")
    }
    guard let url = URL(string: callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw BexError.oauthFailure("Paste the complete OpenAI Codex callback URL.")
    }
    let session = try await complete(flow: activeFlow, callbackURL: url)
    try await keychain.saveCodexSession(session)
    self.activeFlow = nil
    self.listener = nil
    return session
  }

  func cancel() async {
    await listener?.stop()
    listener = nil
    activeFlow = nil
  }

  func disconnect() async throws {
    await cancel()
    try await keychain.deleteCodexSession()
  }

  func complete(flow: CodexOAuthFlow, callbackURL: URL) async throws -> CodexSession {
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
      throw BexError.oauthFailure("Paste the complete OpenAI Codex callback URL.")
    }
    let query = Dictionary(
      uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    if query["error"] != nil {
      throw BexError.oauthFailure("OpenAI Codex login was not completed.")
    }
    guard let returnedState = query["state"], returnedState == flow.state else {
      throw BexError.oauthFailure("State mismatch while completing Codex login.")
    }
    guard let code = query["code"], !code.isEmpty else {
      throw BexError.oauthFailure("Missing authorization code.")
    }
    return try await exchangeAuthorizationCode(code: code, verifier: flow.verifier)
  }

  static func makeFlow(loopbackAvailable: Bool) throws -> CodexOAuthFlow {
    let verifier = base64URL(try randomBytes(count: 32))
    let challenge = pkceChallenge(for: verifier)
    let state = try randomBytes(count: 16).map { String(format: "%02x", $0) }.joined()
    var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "scope", value: scope),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "id_token_add_organizations", value: "true"),
      URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
      URLQueryItem(name: "originator", value: "bex"),
    ]
    guard let url = components.url else {
      throw BexError.oauthFailure("Bex could not start OpenAI Codex login.")
    }
    return CodexOAuthFlow(
      authorizationURL: url,
      state: state,
      verifier: verifier,
      loopbackAvailable: loopbackAvailable
    )
  }

  static func pkceChallenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func refresh(
    session: CodexSession,
    transport: any HTTPTransport,
    timeout: TimeInterval = 30
  ) async throws -> CodexSession {
    let request = ProviderRequest.form(
      url: tokenURL,
      values: [
        ("grant_type", "refresh_token"),
        ("refresh_token", session.refreshToken),
        ("client_id", clientID),
      ],
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .openAICodex
    )
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw BexError.unauthorized(.openAICodex)
      }
      if response.statusCode == 429 { throw BexError.rateLimited }
      throw BexError.providerHTTPStatus(response.statusCode)
    }
    return try tokenSession(from: data, incompleteMessage: "Codex refresh response was incomplete.")
  }

  private func exchangeAuthorizationCode(code: String, verifier: String) async throws
    -> CodexSession
  {
    let request = ProviderRequest.form(
      url: Self.tokenURL,
      values: [
        ("grant_type", "authorization_code"),
        ("client_id", Self.clientID),
        ("code", code),
        ("code_verifier", verifier),
        ("redirect_uri", Self.redirectURI),
      ],
      timeout: timeout
    )
    let (data, response) = try await ProviderResponse.data(
      for: request,
      transport: transport,
      provider: .openAICodex
    )
    guard (200..<300).contains(response.statusCode) else {
      if response.statusCode == 401 || response.statusCode == 403 {
        throw BexError.unauthorized(.openAICodex)
      }
      if response.statusCode == 429 { throw BexError.rateLimited }
      throw BexError.providerHTTPStatus(response.statusCode)
    }
    return try Self.tokenSession(
      from: data,
      incompleteMessage: "Codex OAuth token response was incomplete."
    )
  }

  private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?

    enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case refreshToken = "refresh_token"
      case expiresIn = "expires_in"
    }
  }

  private static func tokenSession(from data: Data, incompleteMessage: String) throws
    -> CodexSession
  {
    guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data),
      let accessToken = response.accessToken,
      !accessToken.isEmpty,
      let refreshToken = response.refreshToken,
      !refreshToken.isEmpty,
      let expiresIn = response.expiresIn
    else {
      throw BexError.oauthFailure(incompleteMessage)
    }
    return CodexSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: Date().addingTimeInterval(expiresIn),
      accountID: try extractAccountID(from: accessToken)
    )
  }

  static func extractAccountID(from accessToken: String) throws -> String {
    let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let payload = base64URLDecode(String(parts[1])),
      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
      let auth = object[accountClaimKey] as? [String: Any],
      let accountID = auth["chatgpt_account_id"] as? String,
      !accountID.isEmpty
    else {
      throw BexError.oauthFailure("Failed to extract ChatGPT account ID from token.")
    }
    return accountID
  }

  private static func randomBytes(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw BexError.oauthFailure("Bex could not create a secure OpenAI Codex login.")
    }
    return data
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func base64URLDecode(_ value: String) -> Data? {
    var normalized =
      value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
    return Data(base64Encoded: normalized)
  }
}
