import Foundation

/// Dedicated to the inactive packaged host. Never changes URLSessionTransport or
/// the existing app's factory. One immutable recipient and one session per host.
final class NativeProviderTransport: HTTPTransport, @unchecked Sendable {
  enum Failure: Error { case invalidDestination, refusedRequest, refusedResponse }

  private let recipient: NativeProviderRecipient
  private let lifecycle = NativeProviderAdmission()
  private let delegate: NativeProviderSessionDelegate
  private let session: URLSession

  init(destination: OutboundDestination) throws {
    recipient = try NativeProviderRecipient(destination: destination)
    let delegate = NativeProviderSessionDelegate()
    self.delegate = delegate
    session = URLSession(configuration: Self.isolatedConfiguration(),
      delegate: delegate, delegateQueue: nil)
  }

  // Returns a NEW configuration. Neither callers nor the host can supply a session,
  // transport, credential store, cache, or custom URLProtocol to this initializer.
  static func isolatedConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = [:]
    configuration.protocolClasses = []
    configuration.waitsForConnectivity = false
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForResource = 60
    return configuration
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    let request = try recipient.prepare(request)
    let cancellation = NativeProviderTaskCancellation()
    let recipient = self.recipient
    let lifecycle = self.lifecycle
    let result: (Data, HTTPURLResponse) = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Construct AND resume under the admission lock. close() cannot invalidate
        // the session between checking admission and constructing a task.
        let admitted = lifecycle.admit {
          let task = session.dataTask(with: request) { data, response, error in
            defer { lifecycle.complete() }
            let wasCancelled = cancellation.complete()
            if wasCancelled || (error as? URLError)?.code == .cancelled {
              continuation.resume(throwing: CancellationError())
            } else if let error {
              continuation.resume(throwing: error)
            } else {
              do {
                let response = try recipient.validate(response)
                guard let data else { throw Failure.refusedResponse }
                continuation.resume(returning: (data, response))
              } catch {
                continuation.resume(throwing: error)
              }
            }
          }
          cancellation.install { task.cancel() }
          task.resume()
        }
        if !admitted { continuation.resume(throwing: CancellationError()) }
      }
    } onCancel: {
      // Never resume the continuation here: the caller remains outstanding until
      // URLSession reports actual task completion, including a cancelled task.
      cancellation.cancel()
    }
    try Task.checkCancellation()
    guard !lifecycle.isClosed else { throw CancellationError() }
    return result
  }

  /// Revokes task admission synchronously, then asks URLSession to stop its tasks.
  func close() {
    if lifecycle.close() { session.invalidateAndCancel() }
  }

  /// The host separately awaits its coordinator. This also waits for the session's
  /// task completion handlers and invalidation callback, not just cancellation.
  /// Invalidation alone does not prove task completion after invalidateAndCancel.
  func closeAndWait() async {
    close()
    await lifecycle.waitForTasks()
    await delegate.waitForInvalidation()
  }

  // URLSession retains its delegate, which deliberately has NO session/owner link.
  // Dropping an unclosed host cannot leave a session -> transport -> session cycle.
  deinit { session.invalidateAndCancel() }
}

/// Immutable URL policy derived only from trusted native configuration. Not a host
/// prefix allowlist: every request and response must match one exact absolute URL.
struct NativeProviderRecipient: Sendable {
  let url: URL

  init(destination: OutboundDestination) throws {
    let endpoint: String
    switch destination.provider {
    case .openAI:
      endpoint = "https://api.openai.com/v1/chat/completions"
    case .claude:
      endpoint = "https://api.anthropic.com/v1/messages"
    case .gemini:
      // The existing client interpolates this into a path. Do not allow model
      // names to create a query, fragment, another path, or encoded path syntax.
      let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
      guard !destination.model.isEmpty, destination.model.utf8.count <= 200,
        destination.model != ".", destination.model != "..",
        destination.model.unicodeScalars.allSatisfy({ allowed.contains($0) })
      else { throw NativeProviderTransport.Failure.invalidDestination }
      endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(destination.model):generateContent"
    case .ollama:
      guard let base = destination.ollamaEndpoint else {
        throw NativeProviderTransport.Failure.invalidDestination
      }
      endpoint = "\(base)/api/chat"
    case .openAICodex:
      throw NativeProviderTransport.Failure.invalidDestination
    }
    guard let components = URLComponents(string: endpoint),
      components.scheme == "https" || components.scheme == "http",
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.port.map({ (1...65535).contains($0) }) ?? true,
      let url = components.url, url.absoluteString == endpoint,
      Self.unambiguousPath(components.percentEncodedPath)
    else { throw NativeProviderTransport.Failure.invalidDestination }
    self.url = url
  }

  private static func unambiguousPath(_ path: String) -> Bool {
    // Reject dot-segment aliases and encoded separators even for native-configured
    // Ollama bases. Disclosing a path does not authorize URL parser normalization.
    path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
      guard let decoded = String(part).removingPercentEncoding,
        decoded != ".", decoded != "..", !decoded.contains("/"),
        !decoded.contains("\\"), !decoded.contains("%"),
        !decoded.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
      else { return false }
      return true
    }
  }

  func matches(_ candidate: URL?) -> Bool {
    candidate?.baseURL == nil && candidate?.absoluteString == url.absoluteString
  }

  func prepare(_ original: URLRequest) throws -> URLRequest {
    let forbiddenHeaders: Set<String> = ["cookie", "cookie2", "host",
      "proxy-authorization", "proxy-connection"]
    guard matches(original.url), original.httpMethod == "POST",
      original.httpBody != nil, original.httpBodyStream == nil,
      !(original.allHTTPHeaderFields ?? [:]).keys.contains(where: {
        forbiddenHeaders.contains($0.lowercased())
      })
    else { throw NativeProviderTransport.Failure.refusedRequest }
    var request = original
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.mainDocumentURL = nil
    return request
  }

  func validate(_ response: URLResponse?) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse,
      matches(response.url), !(300..<400).contains(response.statusCode)
    else { throw NativeProviderTransport.Failure.refusedResponse }
    return response
  }
}

/// Both request construction and close use this lock. No async work runs in it.
final class NativeProviderAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var closed = false
  private var outstanding = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var isClosed: Bool { lock.withLock { closed } }

  func admit(_ start: () -> Void) -> Bool {
    lock.withLock {
      guard !closed else { return false }
      outstanding += 1
      start()
      return true
    }
  }

  func close() -> Bool {
    lock.withLock {
      guard !closed else { return false }
      closed = true
      return true
    }
  }

  func complete() {
    let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      precondition(outstanding > 0)
      outstanding -= 1
      guard outstanding == 0 else { return [] }
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    pending.forEach { $0.resume() }
  }

  func waitForTasks() async {
    await withCheckedContinuation { _ = registerTaskWaiter($0) }
  }

  // Synchronous registration also permits deterministic state-machine tests.
  @discardableResult
  func registerTaskWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
    let alreadyFinished = lock.withLock {
      precondition(closed)
      if outstanding == 0 { return true }
      waiters.append(continuation)
      return false
    }
    if alreadyFinished { continuation.resume() }
    return !alreadyFinished
  }
}

/// Handles cancellation arriving before task assignment and breaks the temporary
/// task/completion/slot cycle only when completion actually runs. Cancellation does
/// not call any continuation. All mutable state is protected by this lock.
final class NativeProviderTaskCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var completed = false
  private var cancelTask: (@Sendable () -> Void)?

  func install(_ cancel: @escaping @Sendable () -> Void) {
    let shouldCancel = lock.withLock {
      precondition(cancelTask == nil && !completed)
      cancelTask = cancel
      return cancelled
    }
    if shouldCancel { cancel() }
  }

  func cancel() {
    let action = lock.withLock { () -> (@Sendable () -> Void)? in
      guard !cancelled, !completed else { return nil }
      cancelled = true
      return cancelTask
    }
    action?()
  }

  func complete() -> Bool {
    lock.withLock {
      completed = true
      cancelTask = nil
      return cancelled
    }
  }
}

/// Not the transport itself: URLSession can retain this delegate through its final
/// callback without retaining the session or host. Lock protects invalidation state.
final class NativeProviderSessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable {
  private let lock = NSLock()
  private var invalidated = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    // Refuse every redirect, including same-host/path and POST-preserving 307/308.
    completionHandler(nil)
  }

  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @Sendable
                    (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    Self.resolve(challenge, completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @Sendable
                    (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    Self.resolve(challenge, completionHandler: completionHandler)
  }

  private static func resolve(_ challenge: URLAuthenticationChallenge,
                              completionHandler: @escaping @Sendable
                                (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // Keep normal TLS trust evaluation. Never accept a trust bypass or ambient
    // password/client-certificate/proxy credential challenge, even if proposed.
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      invalidated = true
      let pending = waiters
      waiters.removeAll()
      return pending
    }
    pending.forEach { $0.resume() }
  }

  func waitForInvalidation() async {
    await withCheckedContinuation { _ = registerInvalidationWaiter($0) }
  }

  @discardableResult
  func registerInvalidationWaiter(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
    let alreadyInvalidated = lock.withLock {
      if invalidated { return true }
      waiters.append(continuation)
      return false
    }
    if alreadyInvalidated { continuation.resume() }
    return !alreadyInvalidated
  }
}
