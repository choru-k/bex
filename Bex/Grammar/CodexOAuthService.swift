import CryptoKit
import Foundation
import Security

struct CodexOAuthFlow: Equatable, Sendable {
  let authorizationURL: URL
  let state: String
  let verifier: String
  let loopbackAvailable: Bool
}

/// The production listener uses Network.framework. Tests inject a synthetic listener so
/// lifecycle races can be exercised without opening a socket or contacting a provider.
protocol CodexOAuthListening: Sendable {
  func start() async throws
  func waitForCallback() async throws -> URL
  func stop() async
}

extension CodexLoopbackListener: CodexOAuthListening {}

enum CodexOAuthCompletionError: Error, Equatable, Sendable {
  case alreadyInProgress
}

actor CodexOAuthService {
  static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
  static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
  static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
  static let redirectURI = "http://localhost:1455/auth/callback"
  static let scope = "openid profile email offline_access"
  static let accountClaimKey = "https://api.openai.com/auth"

  private struct LoginAttempt {
    let id: UUID
    let token: KeychainStore.CodexOperationToken
    var flow: CodexOAuthFlow
    let listener: (any CodexOAuthListening)?
    var isCompleting = false
  }

  private let keychain: KeychainStore
  private let transport: any HTTPTransport
  private let timeout: TimeInterval
  private let makeListener: @Sendable () -> any CodexOAuthListening
  // Set before the first suspension, including while the shared login token is pending.
  private var currentAttemptID: UUID?
  private var activeAttempt: LoginAttempt?

  init(
    keychain: KeychainStore,
    transport: any HTTPTransport,
    timeout: TimeInterval = 30,
    makeListener: @escaping @Sendable () -> any CodexOAuthListening = {
      CodexLoopbackListener()
    }
  ) {
    self.keychain = keychain
    self.transport = transport
    self.timeout = timeout
    self.makeListener = makeListener
  }

  func begin() async throws -> CodexOAuthFlow {
    let previousListener = activeAttempt?.listener
    let id = UUID()
    currentAttemptID = id
    activeAttempt = nil
    // New login intent invalidates older login AND refresh work across service/store
    // instances before listener startup or network exchange. It holds no mutation gate.
    let token = await keychain.beginCodexLogin()
    await previousListener?.stop()
    do {
      try requireCurrentAttempt(id)
      let baseFlow = try Self.makeFlow(loopbackAvailable: false)
      let listener = makeListener()
      activeAttempt = LoginAttempt(id: id, token: token, flow: baseFlow, listener: listener)
      return try await withTaskCancellationHandler {
        do {
          try await listener.start()
        } catch {
          try requireCurrentAttempt(id)
          if error is CancellationError || (error as? BexError) == .cancellation {
            throw BexError.cancellation
          }
          // A busy callback port still supports the existing manual-paste flow.
          await listener.stop()
          try requireCurrentAttempt(id)
          activeAttempt = LoginAttempt(id: id, token: token, flow: baseFlow, listener: nil)
          return baseFlow
        }
        try requireCurrentAttempt(id)
        let flow = CodexOAuthFlow(
          authorizationURL: baseFlow.authorizationURL,
          state: baseFlow.state,
          verifier: baseFlow.verifier,
          loopbackAvailable: true
        )
        activeAttempt?.flow = flow
        return flow
      } onCancel: {
        Task { await self.cancelAttempt(id) }
      }
    } catch {
      await cancelAttempt(id)
      // begin may have been superseded before it could install its local attempt.
      // Conditional invalidation must never cancel a newer service instance's login.
      _ = await keychain.cancelCodexLogin(token)
      throw error
    }
  }

  func waitForLoopbackCompletion() async throws -> CodexSession {
    guard let attempt = activeAttempt, attempt.flow.loopbackAvailable,
      let listener = attempt.listener
    else {
      throw BexError.oauthFailure("OpenAI Codex callback is not listening.")
    }
    return try await withTaskCancellationHandler {
      let callbackURL = try await listener.waitForCallback()
      return try await finish(attemptID: attempt.id, callbackURL: callbackURL)
    } onCancel: {
      Task { await self.cancelAttempt(attempt.id) }
    }
  }

  func completeManual(callbackURL: String) async throws -> CodexSession {
    guard let attempt = activeAttempt else {
      throw BexError.oauthFailure("Start OpenAI Codex login again.")
    }
    guard let url = URL(string: callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw BexError.oauthFailure("Paste the complete OpenAI Codex callback URL.")
    }
    return try await withTaskCancellationHandler {
      try await finish(attemptID: attempt.id, callbackURL: url, stopListenerBeforeExchange: true)
    } onCancel: {
      Task { await self.cancelAttempt(attempt.id) }
    }
  }

  func cancel() async {
    guard let id = currentAttemptID else { return }
    await cancelAttempt(id)
  }

  /// A delayed UI cleanup must not cancel a newer login on this service.
  func cancel(flow: CodexOAuthFlow) async {
    guard let attempt = activeAttempt, attempt.flow.state == flow.state else { return }
    await cancelAttempt(attempt.id)
  }

  func disconnect() async throws {
    let listener = activeAttempt?.listener
    // Clear before the first await. A new begin while deletion drains must not be
    // cleared by this disconnect's eventual listener cleanup.
    currentAttemptID = nil
    activeAttempt = nil
    do {
      try await keychain.deleteCodexSession()
    } catch {
      await listener?.stop()
      throw error
    }
    await listener?.stop()
  }

  private func requireCurrentAttempt(_ id: UUID) throws {
    guard currentAttemptID == id, !Task.isCancelled else {
      throw BexError.cancellation
    }
  }

  private func cancelAttempt(_ id: UUID) async {
    guard currentAttemptID == id else { return }
    let attempt = activeAttempt
    currentAttemptID = nil
    activeAttempt = nil
    if let attempt {
      _ = await keychain.cancelCodexLogin(attempt.token)
      await attempt.listener?.stop()
    }
  }

  private func finish(
    attemptID id: UUID,
    callbackURL: URL,
    stopListenerBeforeExchange: Bool = false
  ) async throws -> CodexSession {
    try requireCurrentAttempt(id)
    guard let attempt = activeAttempt, attempt.id == id else {
      throw BexError.cancellation
    }
    guard !attempt.isCompleting else { throw CodexOAuthCompletionError.alreadyInProgress }
    // Waiting for loopback does not claim completion: manual paste must still work.
    // Claim only once a callback arrives so the two routes cannot exchange it twice.
    activeAttempt?.isCompleting = true
    var attemptedCommit = false
    do {
      // Validate before ending the loopback waiter so malformed manual paste leaves
      // the valid loopback route intact and can be retried without a new login.
      let code = try Self.authorizationCode(flow: attempt.flow, callbackURL: callbackURL)
      if stopListenerBeforeExchange {
        // Manual handover ends the loopback waiter without cancelling its Task (which
        // would invalidate this same login). The captured listener cannot be newer.
        await attempt.listener?.stop()
        try requireCurrentAttempt(id)
      }
      let session = try await exchangeAuthorizationCode(code: code, verifier: attempt.flow.verifier)
      try requireCurrentAttempt(id)
      // Stop the captured listener before the final commit, outside the mutation
      // gate. A disconnect in any service/store while shutdown suspends invalidates
      // this token, so it cannot persist or report a superseded login afterward.
      if !stopListenerBeforeExchange {
        await attempt.listener?.stop()
        try requireCurrentAttempt(id)
      }
      attemptedCommit = true
      guard try await keychain.saveCodexSession(session, ifCurrent: attempt.token) else {
        await cancelAttempt(id)
        throw BexError.cancellation
      }
      try requireCurrentAttempt(id)
      currentAttemptID = nil
      activeAttempt = nil
      return session
    } catch {
      if attemptedCommit || Task.isCancelled || (error as? BexError) == .cancellation {
        await cancelAttempt(id)
      } else if currentAttemptID == id {
        // Preserve the existing retryable manual flow after malformed/network errors.
        activeAttempt?.isCompleting = false
      }
      throw error
    }
  }

  /// Exchange-only helper. Persisting a login must go through finish's shared-store CAS.
  func complete(flow: CodexOAuthFlow, callbackURL: URL) async throws -> CodexSession {
    let code = try Self.authorizationCode(flow: flow, callbackURL: callbackURL)
    return try await exchangeAuthorizationCode(code: code, verifier: flow.verifier)
  }

  private static func authorizationCode(flow: CodexOAuthFlow, callbackURL: URL) throws -> String {
    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
      throw BexError.oauthFailure("Paste the complete OpenAI Codex callback URL.")
    }
    // The callback is untrusted. Duplicate keys must fail closed rather than trap in
    // Dictionary(uniqueKeysWithValues:) or let different parsers choose different values.
    var query: [String: String] = [:]
    for item in components.queryItems ?? [] {
      guard query.updateValue(item.value ?? "", forKey: item.name) == nil else {
        throw BexError.oauthFailure("OpenAI Codex callback contains duplicate parameters.")
      }
    }
    if query["error"] != nil {
      throw BexError.oauthFailure("OpenAI Codex login was not completed.")
    }
    guard let returnedState = query["state"], returnedState == flow.state else {
      throw BexError.oauthFailure("State mismatch while completing Codex login.")
    }
    guard let code = query["code"], !code.isEmpty else {
      throw BexError.oauthFailure("Missing authorization code.")
    }
    return code
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
