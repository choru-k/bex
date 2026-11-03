import Foundation

/// Dedicated to the inactive packaged host. Never changes URLSessionTransport or
/// the existing app's factory. One immutable recipient and one session per host.
final class NativeProviderTransport: HTTPTransport, @unchecked Sendable {
  enum Failure: Error, Equatable {
    case invalidDestination, refusedRequest, refusedResponse, responseTooLarge
  }

  // Cap the provider envelope, not only the extracted structured JSON (128,000
  // UTF-8 bytes). One level of JSON string escaping can expand it by up to 6x;
  // 1 MiB leaves space for that plus bounded provider metadata. This is a strict
  // retained-body bound, not a bound on Foundation's buffers or delivered chunks.
  static let maximumResponseBytes = 1_048_576

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
          let task = session.dataTask(with: request)
          let response = NativeProviderResponseState(recipient: recipient,
            cancellation: cancellation) { result in
              defer { lifecycle.complete() }
              continuation.resume(with: result)
            }
          delegate.register(response, for: task.taskIdentifier)
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
  /// terminal task callbacks and invalidation callback, not just cancellation.
  /// Invalidation alone does not prove task completion after invalidateAndCancel.
  func closeAndWait() async {
    close()
    await lifecycle.waitForTasks()
    await delegate.waitForInvalidation()
  }

  // URLSession retains its delegate, which deliberately has NO transport/owner link.
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
/// task/response-state/slot cycle only when completion actually runs. Cancellation does
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

/// One bounded body and one terminal callback per admitted task. Header hints are
/// only an early-rejection optimization; every delivered (possibly decompressed)
/// chunk is checked before append. No capacity is allocated from Content-Length.
/// Its separate lock also makes late/concurrent synthetic callbacks safe.
final class NativeProviderResponseState: @unchecked Sendable {
  enum ChunkDisposition: Equatable { case accepted, cancel, discard }
  typealias Completion = @Sendable (Result<(Data, HTTPURLResponse), Error>) -> Void

  private let lock = NSLock()
  private let recipient: NativeProviderRecipient
  private let cancellation: NativeProviderTaskCancellation
  private let maximumBytes: Int
  private var body = Data()
  private var response: HTTPURLResponse?
  private var failure: NativeProviderTransport.Failure?
  private var completion: Completion?

  init(recipient: NativeProviderRecipient, cancellation: NativeProviderTaskCancellation,
       maximumBytes: Int = NativeProviderTransport.maximumResponseBytes,
       completion: @escaping Completion) {
    precondition(maximumBytes > 0 && maximumBytes <= NativeProviderTransport.maximumResponseBytes)
    self.recipient = recipient
    self.cancellation = cancellation
    self.maximumBytes = maximumBytes
    self.completion = completion
  }

  // Internal observation seam for deterministic bounded-retention tests.
  var bufferedByteCount: Int { lock.withLock { body.count } }

  func receive(_ incoming: URLResponse) -> URLSession.ResponseDisposition {
    lock.withLock {
      guard completion != nil, failure == nil else { return .cancel }
      guard response == nil else { return reject(.refusedResponse) }
      do {
        let accepted = try recipient.validate(incoming)
        guard accepted.expectedContentLength <= Int64(maximumBytes) else {
          return reject(.responseTooLarge)
        }
        if let raw = accepted.value(forHTTPHeaderField: "Content-Length") {
          // Parse with a cap-aware decimal comparison, including values too large
          // for Int64. Malformed or conflicting/coalesced lengths fail closed.
          let digits = raw.trimmingCharacters(in: .whitespaces).utf8
          guard !digits.isEmpty,
            digits.allSatisfy({ $0 >= 48 && $0 <= 57 })
          else { return reject(.refusedResponse) }
          var length = 0
          for byte in digits {
            let digit = Int(byte - 48)
            guard length < maximumBytes / 10 ||
              (length == maximumBytes / 10 && digit <= maximumBytes % 10)
            else { return reject(.responseTooLarge) }
            length = length * 10 + digit
          }
        }
        response = accepted
        return .allow
      } catch {
        return reject(.refusedResponse)
      }
    }
  }

  func receive(_ chunk: Data) -> ChunkDisposition {
    lock.withLock {
      guard completion != nil, failure == nil else { return .discard }
      guard response != nil else { _ = reject(.refusedResponse); return .cancel }
      // Subtraction avoids count + chunk.count overflow. Never append a prefix
      // of an oversized chunk or reserve capacity based on an untrusted length.
      guard chunk.count <= maximumBytes - body.count else {
        _ = reject(.responseTooLarge)
        return .cancel
      }
      body.append(chunk)
      return .accepted
    }
  }

  // Called only while holding lock. Release already-buffered bytes immediately;
  // leave the completion/cancellation slot alive until didCompleteWithError.
  private func reject(_ error: NativeProviderTransport.Failure) -> URLSession.ResponseDisposition {
    failure = error
    body = Data()
    response = nil
    return .cancel
  }

  func complete(error: Error?) {
    let finished = lock.withLock { () -> (Completion, Result<(Data, HTTPURLResponse), Error>)? in
      guard let completion else { return nil }
      let wasCancelled = cancellation.complete()
      let result: Result<(Data, HTTPURLResponse), Error>
      if wasCancelled {
        result = .failure(CancellationError())
      } else if let failure {
        // The rejection caused URLSession's cancellation; preserve its fixed
        // reason instead of relabeling an oversized response as user cancel.
        result = .failure(failure)
      } else if (error as? URLError)?.code == .cancelled {
        result = .failure(CancellationError())
      } else if let error {
        result = .failure(error)
      } else if let response {
        result = .success((body, response))
      } else {
        result = .failure(NativeProviderTransport.Failure.refusedResponse)
      }
      self.completion = nil
      body = Data()
      response = nil
      return (completion, result)
    }
    if let (completion, result) = finished { completion(result) }
  }
}

/// Not the transport itself: URLSession can retain this delegate through its final
/// callback without retaining the transport or host. Pending states retain tasks
/// only until their terminal callbacks; the lock protects registry/invalidation.
final class NativeProviderSessionDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable {
  private let lock = NSLock()
  private var invalidated = false
  private var responses: [Int: NativeProviderResponseState] = [:]
  private var waiters: [CheckedContinuation<Void, Never>] = []

  // Registration occurs under admission before task.resume(), so no response
  // callback can arrive without its state. Unknown/late callbacks fail closed.
  func register(_ response: NativeProviderResponseState, for taskIdentifier: Int) {
    lock.withLock {
      precondition(!invalidated && responses[taskIdentifier] == nil)
      responses[taskIdentifier] = response
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable
                    (URLSession.ResponseDisposition) -> Void) {
    let pending = lock.withLock { responses[dataTask.taskIdentifier] }
    completionHandler(pending?.receive(response) ?? .cancel)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive data: Data) {
    let pending = lock.withLock { responses[dataTask.taskIdentifier] }
    guard let pending else { dataTask.cancel(); return }
    if pending.receive(data) == .cancel { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didCompleteWithError error: Error?) {
    let pending = lock.withLock { responses.removeValue(forKey: task.taskIdentifier) }
    // Removing the entry and completing its cancellation slot releases the task
    // capture before the admission count is decremented by its completion closure.
    pending?.complete(error: error)
  }

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
