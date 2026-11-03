import Combine
import Foundation
import XCTest

@testable import Bex

/// Synthetic transports/listeners only: no sockets, Keychain access, credentials or
/// provider calls. These tests need native compilation/execution before activation.
@MainActor
final class CodexAccountLifecycleTests: XCTestCase {
  func testManualExchangeFinishingAfterOtherStoreDisconnectCannotRestoreSession() async throws {
    let serviceName = "com.bex.tests.oauth-disconnect.\(UUID())"
    let keychain = KeychainStore(service: serviceName, inMemory: true)
    let otherStore = KeychainStore(service: serviceName, inMemory: true)
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport)
    let flow = try await oauth.begin()
    let completion = Task { try await oauth.completeManual(callbackURL: callback(for: flow)) }
    await transport.waitForRequests(1)

    try await otherStore.deleteCodexSession()
    await transport.succeed(0, data: try tokenPayload(marker: "late-login"))

    await assertCancelled(completion)
    let stored = try await keychain.codexSession()
    XCTAssertNil(stored)
  }

  func testLoopbackExchangeFinishingAfterReplacementCannotOverwriteSession() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    let flow = try await oauth.begin()
    let completion = Task { try await oauth.waitForLoopbackCompletion() }
    await listener.deliver(URL(string: callback(for: flow))!)
    await transport.waitForRequests(1)
    let replacement = session(marker: "replacement", expired: false)

    try await keychain.saveCodexSession(replacement)
    await transport.succeed(0, data: try tokenPayload(marker: "late-login"))

    await assertCancelled(completion)
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, replacement)
  }

  func testNewServiceLoginSupersedesOldCompletionAndOldCancelDoesNotCancelNewFlow() async throws {
    let serviceName = "com.bex.tests.oauth-replacement.\(UUID())"
    let firstStore = KeychainStore(service: serviceName, inMemory: true)
    let secondStore = KeychainStore(service: serviceName, inMemory: true)
    let firstTransport = DeferredCodexTransport()
    let secondTransport = DeferredCodexTransport()
    let first = makeService(keychain: firstStore, transport: firstTransport)
    let second = makeService(keychain: secondStore, transport: secondTransport)
    let oldFlow = try await first.begin()
    let oldCompletion = Task {
      try await first.completeManual(callbackURL: callback(for: oldFlow))
    }
    await firstTransport.waitForRequests(1)
    let newFlow = try await second.begin()
    await first.cancel()
    let newCompletion = Task {
      try await second.completeManual(callbackURL: callback(for: newFlow))
    }
    await secondTransport.waitForRequests(1)
    await secondTransport.succeed(0, data: try tokenPayload(marker: "new-login"))
    let connected = try await newCompletion.value
    await firstTransport.succeed(0, data: try tokenPayload(marker: "old-login"))

    await assertCancelled(oldCompletion)
    let stored = try await firstStore.codexSession()
    XCTAssertEqual(stored, connected)
    XCTAssertEqual(stored?.refreshToken, "refresh-new-login")
  }

  func testRefreshFinishingAfterDisconnectCannotRestoreSessionOrSendRequest() async throws {
    let keychain = makeKeychain()
    try await keychain.saveCodexSession(session(marker: "old", expired: true))
    let transport = DeferredCodexTransport()
    let client = OpenAICodexClient(keychain: keychain, transport: transport)
    let request = Task { try await client.fetchModels() }
    await transport.waitForRequests(1)

    try await keychain.deleteCodexSession()
    await transport.succeed(0, data: try tokenPayload(marker: "late-refresh"))

    await assertCancelled(request)
    let stored = try await keychain.codexSession()
    let requests = await transport.recordedRequests()
    XCTAssertNil(stored)
    XCTAssertEqual(requests.count, 1, "stale refresh must not issue the model request")
  }

  func testLoginIntentInvalidatesInFlightRefreshBeforeLoginCompletes() async throws {
    let keychain = makeKeychain()
    let original = session(marker: "old", expired: true)
    try await keychain.saveCodexSession(original)
    let transport = DeferredCodexTransport()
    let client = OpenAICodexClient(keychain: keychain, transport: transport)
    let request = Task {
      try await client.generate(text: "text", model: "model", systemPrompt: "system")
    }
    await transport.waitForRequests(1)
    let oauth = makeService(keychain: keychain, transport: DeferredCodexTransport())
    _ = try await oauth.begin()
    await oauth.cancel() // A failed/cancelled newer login must not revive older work.
    await transport.succeed(0, data: try tokenPayload(marker: "late-refresh"))

    await assertCancelled(request)
    let stored = try await keychain.codexSession()
    let requests = await transport.recordedRequests()
    XCTAssertEqual(stored, original)
    XCTAssertEqual(requests.count, 1)
  }

  func testRefreshFinishingAfterSameAccountReplacementCannotOverwriteExactVersion() async throws {
    let keychain = makeKeychain()
    try await keychain.saveCodexSession(session(marker: "old", expired: true))
    let transport = DeferredCodexTransport()
    let client = OpenAICodexClient(keychain: keychain, transport: transport)
    let request = Task { try await client.fetchModels() }
    await transport.waitForRequests(1)
    // All fixtures deliberately use the same account ID. Account ID equality is not CAS.
    let replacement = session(marker: "replacement", expired: false)
    try await keychain.saveCodexSession(replacement)
    await transport.succeed(0, data: try tokenPayload(marker: "late-refresh"))

    await assertCancelled(request)
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, replacement)
  }

  func testCompetingRefreshesOnlyCommitFirstExactSessionVersion() async throws {
    let serviceName = "com.bex.tests.refresh-version.\(UUID())"
    let firstStore = KeychainStore(service: serviceName, inMemory: true)
    let secondStore = KeychainStore(service: serviceName, inMemory: true)
    try await firstStore.saveCodexSession(session(marker: "old", expired: true))
    let firstTransport = DeferredCodexTransport()
    let secondTransport = DeferredCodexTransport()
    let first = OpenAICodexClient(keychain: firstStore, transport: firstTransport)
    let second = OpenAICodexClient(keychain: secondStore, transport: secondTransport)
    let firstRequest = Task { try await first.fetchModels() }
    let secondRequest = Task { try await second.fetchModels() }
    await firstTransport.waitForRequests(1)
    await secondTransport.waitForRequests(1)

    await firstTransport.succeed(0, data: try tokenPayload(marker: "winner"))
    await firstTransport.waitForRequests(2)
    await firstTransport.succeed(1, data: modelsPayload)
    _ = try await firstRequest.value
    await secondTransport.succeed(0, data: try tokenPayload(marker: "loser"))

    await assertCancelled(secondRequest)
    let stored = try await secondStore.codexSession()
    let secondRequests = await secondTransport.recordedRequests()
    XCTAssertEqual(stored?.refreshToken, "refresh-winner")
    XCTAssertEqual(secondRequests.count, 1)
  }

  func testCancelledExchangeIgnoringCancellationCannotCommit() async throws {
    let keychain = makeKeychain()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport)
    let flow = try await oauth.begin()
    let completion = Task { try await oauth.completeManual(callbackURL: callback(for: flow)) }
    await transport.waitForRequests(1)
    completion.cancel()
    // The fake deliberately ignores cancellation, as a provider may do during shutdown.
    await transport.succeed(0, data: try tokenPayload(marker: "cancelled"))

    await assertCancelled(completion)
    let stored = try await keychain.codexSession()
    XCTAssertNil(stored)
  }

  func testCancelledRefreshIgnoringCancellationCannotCommitOrSendRequest() async throws {
    let keychain = makeKeychain()
    let original = session(marker: "old", expired: true)
    try await keychain.saveCodexSession(original)
    let transport = DeferredCodexTransport()
    let client = OpenAICodexClient(keychain: keychain, transport: transport)
    let request = Task { try await client.fetchModels() }
    await transport.waitForRequests(1)
    request.cancel()
    await transport.succeed(0, data: try tokenPayload(marker: "cancelled"))

    await assertCancelled(request)
    let stored = try await keychain.codexSession()
    let requests = await transport.recordedRequests()
    XCTAssertEqual(stored, original)
    XCTAssertEqual(requests.count, 1)
  }

  func testCancelledLoopbackWaitStopsCapturedListenerAndFinishes() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    _ = try await oauth.begin()
    let completion = Task { try await oauth.waitForLoopbackCompletion() }
    await listener.waitUntilCallbackWaits()
    completion.cancel()

    await assertCancelled(completion)
    let requests = await transport.recordedRequests()
    let stored = try await keychain.codexSession()
    XCTAssertTrue(requests.isEmpty)
    XCTAssertNil(stored)
  }

  func testManualCompletionWhileLoopbackWaitsExchangesAndCommitsOnlyOnce() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    let flow = try await oauth.begin()
    let loopback = Task { try await oauth.waitForLoopbackCompletion() }
    await listener.waitUntilCallbackWaits()
    let manual = Task { try await oauth.completeManual(callbackURL: callback(for: flow)) }
    await transport.waitForRequests(1)
    await listener.deliver(URL(string: callback(for: flow))!)
    await assertCancelled(loopback)
    await transport.succeed(0, data: try tokenPayload(marker: "once"))

    let connected = try await manual.value
    let stored = try await keychain.codexSession()
    let requests = await transport.recordedRequests()
    XCTAssertEqual(stored, connected)
    XCTAssertEqual(requests.count, 1)
  }

  func testCancelSuspendedInOldListenerStopDoesNotClearNewBegin() async throws {
    let keychain = makeKeychain()
    let oldListener = SyntheticCodexListener()
    let newListener = SyntheticCodexListener()
    let listeners = CodexListenerSequence([oldListener, newListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    _ = try await oauth.begin()
    let stopGate = CodexRaceSignal()
    await oldListener.pauseStop(until: stopGate)
    let cancellation = Task { await oauth.cancel() }
    await oldListener.waitUntilStopStarts()

    let newFlow = try await oauth.begin()
    await stopGate.signal()
    await cancellation.value
    let completion = Task {
      try await oauth.completeManual(callbackURL: callback(for: newFlow))
    }
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "new-after-cancel"))
    let connected = try await completion.value
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, connected)
  }

  func testSupersededBeginResumingFromListenerStartCannotReplaceNewFlow() async throws {
    let keychain = makeKeychain()
    let oldListener = SyntheticCodexListener()
    let newListener = SyntheticCodexListener()
    let startGate = CodexRaceSignal()
    await oldListener.pauseStart(until: startGate)
    let listeners = CodexListenerSequence([oldListener, newListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    let oldBegin = Task { try await oauth.begin() }
    await oldListener.waitUntilStartStarts()

    let newFlow = try await oauth.begin()
    await startGate.signal()
    await assertCancelled(oldBegin)
    let completion = Task {
      try await oauth.completeManual(callbackURL: callback(for: newFlow))
    }
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "new-after-begin"))
    let connected = try await completion.value
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, connected)
  }

  func testDisconnectSuspendedInOldListenerStopDoesNotClearNewBegin() async throws {
    let keychain = makeKeychain()
    let oldListener = SyntheticCodexListener()
    let newListener = SyntheticCodexListener()
    let listeners = CodexListenerSequence([oldListener, newListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    _ = try await oauth.begin()
    let stopGate = CodexRaceSignal()
    await oldListener.pauseStop(until: stopGate)
    let disconnect = Task { try await oauth.disconnect() }
    await oldListener.waitUntilStopStarts()

    let newFlow = try await oauth.begin()
    await stopGate.signal()
    try await disconnect.value
    let completion = Task {
      try await oauth.completeManual(callbackURL: callback(for: newFlow))
    }
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "new-after-disconnect"))
    let connected = try await completion.value
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, connected)
  }

  func testLoginCannotCommitAfterOtherStoreDisconnectDuringListenerStop() async throws {
    let serviceName = "com.bex.tests.oauth-stop-disconnect.\(UUID())"
    let keychain = KeychainStore(service: serviceName, inMemory: true)
    let otherStore = KeychainStore(service: serviceName, inMemory: true)
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    let flow = try await oauth.begin()
    let stopGate = CodexRaceSignal()
    await listener.pauseStop(until: stopGate)
    let completion = Task { try await oauth.waitForLoopbackCompletion() }
    await listener.deliver(URL(string: callback(for: flow))!)
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "committed"))
    await listener.waitUntilStopStarts()
    let beforeCommit = try await keychain.codexSession()
    XCTAssertNil(beforeCommit)

    try await otherStore.deleteCodexSession()
    await stopGate.signal()

    await assertCancelled(completion)
    let stored = try await keychain.codexSession()
    XCTAssertNil(stored)
  }

  func testLoginStoppingOldListenerCannotCommitOrClearNewFlow() async throws {
    let keychain = makeKeychain()
    let oldListener = SyntheticCodexListener()
    let newListener = SyntheticCodexListener()
    let listeners = CodexListenerSequence([oldListener, newListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    let oldFlow = try await oauth.begin()
    let stopGate = CodexRaceSignal()
    await oldListener.pauseStop(until: stopGate)
    let oldCompletion = Task { try await oauth.waitForLoopbackCompletion() }
    await oldListener.deliver(URL(string: callback(for: oldFlow))!)
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "old-committed"))
    await oldListener.waitUntilStopStarts()
    let beforeCommit = try await keychain.codexSession()
    XCTAssertNil(beforeCommit)
    // cancel clears the old attempt synchronously before its own stop suspension.
    let cancellation = Task { await oauth.cancel() }
    await oldListener.waitForStopCalls(2)
    let newFlow = try await oauth.begin()
    await stopGate.signal()
    await cancellation.value
    await assertCancelled(oldCompletion)
    let newCompletion = Task {
      try await oauth.completeManual(callbackURL: callback(for: newFlow))
    }
    await transport.waitForRequests(2)
    await transport.succeed(1, data: try tokenPayload(marker: "new-committed"))
    let connected = try await newCompletion.value
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, connected)
  }

  func testDuplicateCallbackParametersFailWithoutNetworkAndAllowValidRetry() async throws {
    let keychain = makeKeychain()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport)
    let flow = try await oauth.begin()
    for duplicate in ["state=\(flow.state)", "code=other"] {
      do {
        _ = try await oauth.completeManual(callbackURL: callback(for: flow) + "&" + duplicate)
        XCTFail("duplicate callback parameters must be rejected")
      } catch {
        XCTAssertEqual(
          error as? BexError,
          .oauthFailure("OpenAI Codex callback contains duplicate parameters."))
      }
    }
    let before = await transport.recordedRequests()
    XCTAssertTrue(before.isEmpty)
    let completion = Task { try await oauth.completeManual(callbackURL: callback(for: flow)) }
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "valid-retry"))
    _ = try await completion.value
  }

  func testNoHostManualFallbackAndFreshSessionKeepExistingRequestBehavior() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener(startFails: true)
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    let flow = try await oauth.begin()
    XCTAssertFalse(flow.loopbackAvailable)
    let completion = Task { try await oauth.completeManual(callbackURL: callback(for: flow)) }
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "ordinary"))
    let connected = try await completion.value
    let client = OpenAICodexClient(keychain: keychain, transport: transport)
    let models = Task { try await client.fetchModels() }
    await transport.waitForRequests(2)
    await transport.succeed(1, data: modelsPayload)
    let result = try await models.value
    let requests = await transport.recordedRequests()
    XCTAssertEqual(result, [ModelOption(id: "test-model", name: "Test Model")])
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(connected.accessToken)")
  }

  func testScopedCleanupCannotCancelNewerFlowOnSameService() async throws {
    let keychain = makeKeychain()
    let listeners = CodexListenerSequence([SyntheticCodexListener(), SyntheticCodexListener()])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    let oldFlow = try await oauth.begin()
    let newFlow = try await oauth.begin()
    await oauth.cancel(flow: oldFlow)
    let completion = Task {
      try await oauth.completeManual(callbackURL: callback(for: newFlow))
    }
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "scoped-cleanup"))
    let connected = try await completion.value
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored, connected)
  }

  func testSettingsManualHandoverDoesNotCancelSharedLoginOrApplyOldWaiterError() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    var authorizationURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      authorizationURL = url
      return true
    }
    viewModel.connectCodex()
    await listener.waitUntilCallbackWaits()
    viewModel.callbackURL = try callback(forAuthorizationURL: XCTUnwrap(authorizationURL))
    viewModel.completeManualCallback()
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "settings-manual"))
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertFalse(viewModel.oauthInProgress)
    XCTAssertNil(viewModel.userVisibleError)
    XCTAssertEqual(viewModel.callbackURL, "")
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored?.refreshToken, "refresh-settings-manual")
  }

  func testSettingsRepeatedManualSubmissionKeepsOriginalCompletionCurrent() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    var authorizationURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      authorizationURL = url
      return true
    }
    viewModel.connectCodex()
    await listener.waitUntilCallbackWaits()
    viewModel.callbackURL = try callback(forAuthorizationURL: XCTUnwrap(authorizationURL))
    viewModel.completeManualCallback()
    await transport.waitForRequests(1)
    viewModel.completeManualCallback()
    await transport.succeed(0, data: try tokenPayload(marker: "settings-once"))
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertNil(viewModel.userVisibleError)
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  func testSettingsDisconnectTracksDeletionAndRejectsDelayedManualResult() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    var authorizationURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      authorizationURL = url
      return true
    }
    viewModel.connectCodex()
    await listener.waitUntilCallbackWaits()
    viewModel.callbackURL = try callback(forAuthorizationURL: XCTUnwrap(authorizationURL))
    viewModel.completeManualCallback()
    await transport.waitForRequests(1)
    viewModel.disconnectCodex()
    await transport.succeed(0, data: try tokenPayload(marker: "settings-late"))
    await viewModel.waitForCurrentWork()

    XCTAssertFalse(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Not connected")
    XCTAssertFalse(viewModel.oauthInProgress)
    XCTAssertNil(viewModel.codexExpiry)
    XCTAssertNil(viewModel.userVisibleError)
    let stored = try await keychain.codexSession()
    XCTAssertNil(stored)
  }

  func testSettingsOldBrowserFailureCannotOverwriteNewLoginAfterSuspendedCleanup() async throws {
    let keychain = makeKeychain()
    let firstListener = SyntheticCodexListener()
    let secondListener = SyntheticCodexListener()
    let stopGate = CodexRaceSignal()
    await firstListener.pauseStop(until: stopGate)
    let listeners = CodexListenerSequence([firstListener, secondListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    var openCount = 0
    var latestURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      openCount += 1
      latestURL = url
      return openCount != 1
    }
    viewModel.connectCodex()
    await firstListener.waitUntilStopStarts()
    viewModel.connectCodex()
    await secondListener.waitUntilCallbackWaits()
    await secondListener.deliver(URL(string:
      try callback(forAuthorizationURL: XCTUnwrap(latestURL)))!)
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "settings-new"))
    // The old browser failure resumes only after the newer flow has exchanged its code.
    await stopGate.signal()
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertNil(viewModel.userVisibleError)
    XCTAssertFalse(viewModel.oauthInProgress)
  }

  func testSettingsNewLoginWaitsForRequestedDisconnectAndOldTaskCannotClearIt() async throws {
    let keychain = makeKeychain()
    let firstListener = SyntheticCodexListener()
    let secondListener = SyntheticCodexListener()
    let listeners = CodexListenerSequence([firstListener, secondListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    var latestURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      latestURL = url
      return true
    }
    viewModel.connectCodex()
    await firstListener.waitUntilCallbackWaits()
    viewModel.disconnectCodex()
    viewModel.connectCodex()
    await secondListener.waitUntilCallbackWaits()
    await secondListener.deliver(URL(string:
      try callback(forAuthorizationURL: XCTUnwrap(latestURL)))!)
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "settings-reconnected"))
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertNil(viewModel.userVisibleError)
    let stored = try await keychain.codexSession()
    XCTAssertEqual(stored?.refreshToken, "refresh-settings-reconnected")
  }

  func testSettingsCloseThenReconnectOnSameModelResetsTransientState() async throws {
    let keychain = makeKeychain()
    let firstListener = SyntheticCodexListener()
    let secondListener = SyntheticCodexListener()
    let listeners = CodexListenerSequence([firstListener, secondListener])
    let transport = DeferredCodexTransport()
    let oauth = CodexOAuthService(
      keychain: keychain, transport: transport, makeListener: { listeners.next() })
    var latestURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      latestURL = url
      return true
    }
    viewModel.connectCodex()
    await firstListener.waitUntilCallbackWaits()
    XCTAssertTrue(viewModel.oauthInProgress)
    viewModel.close()
    XCTAssertFalse(viewModel.oauthInProgress)
    XCTAssertFalse(viewModel.manualCallbackRequired)
    XCTAssertEqual(viewModel.callbackURL, "")
    // The sidebar reuses this model. Reconnect before old cleanup finishes to verify
    // the scoped cleanup cannot cancel the newly started service attempt.
    viewModel.connectCodex()
    await secondListener.waitUntilCallbackWaits()
    await secondListener.deliver(URL(string:
      try callback(forAuthorizationURL: XCTUnwrap(latestURL)))!)
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "settings-reopened"))
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertNil(viewModel.userVisibleError)
    XCTAssertFalse(viewModel.oauthInProgress)
  }

  func testSettingsManualSubmitAfterLoopbackExchangeStartsKeepsItsResultCurrent() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    var authorizationURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      authorizationURL = url
      return true
    }
    viewModel.connectCodex()
    await listener.waitUntilCallbackWaits()
    let callback = try callback(forAuthorizationURL: XCTUnwrap(authorizationURL))
    await listener.deliver(URL(string: callback)!)
    await transport.waitForRequests(1) // Loopback has already claimed completion.
    viewModel.callbackURL = callback
    viewModel.completeManualCallback()
    await transport.succeed(0, data: try tokenPayload(marker: "loopback-first"))
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertFalse(viewModel.oauthInProgress)
    XCTAssertNil(viewModel.userVisibleError)
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  func testSettingsMalformedManualPasteDoesNotOrphanValidLoopbackCompletion() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    var authorizationURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      authorizationURL = url
      return true
    }
    viewModel.connectCodex()
    await listener.waitUntilCallbackWaits()
    let valid = try callback(forAuthorizationURL: XCTUnwrap(authorizationURL))
    viewModel.callbackURL = valid + "&code=duplicate"
    viewModel.completeManualCallback()
    // Both routes keep the logical login generation. Whether validation or callback
    // claims first, the valid callback remains eligible and there is one exchange.
    await listener.deliver(URL(string: valid)!)
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "loopback-after-invalid"))
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertNil(viewModel.userVisibleError)
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  func testSettingsDelayedLoopbackErrorCannotOverwriteSuccessfulManualLogin() async throws {
    let keychain = makeKeychain()
    let listener = SyntheticCodexListener()
    await listener.holdCallbackOnStop()
    let transport = DeferredCodexTransport()
    let oauth = makeService(keychain: keychain, transport: transport, listener: listener)
    var authorizationURL: URL?
    let viewModel = makeSettings(keychain: keychain, oauth: oauth) { url in
      authorizationURL = url
      return true
    }
    let becameConnected = CodexRaceSignal()
    let subscription = viewModel.$codexConnected.sink { connected in
      if connected { Task { await becameConnected.signal() } }
    }
    defer { subscription.cancel() }
    viewModel.connectCodex()
    await listener.waitUntilCallbackWaits()
    viewModel.callbackURL = try callback(forAuthorizationURL: XCTUnwrap(authorizationURL))
    viewModel.completeManualCallback()
    await transport.waitForRequests(1)
    await transport.succeed(0, data: try tokenPayload(marker: "manual-before-loopback-error"))
    await becameConnected.wait()
    await listener.failCallback(.timeout)
    await viewModel.waitForCurrentWork()

    XCTAssertTrue(viewModel.codexConnected)
    XCTAssertEqual(viewModel.codexStatus, "Connected")
    XCTAssertNil(viewModel.userVisibleError)
  }

  func testRealListenerWaitAfterStopFailsImmediatelyWithoutOpeningSocket() async throws {
    // Never call start(): this exercises the real terminal-state/continuation code
    // without constructing NWListener. A tiny timeout makes the old bug fail rather
    // than leave a five-minute waiter if this regression is reintroduced.
    let listener = CodexLoopbackListener(timeoutNanoseconds: 1)
    await listener.stop()
    do {
      _ = try await listener.waitForCallback()
      XCTFail("stopped listener must reject a late waiter")
    } catch {
      XCTAssertEqual(error as? BexError, .cancellation)
    }
  }

  func testRealListenerPrecancelledWaitFailsWithoutOpeningSocket() async throws {
    let listener = CodexLoopbackListener(timeoutNanoseconds: 1)
    let gate = CodexRaceSignal()
    let completion = Task {
      await gate.wait()
      return try await listener.waitForCallback()
    }
    completion.cancel()
    await gate.signal()
    await assertCancelled(completion)
    await listener.stop()
  }

  private func makeSettings(
    keychain: KeychainStore,
    oauth: CodexOAuthService,
    open: @escaping @MainActor (URL) -> Bool
  ) -> SettingsViewModel {
    let suite = "com.bex.tests.oauth-settings.\(UUID())"
    addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let defaults = UserDefaults(suiteName: suite)!
    return SettingsViewModel(
      preferences: PreferencesStore(defaults: defaults), keychain: keychain,
      grammar: ModelCatalogGrammarStub(catalogs: [:]), codexOAuth: oauth,
      applyAppearance: { _ in }, openAuthorizationURL: open)
  }

  private func callback(forAuthorizationURL url: URL) throws -> String {
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let state = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "state" })?.value)
    return "http://localhost:1455/auth/callback?code=synthetic-code&state=\(state)"
  }

  private var modelsPayload: Data {
    Data(#"{"models":[{"slug":"test-model","display_name":"Test Model","visibility":"list"}]}"#.utf8)
  }

  private func makeKeychain() -> KeychainStore {
    KeychainStore(service: "com.bex.tests.oauth-lifecycle.\(UUID())", inMemory: true)
  }

  private func makeService(
    keychain: KeychainStore,
    transport: DeferredCodexTransport,
    listener: SyntheticCodexListener = SyntheticCodexListener()
  ) -> CodexOAuthService {
    CodexOAuthService(keychain: keychain, transport: transport, makeListener: { listener })
  }

  private func callback(for flow: CodexOAuthFlow) -> String {
    "http://localhost:1455/auth/callback?code=synthetic-code&state=\(flow.state)"
  }

  private func session(marker: String, expired: Bool) -> CodexSession {
    CodexSession(
      accessToken: "access-\(marker)", refreshToken: "refresh-\(marker)",
      expiresAt: expired ? .distantPast : Date().addingTimeInterval(3_600),
      accountID: "same-synthetic-account")
  }

  private func tokenPayload(marker: String) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: [
      CodexOAuthService.accountClaimKey: ["chatgpt_account_id": "same-synthetic-account"],
      "synthetic_marker": marker,
    ])
    let encoded = payload.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return try JSONSerialization.data(withJSONObject: [
      "access_token": "synthetic.\(encoded).signature",
      "refresh_token": "refresh-\(marker)",
      "expires_in": 3_600,
    ])
  }

  private func assertCancelled<Value: Sendable>(
    _ task: Task<Value, any Error>, file: StaticString = #filePath, line: UInt = #line
  ) async {
    do {
      _ = try await task.value
      XCTFail("superseded/cancelled operation must fail", file: file, line: line)
    } catch {
      XCTAssertTrue(
        error is CancellationError || (error as? BexError) == .cancellation,
        "unexpected error: \(error)", file: file, line: line)
    }
  }
}

private actor CodexRaceSignal {
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if signalled { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func signal() {
    signalled = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

private actor DeferredCodexTransport: HTTPTransport {
  private var requests: [URLRequest] = []
  private var responses: [Int: CheckedContinuation<(Data, HTTPURLResponse), any Error>] = [:]
  private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let index = requests.count
    requests.append(request)
    // No cancellation handler: a late response must be rejected by production code.
    return try await withCheckedThrowingContinuation { continuation in
      responses[index] = continuation
      let ready = requestWaiters.filter { $0.0 <= requests.count }
      requestWaiters.removeAll { $0.0 <= requests.count }
      for (_, waiter) in ready { waiter.resume() }
    }
  }

  func waitForRequests(_ count: Int) async {
    if requests.count >= count { return }
    await withCheckedContinuation { requestWaiters.append((count, $0)) }
  }

  func succeed(_ index: Int, data: Data) {
    guard let continuation = responses.removeValue(forKey: index) else {
      preconditionFailure("response must follow a pending synthetic request")
    }
    let response = HTTPURLResponse(
      url: requests[index].url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    continuation.resume(returning: (data, response))
  }

  func recordedRequests() -> [URLRequest] { requests }
}

private actor SyntheticCodexListener: CodexOAuthListening {
  private let startFails: Bool
  private let startStarted = CodexRaceSignal()
  private let stopStarted = CodexRaceSignal()
  private let callbackWaits = CodexRaceSignal()
  private var startGate: CodexRaceSignal?
  private var stopGate: CodexRaceSignal?
  private var callback: URL?
  private var callbackContinuation: CheckedContinuation<URL, any Error>?
  private var stopped = false
  private var holdsCallbackOnStop = false
  private var stopCalls = 0
  private var stopCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

  init(startFails: Bool = false) { self.startFails = startFails }

  func start() async throws {
    await startStarted.signal()
    await startGate?.wait()
    // Deliberately returns after stop/cancellation when paused: begin must reject it.
    if startFails { throw BexError.connectionFailure("synthetic occupied callback port") }
  }

  func waitForCallback() async throws -> URL {
    if let callback {
      await callbackWaits.signal()
      return callback
    }
    if stopped { throw BexError.cancellation }
    return try await withCheckedThrowingContinuation { continuation in
      callbackContinuation = continuation
      // Publish readiness only after installing the waiter. Tests must not race a
      // signal emitted before registration and accidentally miss the intended path.
      Task { await callbackWaits.signal() }
    }
  }

  func stop() async {
    stopCalls += 1
    let ready = stopCallWaiters.filter { $0.0 <= stopCalls }
    stopCallWaiters.removeAll { $0.0 <= stopCalls }
    for (_, waiter) in ready { waiter.resume() }
    await stopStarted.signal()
    await stopGate?.wait()
    stopped = true
    if holdsCallbackOnStop { return }
    let continuation = callbackContinuation
    callbackContinuation = nil
    continuation?.resume(throwing: BexError.cancellation)
  }

  func deliver(_ url: URL) {
    callback = url
    let continuation = callbackContinuation
    callbackContinuation = nil
    continuation?.resume(returning: url)
  }

  func holdCallbackOnStop() { holdsCallbackOnStop = true }
  func failCallback(_ error: BexError) {
    let continuation = callbackContinuation
    callbackContinuation = nil
    continuation?.resume(throwing: error)
  }
  func pauseStart(until gate: CodexRaceSignal) { startGate = gate }
  func pauseStop(until gate: CodexRaceSignal) { stopGate = gate }
  func waitForStopCalls(_ count: Int) async {
    if stopCalls >= count { return }
    await withCheckedContinuation { stopCallWaiters.append((count, $0)) }
  }
  func waitUntilStartStarts() async { await startStarted.wait() }
  func waitUntilStopStarts() async { await stopStarted.wait() }
  func waitUntilCallbackWaits() async { await callbackWaits.wait() }
}

/// Only the synchronous factory needs a lock; it never holds one across an await.
private final class CodexListenerSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var listeners: [SyntheticCodexListener]

  init(_ listeners: [SyntheticCodexListener]) { self.listeners = listeners }

  func next() -> any CodexOAuthListening {
    lock.lock()
    defer { lock.unlock() }
    precondition(!listeners.isEmpty)
    return listeners.removeFirst()
  }
}
