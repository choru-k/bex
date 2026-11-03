import XCTest
@testable import Bex

private final class TransportTestCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private final class TransportTestWeakReference<Value: AnyObject>: @unchecked Sendable {
  private let lock = NSLock()
  private weak var stored: Value?
  var value: Value? { lock.withLock { stored } }
  init(_ value: Value) { stored = value }
}

private final class TransportTestOutcome: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<(Data, HTTPURLResponse), Error>?
  private var count = 0
  var result: Result<(Data, HTTPURLResponse), Error>? { lock.withLock { stored } }
  var completionCount: Int { lock.withLock { count } }
  func record(_ result: Result<(Data, HTTPURLResponse), Error>) {
    lock.withLock { stored = result; count += 1 }
  }
}

private func transportResponse(headers: [String: String]? = nil, status: Int = 200,
                               url: URL? = nil) throws -> HTTPURLResponse {
  let recipient = try NativeProviderRecipient(destination: transportDestination())
  return try XCTUnwrap(HTTPURLResponse(url: url ?? recipient.url, statusCode: status,
    httpVersion: nil, headerFields: headers))
}

private func transportResponseState(outcome: TransportTestOutcome, maximumBytes: Int = 8,
                                    cancellation: NativeProviderTaskCancellation = .init())
  throws -> NativeProviderResponseState {
  NativeProviderResponseState(recipient: try NativeProviderRecipient(destination:
    transportDestination()), cancellation: cancellation, maximumBytes: maximumBytes) {
      outcome.record($0)
    }
}

private func transportDestination(_ provider: LLMProvider = .openAI,
                                  model: String = "synthetic-model",
                                  endpoint: String? = nil) throws -> OutboundDestination {
  try OutboundDestination(provider: provider, model: model, ollamaEndpoint: endpoint)
}

private func transportRequest(_ url: URL) -> URLRequest {
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.httpBody = Data("{}".utf8)
  return request
}

/// Pure policy/state tests and direct synthetic delegate invocations. No task is
/// resumed and no URLProtocol/live server is used. These are NOT evidence that
/// Foundation's network stack enforces these controls on a supported macOS SDK.
final class NativeProviderTransportTests: XCTestCase {
  func testConfigurationHasNoCookieCredentialOrCacheStore() {
    let config = NativeProviderTransport.isolatedConfiguration()
    XCTAssertNil(config.identifier)
    XCTAssertNil(config.httpCookieStorage)
    XCTAssertNil(config.urlCredentialStorage)
    XCTAssertNil(config.urlCache)
    XCTAssertFalse(config.httpShouldSetCookies)
    XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
    XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertTrue(config.httpAdditionalHeaders?.isEmpty == true)
    XCTAssertTrue(config.protocolClasses?.isEmpty == true)
    XCTAssertFalse(config.waitsForConnectivity)
    XCTAssertEqual(config.httpMaximumConnectionsPerHost, 4)
    XCTAssertEqual(config.timeoutIntervalForResource, 60)
  }

  func testConfigurationsAreFreshAndIndependent() {
    let first = NativeProviderTransport.isolatedConfiguration()
    first.httpShouldSetCookies = true
    first.httpAdditionalHeaders = ["X-Synthetic": "test"]
    let second = NativeProviderTransport.isolatedConfiguration()
    XCTAssertFalse(first === second)
    XCTAssertFalse(second.httpShouldSetCookies)
    XCTAssertTrue(second.httpAdditionalHeaders?.isEmpty == true)
  }

  func testExactNativeEndpoints() throws {
    let cases: [(LLMProvider, String?, String)] = [
      (.openAI, nil, "https://api.openai.com/v1/chat/completions"),
      (.claude, nil, "https://api.anthropic.com/v1/messages"),
      (.gemini, nil, "https://generativelanguage.googleapis.com/v1beta/models/synthetic-model:generateContent"),
      (.ollama, "http://localhost:11434", "http://localhost:11434/api/chat"),
      (.ollama, "https://ollama.example.test:443/private/base/",
        "https://ollama.example.test:443/private/base/api/chat"),
    ]
    for (provider, endpoint, expected) in cases {
      let policy = try NativeProviderRecipient(destination:
        transportDestination(provider, endpoint: endpoint))
      XCTAssertEqual(policy.url.absoluteString, expected)
      XCTAssertTrue(policy.matches(URL(string: expected)))
    }
    XCTAssertThrowsError(try NativeProviderRecipient(destination: transportDestination(.openAICodex)))
  }

  func testGeminiModelCannotAddURLSyntax() throws {
    for model in ["..", ".", "other/model", "model?key=bad", "model#fragment",
                  "model%2Fother", "model name", "model\\other", "é", String(repeating: "a", count: 201)] {
      XCTAssertThrowsError(try NativeProviderRecipient(destination:
        transportDestination(.gemini, model: model)), model)
    }
  }

  func testOllamaRejectsAmbiguousPathsAndInvalidPorts() throws {
    for endpoint in ["https://example.test/a/../b", "https://example.test/%2e%2e",
                     "https://example.test/%2fhidden", "https://example.test/%5chidden",
                     "https://example.test/%252fhidden", "https://example.test/%00",
                     "https://example.test:0", "https://example.test:65536"] {
      XCTAssertThrowsError(try NativeProviderRecipient(destination:
        transportDestination(.ollama, endpoint: endpoint)), endpoint)
    }
  }

  func testExactURLRejectsAliasesAndOtherRecipients() throws {
    let policy = try NativeProviderRecipient(destination: transportDestination())
    for value in ["http://api.openai.com/v1/chat/completions",
                  "https://api.openai.com:443/v1/chat/completions",
                  "https://API.OPENAI.COM/v1/chat/completions",
                  "https://api.openai.com./v1/chat/completions",
                  "https://api.openai.com/v1/chat/completions/",
                  "https://api.openai.com/v1/chat/completions?x=1",
                  "https://api.openai.com/v1/chat/completions#x",
                  "https://api.openai.com/v1/chat/%63ompletions",
                  "https://api.openai.com/v1/models",
                  "https://api.openai.com.attacker.test/v1/chat/completions",
                  "https://synthetic-user@api.openai.com/v1/chat/completions"] {
      XCTAssertFalse(policy.matches(URL(string: value)), value)
    }
    XCTAssertFalse(policy.matches(nil))
    XCTAssertFalse(policy.matches(URL(string: "completions", relativeTo:
      URL(string: "https://api.openai.com/v1/chat/")!)))
  }

  func testRequestSuppressesCookieHandlingAndCacheWithoutChangingExplicitAuth() throws {
    let policy = try NativeProviderRecipient(destination: transportDestination())
    var original = transportRequest(policy.url)
    original.setValue("Bearer synthetic-test-only", forHTTPHeaderField: "Authorization")
    original.setValue("application/json", forHTTPHeaderField: "Content-Type")
    original.httpShouldHandleCookies = true
    original.cachePolicy = .returnCacheDataElseLoad
    original.mainDocumentURL = URL(string: "https://context.example.test")
    let request = try policy.prepare(original)
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(request.mainDocumentURL)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-only")
    XCTAssertEqual(request.httpBody, original.httpBody)
    XCTAssertEqual(request.url, original.url)
  }

  func testManualCookieHostAndProxyHeadersFailClosed() throws {
    let policy = try NativeProviderRecipient(destination: transportDestination())
    for name in ["Cookie", "cOoKiE2", "Host", "Proxy-Authorization", "Proxy-Connection"] {
      var request = transportRequest(policy.url)
      request.setValue("synthetic-test-only", forHTTPHeaderField: name)
      XCTAssertThrowsError(try policy.prepare(request), name)
    }
  }

  func testOnlyPostWithAnInMemoryBodyToExactURLIsAdmitted() throws {
    let policy = try NativeProviderRecipient(destination: transportDestination())
    var request = transportRequest(policy.url)
    request.httpMethod = "GET"
    XCTAssertThrowsError(try policy.prepare(request))
    request.httpMethod = "POST"
    request.httpBody = nil
    XCTAssertThrowsError(try policy.prepare(request))
    request.httpBodyStream = InputStream(data: Data("{}".utf8))
    XCTAssertThrowsError(try policy.prepare(request))
    request = transportRequest(URL(string: "https://other.example.test/")!)
    XCTAssertThrowsError(try policy.prepare(request))
  }

  func testResponsesMustRemainAtExactRecipientAndAll3xxAreRefused() throws {
    let policy = try NativeProviderRecipient(destination: transportDestination())
    for status in [200, 400, 401, 429, 500] {
      let response = try XCTUnwrap(HTTPURLResponse(url: policy.url, statusCode: status,
        httpVersion: nil, headerFields: nil))
      XCTAssertEqual(try policy.validate(response).statusCode, status)
    }
    for status in [300, 301, 302, 303, 304, 305, 307, 308, 399] {
      let response = HTTPURLResponse(url: policy.url, statusCode: status,
        httpVersion: nil, headerFields: ["Location": "https://other.example.test/"])
      XCTAssertThrowsError(try policy.validate(response))
    }
    XCTAssertThrowsError(try policy.validate(HTTPURLResponse(
      url: URL(string: "https://other.example.test/")!, statusCode: 200,
      httpVersion: nil, headerFields: nil)))
    XCTAssertThrowsError(try policy.validate(URLResponse(url: policy.url,
      mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
    XCTAssertThrowsError(try policy.validate(nil))
  }

  func testRedirectDelegateAlwaysReturnsNilIncludingSameRecipient() throws {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    let url = URL(string: "https://recipient.example.test/generate")!
    let task = session.dataTask(with: url) // Deliberately never resumed.
    for status in [301, 302, 303, 307, 308] {
      for target in [url, URL(string: "https://other.example.test/")!] {
        let callbacks = TransportTestCounter()
        delegate.urlSession(session, task: task,
          willPerformHTTPRedirection: try XCTUnwrap(HTTPURLResponse(url: url,
            statusCode: status, httpVersion: nil, headerFields: nil)),
          newRequest: transportRequest(target)) { redirected in
            XCTAssertNil(redirected)
            callbacks.increment()
          }
        XCTAssertEqual(callbacks.value, 1)
      }
    }
  }

  func testAuthenticationChallengesRefuseNonTrustWithoutCredentials() throws {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://recipient.example.test/")!)
    for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                   NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
                   NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault,
                   NSURLAuthenticationMethodServerTrust] {
      let challenge = URLAuthenticationChallenge(protectionSpace: URLProtectionSpace(
        host: "recipient.example.test", port: 443, protocol: "https", realm: nil,
        authenticationMethod: method), proposedCredential: nil,
        previousFailureCount: 0, failureResponse: nil, error: nil,
        sender: TransportChallengeSender())
      let callbacks = TransportTestCounter()
      let handler: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = {
        disposition, credential in
        XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust
          ? .performDefaultHandling : .cancelAuthenticationChallenge)
        XCTAssertNil(credential)
        callbacks.increment()
      }
      delegate.urlSession(session, didReceive: challenge, completionHandler: handler)
      delegate.urlSession(session, task: task, didReceive: challenge, completionHandler: handler)
      XCTAssertEqual(callbacks.value, 2)
    }
  }

  func testAdmissionCloseIsPermanentAndIdempotent() {
    let admission = NativeProviderAdmission()
    var starts = 0
    XCTAssertTrue(admission.admit { starts += 1 })
    XCTAssertTrue(admission.close())
    XCTAssertTrue(admission.isClosed)
    XCTAssertFalse(admission.close())
    XCTAssertFalse(admission.admit { starts += 1 })
    XCTAssertEqual(starts, 1)
    admission.complete()
  }

  func testConcurrentCloseCannotOvertakeAdmittedConstruction() {
    let admission = NativeProviderAdmission()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let closeAttempted = DispatchSemaphore(value: 0)
    let finished = DispatchGroup()
    let closed = TransportTestCounter()
    finished.enter()
    DispatchQueue.global().async {
      XCTAssertTrue(admission.admit {
        started.signal()
        release.wait()
        XCTAssertEqual(closed.value, 0)
      })
      admission.complete()
      finished.leave()
    }
    started.wait()
    finished.enter()
    DispatchQueue.global().async {
      closeAttempted.signal()
      XCTAssertTrue(admission.close())
      closed.increment()
      finished.leave()
    }
    closeAttempted.wait()
    release.signal()
    XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(closed.value, 1)
    XCTAssertFalse(admission.admit { XCTFail("Closed admission") })
  }

  func testCancellationBeforeTaskAssignmentIsRememberedExactlyOnce() {
    let slot = NativeProviderTaskCancellation()
    let cancels = TransportTestCounter()
    slot.cancel()
    slot.cancel()
    slot.install { cancels.increment() }
    XCTAssertEqual(cancels.value, 1)
    slot.cancel()
    XCTAssertTrue(slot.complete())
    slot.cancel()
    XCTAssertEqual(cancels.value, 1)
  }

  func testCancellationAfterAssignmentWaitsForExplicitCompletion() {
    let slot = NativeProviderTaskCancellation()
    let cancels = TransportTestCounter()
    slot.install { cancels.increment() }
    slot.cancel()
    XCTAssertEqual(cancels.value, 1)
    XCTAssertTrue(slot.complete())
    slot.cancel()
    XCTAssertEqual(cancels.value, 1)
  }

  func testCompletionDropsTaskCaptureAndLaterCancellationIsInert() {
    let slot = NativeProviderTaskCancellation()
    weak var retained: TransportTestCounter?
    do {
      let capture = TransportTestCounter()
      retained = capture
      slot.install { capture.increment() }
    }
    XCTAssertNotNil(retained)
    XCTAssertFalse(slot.complete())
    XCTAssertNil(retained)
    slot.cancel()
    XCTAssertFalse(slot.complete())
  }

  func testInvalidationCallbackBeforeWaitAndRepeatedCallbacksAreSafe() async {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    delegate.urlSession(session, didBecomeInvalidWithError: nil)
    await delegate.waitForInvalidation()
    delegate.urlSession(session, didBecomeInvalidWithError: nil)
    await delegate.waitForInvalidation()
  }

  func testMultipleInvalidationWaitersAreReleased() async {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    // Register both before invalidation, without sleeps or scheduler assumptions.
    let registrations = TransportTestCounter()
    let wait: @Sendable () async -> Void = {
      await withCheckedContinuation { continuation in
        XCTAssertTrue(delegate.registerInvalidationWaiter(continuation))
        registrations.increment()
        if registrations.value == 2 {
          delegate.urlSession(session, didBecomeInvalidWithError: nil)
        }
      }
    }
    async let first: Void = wait()
    async let second: Void = wait()
    _ = await (first, second)
    XCTAssertEqual(registrations.value, 2)
  }

  func testTaskDrainWaiterHandlesOutstandingAndAlreadyCompletedWork() async {
    let admission = NativeProviderAdmission()
    XCTAssertTrue(admission.admit {})
    XCTAssertTrue(admission.admit {})
    XCTAssertTrue(admission.close())
    admission.complete()
    await withCheckedContinuation { continuation in
      // The first completion must not have released the last task's waiter.
      XCTAssertTrue(admission.registerTaskWaiter(continuation))
      admission.complete()
    }
    // Later and repeated waiters do not hang after all callbacks have completed.
    await admission.waitForTasks()
    await admission.waitForTasks()
  }

  func testRealClientGenerationEndpointsAgreeWithPolicyWithoutNetwork() async throws {
    for provider in [LLMProvider.openAI, .claude, .gemini, .ollama] {
      let destination = try transportDestination(provider, endpoint:
        provider == .ollama ? "http://localhost:11434/base" : nil)
      let transport = try EndpointCheckingTransport(destination: destination)
      let client: any LLMProviderClient
      switch provider {
      case .openAI: client = OpenAIClient(apiKey: "synthetic-test-only", transport: transport)
      case .claude: client = ClaudeClient(apiKey: "synthetic-test-only", transport: transport)
      case .gemini: client = GeminiClient(apiKey: "synthetic-test-only", transport: transport)
      case .ollama: client = OllamaClient(baseURL: try XCTUnwrap(destination.ollamaEndpoint), transport: transport)
      case .openAICodex: return XCTFail("Unsupported fixture")
      }
      let text = try await client.generate(text: "synthetic", model: destination.model,
        systemPrompt: "synthetic", effort: .low)
      XCTAssertEqual(text, "synthetic-output")
      let calls = await transport.calls
      XCTAssertEqual(calls, 1)
    }
  }

  func testBoundedResponseAccumulatesInOrderAndAcceptsExactCap() throws {
    for headers in [nil, ["Content-Length": "8"], ["Content-Length": "0008"]] as [[String: String]?] {
      let outcome = TransportTestOutcome()
      let response = try transportResponseState(outcome: outcome)
      XCTAssertEqual(response.receive(try transportResponse(headers: headers)), .allow)
      XCTAssertEqual(response.receive(Data("abc".utf8)), .accepted)
      XCTAssertEqual(response.receive(Data()), .accepted)
      XCTAssertEqual(response.receive(Data("defgh".utf8)), .accepted)
      XCTAssertEqual(response.bufferedByteCount, 8)
      XCTAssertNil(outcome.result)
      response.complete(error: nil)
      XCTAssertEqual(try XCTUnwrap(outcome.result).get().0, Data("abcdefgh".utf8))
      XCTAssertEqual(response.bufferedByteCount, 0)
      XCTAssertEqual(outcome.completionCount, 1)
    }
  }

  func testResponseCapAllowsEscapedStructuredJSONEnvelope() throws {
    // Model the largest one-level JSON escaping expansion for 128,000 bytes.
    // This is a size-policy fixture, not a valid correction or provider reply.
    let escaped = String(repeating: "\\u0000", count: 128_000)
    let envelope = Data(("{\"choices\":[{\"message\":{\"content\":\"" + escaped + "\"}}]}").utf8)
    XCTAssertEqual(NativeProviderTransport.maximumResponseBytes, 1_048_576)
    XCTAssertGreaterThan(envelope.count, 128_000)
    XCTAssertLessThan(envelope.count, NativeProviderTransport.maximumResponseBytes)
    let outcome = TransportTestOutcome()
    let response = try transportResponseState(outcome: outcome,
      maximumBytes: NativeProviderTransport.maximumResponseBytes)
    XCTAssertEqual(response.receive(try transportResponse()), .allow)
    XCTAssertEqual(response.receive(envelope), .accepted)
    response.complete(error: nil)
    XCTAssertEqual(try XCTUnwrap(outcome.result).get().0, envelope)
  }

  func testOversizedContentLengthRefusesBeforeAccumulating() throws {
    for length in ["9", "0009", "1048577", "184467440737095516160000"] {
      let outcome = TransportTestOutcome()
      let response = try transportResponseState(outcome: outcome)
      XCTAssertEqual(response.receive(try transportResponse(headers:
        ["Content-Length": length])), .cancel, length)
      XCTAssertEqual(response.bufferedByteCount, 0)
      XCTAssertEqual(response.receive(Data("ignored".utf8)), .discard)
      XCTAssertNil(outcome.result)
      response.complete(error: URLError(.cancelled))
      assertTransportFailure(outcome, .responseTooLarge)
    }
  }

  func testMalformedContentLengthFailsClosed() throws {
    for length in ["-1", "+1", "1.0", "1, 1", "NaN", ""] {
      let outcome = TransportTestOutcome()
      let response = try transportResponseState(outcome: outcome)
      XCTAssertEqual(response.receive(try transportResponse(headers:
        ["Content-Length": length])), .cancel, length)
      response.complete(error: nil)
      assertTransportFailure(outcome, .refusedResponse)
    }
  }

  func testAbsentOrFalseLengthCannotBypassActualChunkCap() throws {
    for headers in [nil, ["Content-Length": "0"], ["Content-Length": "1"],
                    ["Transfer-Encoding": "chunked"],
                    ["Content-Encoding": "gzip", "Content-Length": "2"]] as [[String: String]?] {
      let outcome = TransportTestOutcome()
      let response = try transportResponseState(outcome: outcome)
      XCTAssertEqual(response.receive(try transportResponse(headers: headers)), .allow)
      XCTAssertEqual(response.receive(Data(repeating: 65, count: 8)), .accepted)
      XCTAssertEqual(response.bufferedByteCount, 8)
      XCTAssertEqual(response.receive(Data([66])), .cancel)
      XCTAssertEqual(response.bufferedByteCount, 0)
      XCTAssertEqual(response.receive(Data(repeating: 67, count: 100)), .discard)
      XCTAssertNil(outcome.result)
      response.complete(error: URLError(.cancelled))
      assertTransportFailure(outcome, .responseTooLarge)
    }
  }

  func testOversizedFirstChunkIsNeverAppendedAndFailureStaysLatched() throws {
    let outcome = TransportTestOutcome()
    let response = try transportResponseState(outcome: outcome)
    XCTAssertEqual(response.receive(try transportResponse()), .allow)
    XCTAssertEqual(response.receive(Data(repeating: 65, count: 100_000)), .cancel)
    XCTAssertEqual(response.bufferedByteCount, 0)
    XCTAssertEqual(response.receive(Data([66])), .discard)
    XCTAssertEqual(response.receive(try transportResponse()), .cancel)
    XCTAssertNil(outcome.result)
    response.complete(error: nil)
    assertTransportFailure(outcome, .responseTooLarge)
  }

  func testResponseValidationPrecedesAccumulationAndDuplicateResponsesFailClosed() throws {
    let refused: [URLResponse] = [
      try transportResponse(status: 307),
      try transportResponse(url: URL(string: "https://other.example.test/")),
      URLResponse(url: URL(string: "https://api.openai.com/v1/chat/completions")!,
        mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
    ]
    for incoming in refused {
      let outcome = TransportTestOutcome()
      let response = try transportResponseState(outcome: outcome)
      XCTAssertEqual(response.receive(incoming), .cancel)
      XCTAssertEqual(response.receive(Data([65])), .discard)
      XCTAssertEqual(response.bufferedByteCount, 0)
      response.complete(error: nil)
      assertTransportFailure(outcome, .refusedResponse)
    }
    let outcome = TransportTestOutcome()
    let response = try transportResponseState(outcome: outcome)
    XCTAssertEqual(response.receive(try transportResponse()), .allow)
    XCTAssertEqual(response.receive(Data(repeating: 65, count: 8)), .accepted)
    XCTAssertEqual(response.receive(try transportResponse()), .cancel)
    XCTAssertEqual(response.bufferedByteCount, 0)
    XCTAssertEqual(response.receive(Data([66])), .discard)
    response.complete(error: nil)
    assertTransportFailure(outcome, .refusedResponse)
  }

  func testResponseStateRejectsDataBeforeHeadersAndCompletionWithoutHeaders() throws {
    for sendEarlyData in [false, true] {
      let outcome = TransportTestOutcome()
      let response = try transportResponseState(outcome: outcome)
      if sendEarlyData {
        XCTAssertEqual(response.receive(Data([65])), .cancel)
        XCTAssertEqual(response.bufferedByteCount, 0)
      }
      response.complete(error: nil)
      assertTransportFailure(outcome, .refusedResponse)
    }
  }

  func testResponseStatePreservesNetworkErrorsAndAcceptsEmptyHTTPBody() throws {
    let failed = TransportTestOutcome()
    let response = try transportResponseState(outcome: failed)
    XCTAssertEqual(response.receive(try transportResponse()), .allow)
    XCTAssertEqual(response.receive(Data([65])), .accepted)
    response.complete(error: URLError(.timedOut))
    XCTAssertThrowsError(try XCTUnwrap(failed.result).get()) {
      XCTAssertEqual(($0 as? URLError)?.code, .timedOut)
    }
    XCTAssertEqual(response.bufferedByteCount, 0)
    let empty = TransportTestOutcome()
    let emptyResponse = try transportResponseState(outcome: empty)
    XCTAssertEqual(emptyResponse.receive(try transportResponse(status: 500)), .allow)
    emptyResponse.complete(error: nil)
    XCTAssertEqual(try XCTUnwrap(empty.result).get().0, Data())
    XCTAssertEqual(try XCTUnwrap(empty.result).get().1.statusCode, 500)
  }

  func testCallerCancellationWinsButNeverCompletesBeforeTerminalCallback() throws {
    let outcome = TransportTestOutcome()
    let cancellation = NativeProviderTaskCancellation()
    let cancels = TransportTestCounter()
    cancellation.install { cancels.increment() }
    let response = try transportResponseState(outcome: outcome, cancellation: cancellation)
    XCTAssertEqual(response.receive(try transportResponse()), .allow)
    XCTAssertEqual(response.receive(Data(repeating: 65, count: 9)), .cancel)
    cancellation.cancel()
    cancellation.cancel()
    XCTAssertEqual(cancels.value, 1)
    XCTAssertNil(outcome.result)
    response.complete(error: URLError(.cancelled))
    XCTAssertThrowsError(try XCTUnwrap(outcome.result).get()) { XCTAssertTrue($0 is CancellationError) }
    response.complete(error: nil)
    cancellation.cancel()
    XCTAssertEqual(outcome.completionCount, 1)
    XCTAssertEqual(cancels.value, 1)
    XCTAssertEqual(response.receive(Data([66])), .discard)
    XCTAssertEqual(response.receive(try transportResponse()), .cancel)
  }

  func testDelegateRoutesInterleavedChunksAndCompletesEachTaskOnlyOnce() throws {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    let url = try NativeProviderRecipient(destination: transportDestination()).url
    let firstTask = session.dataTask(with: url) // Neither task is ever resumed.
    let secondTask = session.dataTask(with: url)
    let first = TransportTestOutcome()
    let second = TransportTestOutcome()
    let firstResponse = try transportResponseState(outcome: first)
    let secondResponse = try transportResponseState(outcome: second)
    delegate.register(firstResponse, for: firstTask.taskIdentifier)
    delegate.register(secondResponse, for: secondTask.taskIdentifier)
    for task in [firstTask, secondTask] {
      delegate.urlSession(session, dataTask: task, didReceive: try transportResponse()) {
        XCTAssertEqual($0, .allow)
      }
    }
    delegate.urlSession(session, dataTask: firstTask, didReceive: Data("ab".utf8))
    delegate.urlSession(session, dataTask: secondTask, didReceive: Data("12".utf8))
    delegate.urlSession(session, dataTask: firstTask, didReceive: Data("cd".utf8))
    delegate.urlSession(session, task: firstTask, didCompleteWithError: nil)
    delegate.urlSession(session, dataTask: secondTask, didReceive: Data("34".utf8))
    delegate.urlSession(session, task: secondTask, didCompleteWithError: nil)
    delegate.urlSession(session, task: firstTask, didCompleteWithError: URLError(.cancelled))
    delegate.urlSession(session, dataTask: firstTask, didReceive: Data("late".utf8))
    delegate.urlSession(session, dataTask: firstTask, didReceive: try transportResponse()) {
      XCTAssertEqual($0, .cancel)
    }
    XCTAssertEqual(try XCTUnwrap(first.result).get().0, Data("abcd".utf8))
    XCTAssertEqual(try XCTUnwrap(second.result).get().0, Data("1234".utf8))
    XCTAssertEqual(first.completionCount, 1)
    XCTAssertEqual(second.completionCount, 1)
  }

  func testOversizeDelegateCancellationRetainsAdmissionUntilTerminalCallback() async throws {
    let delegate = NativeProviderSessionDelegate()
    let admission = NativeProviderAdmission()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    let recipient = try NativeProviderRecipient(destination: transportDestination())
    let task = session.dataTask(with: recipient.url) // Never resumed; callbacks are synthetic.
    let cancellation = NativeProviderTaskCancellation()
    let outcome = TransportTestOutcome()
    let retained: TransportTestWeakReference<TransportTestCounter>
    do {
      let capture = TransportTestCounter()
      retained = TransportTestWeakReference(capture)
      cancellation.install { capture.increment() }
    }
    let response = NativeProviderResponseState(recipient: recipient,
      cancellation: cancellation, maximumBytes: 8) {
        XCTAssertNil(retained.value) // Cancellation capture is cleared before completion.
        outcome.record($0)
        admission.complete()
      }
    XCTAssertTrue(admission.admit { delegate.register(response, for: task.taskIdentifier) })
    delegate.urlSession(session, dataTask: task, didReceive: try transportResponse()) {
      XCTAssertEqual($0, .allow)
    }
    delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 65, count: 9))
    XCTAssertEqual(response.bufferedByteCount, 0)
    XCTAssertNil(outcome.result)
    XCTAssertNotNil(retained.value)
    XCTAssertTrue(admission.close())
    delegate.urlSession(session, didBecomeInvalidWithError: nil)
    await delegate.waitForInvalidation() // Invalidation alone must not drain this task.
    await withCheckedContinuation { continuation in
      XCTAssertTrue(admission.registerTaskWaiter(continuation))
      XCTAssertNil(outcome.result)
      delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    }
    assertTransportFailure(outcome, .responseTooLarge)
    XCTAssertNil(retained.value)
    delegate.urlSession(session, task: task, didCompleteWithError: nil)
    XCTAssertEqual(outcome.completionCount, 1)
    await admission.waitForTasks()
  }

  func testTerminalDelegateCallbackReleasesRegisteredResponseState() throws {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: try NativeProviderRecipient(destination:
      transportDestination()).url) // Never resumed.
    let outcome = TransportTestOutcome()
    let retained: TransportTestWeakReference<NativeProviderResponseState>
    do {
      let response = try transportResponseState(outcome: outcome)
      retained = TransportTestWeakReference(response)
      delegate.register(response, for: task.taskIdentifier)
    }
    XCTAssertNotNil(retained.value)
    delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    XCTAssertNil(retained.value)
    XCTAssertEqual(outcome.completionCount, 1)
    XCTAssertThrowsError(try XCTUnwrap(outcome.result).get()) { XCTAssertTrue($0 is CancellationError) }
  }

  func testDelegateHeaderRefusalWaitsForTerminalCallback() throws {
    let delegate = NativeProviderSessionDelegate()
    let session = URLSession(configuration: NativeProviderTransport.isolatedConfiguration())
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: try NativeProviderRecipient(destination:
      transportDestination()).url) // Never resumed.
    let outcome = TransportTestOutcome()
    let response = try transportResponseState(outcome: outcome)
    delegate.register(response, for: task.taskIdentifier)
    let callbacks = TransportTestCounter()
    delegate.urlSession(session, dataTask: task, didReceive: try transportResponse(headers:
      ["Content-Length": "9"])) {
        XCTAssertEqual($0, .cancel)
        callbacks.increment()
      }
    XCTAssertEqual(callbacks.value, 1)
    XCTAssertNil(outcome.result)
    delegate.urlSession(session, dataTask: task, didReceive: Data(repeating: 65, count: 9))
    XCTAssertEqual(response.bufferedByteCount, 0)
    XCTAssertNil(outcome.result)
    delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    assertTransportFailure(outcome, .responseTooLarge)
  }

  private func assertTransportFailure(_ outcome: TransportTestOutcome,
                                      _ expected: NativeProviderTransport.Failure,
                                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try XCTUnwrap(outcome.result).get(), file: file, line: line) {
      XCTAssertEqual($0 as? NativeProviderTransport.Failure, expected, file: file, line: line)
    }
    XCTAssertEqual(outcome.completionCount, 1, file: file, line: line)
  }

  func testClosedTransportNeverCreatesNetworkWork() async throws {
    let transport = try NativeProviderTransport(destination: transportDestination())
    transport.close()
    let policy = try NativeProviderRecipient(destination: transportDestination())
    do {
      _ = try await transport.data(for: transportRequest(policy.url))
      XCTFail("Closed transport accepted work")
    } catch { XCTAssertTrue(error is CancellationError) }
    await transport.closeAndWait()
    await transport.closeAndWait()
  }
}

/// Executes existing provider URL/body construction against an in-memory transport.
/// Only fixed synthetic strings are used; no Keychain/factory or URLSession call.
private actor EndpointCheckingTransport: HTTPTransport {
  let recipient: NativeProviderRecipient
  let responseBody: Data
  private(set) var calls = 0

  init(destination: OutboundDestination) throws {
    recipient = try NativeProviderRecipient(destination: destination)
    let body: String
    switch destination.provider {
    case .openAI: body = #"{"choices":[{"message":{"content":"synthetic-output"}}]}"#
    case .claude: body = #"{"content":[{"text":"synthetic-output"}]}"#
    case .gemini: body = #"{"candidates":[{"content":{"parts":[{"text":"synthetic-output"}]}}]}"#
    case .ollama: body = #"{"message":{"content":"synthetic-output"}}"#
    case .openAICodex: throw NativeProviderTransport.Failure.invalidDestination
    }
    responseBody = Data(body.utf8)
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    _ = try recipient.prepare(request)
    calls += 1
    return (responseBody, HTTPURLResponse(url: recipient.url, statusCode: 200,
      httpVersion: nil, headerFields: nil)!)
  }
}

/// Synthetic challenge sender. No Keychain, password, certificate or trust object.
private final class TransportChallengeSender: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
  func cancel(_ challenge: URLAuthenticationChallenge) {}
  func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
  func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
