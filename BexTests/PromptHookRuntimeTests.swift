import Foundation
import XCTest

@testable import Bex

final class PromptApprovalStoreTests: XCTestCase {
  func testReceiptIsBoundOneUseRevocableAndExpires() async throws {
    let directory = temporaryDirectory("receipts")
    let store = PromptApprovalStore(
      directoryURL: directory,
      timeToLive: 0.01
    )

    _ = try await store.issue(
      client: .claudeCode,
      text: "corrected",
      sessionID: "session",
      cwd: "/tmp/project"
    )
    let wrongClient = try await store.consume(
      client: .codex,
      text: "corrected",
      sessionID: "session",
      cwd: "/tmp/project"
    )
    XCTAssertFalse(wrongClient)
    let wrongText = try await store.consume(
      client: .claudeCode,
      text: "wrong",
      sessionID: "session",
      cwd: "/tmp/project"
    )
    XCTAssertFalse(wrongText)
    let wrongSession = try await store.consume(
      client: .claudeCode,
      text: "corrected",
      sessionID: "other",
      cwd: "/tmp/project"
    )
    XCTAssertFalse(wrongSession)
    let wrongCWD = try await store.consume(
      client: .claudeCode,
      text: "corrected",
      sessionID: "session",
      cwd: "/other"
    )
    XCTAssertFalse(wrongCWD)
    let accepted = try await store.consume(
      client: .claudeCode,
      text: "corrected",
      sessionID: "session",
      cwd: "/tmp/project"
    )
    XCTAssertTrue(accepted)
    let duplicate = try await store.consume(
      client: .claudeCode,
      text: "corrected",
      sessionID: "session",
      cwd: "/tmp/project"
    )
    XCTAssertFalse(duplicate)

    let revoked = try await store.issue(
      client: .codex,
      text: "revoked",
      sessionID: nil,
      cwd: nil
    )
    try await store.revoke(id: revoked)
    let revokedResult = try await store.consume(
      client: .codex,
      text: "revoked",
      sessionID: nil,
      cwd: nil
    )
    XCTAssertFalse(revokedResult)

    _ = try await store.issue(
      client: .codex,
      text: "expired",
      sessionID: nil,
      cwd: nil
    )
    try await Task.sleep(for: .milliseconds(20))
    let expiredResult = try await store.consume(
      client: .codex,
      text: "expired",
      sessionID: nil,
      cwd: nil
    )
    XCTAssertFalse(expiredResult)
  }

  func testConcurrentReceiptConsumptionAllowsExactlyOneWinner() async throws {
    let store = PromptApprovalStore(directoryURL: temporaryDirectory("concurrent-receipts"))
    _ = try await store.issue(
      client: .claudeCode,
      text: "once",
      sessionID: "session",
      cwd: "/tmp"
    )

    async let first = store.consume(
      client: .claudeCode,
      text: "once",
      sessionID: "session",
      cwd: "/tmp"
    )
    async let second = store.consume(
      client: .claudeCode,
      text: "once",
      sessionID: "session",
      cwd: "/tmp"
    )
    let winners = try await [first, second].filter { $0 }
    XCTAssertEqual(winners.count, 1)
  }
}

final class ClaudePromptSourceTests: XCTestCase {
  func testSystemOriginTranscriptEntrySkippedUntilTypedEntryAppears() throws {
    let transcriptURL = temporaryDirectory("claude-transcript")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // A plain-text prompt (no injected wrapper prefix) so the transcript path does the work.
    let prompt = "Summarize the results of the run."
    let input = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: prompt,
      sessionID: "session-123",
      cwd: "/tmp/project",
      promptID: "prompt-123",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )

    // Matched entry is machine-sourced (non-human origin) -> skip.
    try transcriptEntry(
      prompt: prompt,
      sessionID: input.sessionID,
      promptID: try XCTUnwrap(input.promptID),
      promptSource: "system",
      origin: "task-notification"
    ).write(to: transcriptURL)
    XCTAssertTrue(ClaudePromptSource.isNonInteractivePrompt(input))

    // Appending a newer, genuinely-typed entry for the same prompt/session/promptID means the
    // newest matching transcript entry is human-typed, so it must gate again.
    var transcript = try Data(contentsOf: transcriptURL)
    transcript.append(0x0A)
    transcript.append(
      try transcriptEntry(
        prompt: prompt,
        sessionID: input.sessionID,
        promptID: try XCTUnwrap(input.promptID),
        promptSource: "typed",
        origin: "human"
      )
    )
    try transcript.write(to: transcriptURL)
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(input))
  }

  func testSidechainSubAgentPromptIsNonInteractive() throws {
    let transcriptURL = temporaryDirectory("claude-transcript-sidechain")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let prompt = "Summarize the findings from the sub-agent run."
    let input = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: prompt,
      sessionID: "session-789",
      cwd: "/tmp/project",
      promptID: "prompt-789",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )

    // Sidechain sub-agent entries are non-interactive regardless of promptSource/origin.
    try transcriptEntry(
      prompt: prompt,
      sessionID: input.sessionID,
      promptID: try XCTUnwrap(input.promptID),
      promptSource: "typed",
      origin: "human",
      isSidechain: true
    ).write(to: transcriptURL)
    XCTAssertTrue(ClaudePromptSource.isNonInteractivePrompt(input))
  }

  func testSlashCommandWrapperIsNonInteractive() throws {
    // The real-world bug: slash-command wrapper entries (e.g. the /model command) carry NO
    // promptSource and NO origin — no machine marker at all — yet must not reach the gate.
    let transcriptURL = temporaryDirectory("claude-transcript-command")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let wrapper =
      "<command-name>/model</command-name>\n"
      + "<command-message>model</command-message>\n<command-args></command-args>"
    let input = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: wrapper,
      sessionID: "session-cmd",
      cwd: "/tmp/project",
      promptID: "prompt-cmd",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )
    try transcriptEntry(
      prompt: wrapper,
      sessionID: input.sessionID,
      promptID: try XCTUnwrap(input.promptID)
    ).write(to: transcriptURL)
    XCTAssertTrue(ClaudePromptSource.isNonInteractivePrompt(input))
  }

  func testTaskNotificationIsNonInteractiveWithoutTranscriptEntry() throws {
    // The reported bug: task-notifications fire the hook but current Claude Code does NOT record
    // them as a matchable transcript entry, so the transcript lookup can't find them. They must
    // still be recognized (by prompt shape) and skipped — even when no matching entry exists.
    let notification =
      "<task-notification>\n<task-id>agent-1</task-id>\n<status>completed</status>\n"
      + "</task-notification>"

    let transcriptURL = temporaryDirectory("claude-transcript-tasknotif")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Transcript contains only an unrelated tool-result entry — no notification entry at all.
    let unrelatedEntry: [String: Any] = [
      "type": "user", "sessionId": "session-tn",
      "message": ["role": "user", "content": [["type": "tool_result", "content": "x"]]],
    ]
    var unrelated = try JSONSerialization.data(withJSONObject: unrelatedEntry, options: [.sortedKeys])
    unrelated.append(0x0A)
    try unrelated.write(to: transcriptURL)

    let withUnrelatedTranscript = HookInput(
      hookEventName: "UserPromptSubmit", prompt: notification, sessionID: "session-tn",
      cwd: "/tmp/project", promptID: "p-tn", integrationID: nil, turnID: nil,
      transcriptPath: transcriptURL.path)
    XCTAssertTrue(ClaudePromptSource.isNonInteractivePrompt(withUnrelatedTranscript))

    // And with no transcript path at all.
    let withoutTranscript = HookInput(
      hookEventName: "UserPromptSubmit", prompt: notification, sessionID: "session-tn",
      cwd: "/tmp/project", promptID: "p-tn", integrationID: nil, turnID: nil, transcriptPath: nil)
    XCTAssertTrue(ClaudePromptSource.isNonInteractivePrompt(withoutTranscript))
  }

  func testArrayStyleContentEntryIsMatchedAndClassified() throws {
    // A transcript entry whose content is an array of text blocks must still be matched to the
    // prompt (text reconstructed) and classified — here a sidechain sub-agent entry -> skip.
    let prompt = "Investigate the failing test and report back."
    let transcriptURL = temporaryDirectory("claude-transcript-arraycontent")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let entry: [String: Any] = [
      "type": "user", "sessionId": "session-arr", "promptId": "p-arr", "isSidechain": true,
      "message": ["role": "user", "content": [["type": "text", "text": prompt]]],
    ]
    var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    data.append(0x0A)
    try data.write(to: transcriptURL)

    let input = HookInput(
      hookEventName: "UserPromptSubmit", prompt: prompt, sessionID: "session-arr",
      cwd: "/tmp/project", promptID: "p-arr", integrationID: nil, turnID: nil,
      transcriptPath: transcriptURL.path)
    XCTAssertTrue(ClaudePromptSource.isNonInteractivePrompt(input))
  }

  func testGenuineTypedPromptIsGated() throws {
    let transcriptURL = temporaryDirectory("claude-transcript-typed")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let prompt = "Please refactor this function to be async."
    let input = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: prompt,
      sessionID: "session-321",
      cwd: "/tmp/project",
      promptID: "prompt-321",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )

    // This is the critical regression guard: a real, human-typed prompt must still be gated.
    try transcriptEntry(
      prompt: prompt,
      sessionID: input.sessionID,
      promptID: try XCTUnwrap(input.promptID),
      promptSource: "typed",
      origin: "human"
    ).write(to: transcriptURL)
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(input))
  }

  func testIdentityMismatchIsGated() throws {
    let transcriptURL = temporaryDirectory("claude-transcript-identity")
      .appendingPathComponent("session.jsonl")
    try FileManager.default.createDirectory(
      at: transcriptURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    // A plain-text prompt (no injected wrapper prefix) so the transcript identity check is what
    // decides the outcome, not the fast path.
    let recordedPrompt = "Investigate the earlier failure and report back."
    try transcriptEntry(
      prompt: recordedPrompt,
      sessionID: "different-session",
      promptID: "different-prompt",
      promptSource: "system",
      origin: "task-notification"
    ).write(to: transcriptURL)

    let input = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: recordedPrompt,
      sessionID: "session-456",
      cwd: "/tmp/project",
      promptID: "prompt-456",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(input))

    // Same session and content, but a different promptId, is also an identity mismatch.
    let matchingSessionButDifferentPromptID = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: recordedPrompt,
      sessionID: "different-session",
      cwd: "/tmp/project",
      promptID: "not-the-recorded-prompt-id",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(matchingSessionButDifferentPromptID))

    // Same session and promptId, but different content, is also an identity mismatch.
    let matchingSessionButDifferentContent = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: "not the recorded content",
      sessionID: "different-session",
      cwd: "/tmp/project",
      promptID: "different-prompt",
      integrationID: nil,
      turnID: nil,
      transcriptPath: transcriptURL.path
    )
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(matchingSessionButDifferentContent))
  }

  func testMissingOrUnreadableTranscriptIsGated() throws {
    let noTranscriptInput = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: "hello",
      sessionID: "session-000",
      cwd: "/tmp/project",
      promptID: nil,
      integrationID: nil,
      turnID: nil,
      transcriptPath: nil
    )
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(noTranscriptInput))

    let emptyTranscriptPathInput = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: "hello",
      sessionID: "session-000",
      cwd: "/tmp/project",
      promptID: nil,
      integrationID: nil,
      turnID: nil,
      transcriptPath: ""
    )
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(emptyTranscriptPathInput))

    let unreadableTranscriptInput = HookInput(
      hookEventName: "UserPromptSubmit",
      prompt: "hello",
      sessionID: "session-000",
      cwd: "/tmp/project",
      promptID: nil,
      integrationID: nil,
      turnID: nil,
      transcriptPath: temporaryDirectory("claude-transcript-missing")
        .appendingPathComponent("does-not-exist.jsonl").path
    )
    XCTAssertFalse(ClaudePromptSource.isNonInteractivePrompt(unreadableTranscriptInput))
  }

  private func transcriptEntry(
    prompt: String,
    sessionID: String,
    promptID: String,
    promptSource: String? = nil,
    origin: String? = nil,
    isSidechain: Bool? = nil
  ) throws -> Data {
    var object: [String: Any] = [
      "type": "user",
      "sessionId": sessionID,
      "promptId": promptID,
      "message": [
        "role": "user",
        "content": prompt,
      ],
    ]
    // Real command/meta entries carry neither field, so include them only when set.
    if let promptSource {
      object["promptSource"] = promptSource
    }
    if let origin {
      object["origin"] = ["kind": origin]
    }
    if let isSidechain {
      object["isSidechain"] = isSidechain
    }
    return try JSONSerialization.data(
      withJSONObject: object,
      options: [.sortedKeys]
    )
  }
}

/// Fixtures are real prompts harvested from Claude Code transcripts, not invented ones —
/// an earlier hand-written sample set scored 30/30 for a rule that then scored 22/55 on
/// these. See `KoreanPrompt` for why counting Hangul characters cannot do this job.
final class KoreanPromptTests: XCTestCase {
  func testKoreanRequestsAreSkippedEvenWhenFullOfEnglishTechnicalWords() {
    let korean = [
      "rebase 하고 나서 deploy 해줘",
      "latest 만 비교해도 충분할까?",
      "draft PR 잇지 않아?",
      "jira comment 에도 상황을 남기고, close 하면 되는걸까?",
      "GrammarPrompts.swift 에서 promptSafeSystem 고쳐줘",
      "PromptTechnicalSpanProtector 테스트 추가해줘",
      "codex 왤케 안되고 잇어",
      "ce gcp 을 disable 할래",
      "https://github.com/clumio/cdf/pull/69237 은 머지 되엇어.",
      "모델을 terra로 바꾸고 effort는 low로 설정해줘",
    ]
    for prompt in korean {
      XCTAssertTrue(KoreanPrompt.isMainlyKorean(prompt), "should skip: \(prompt)")
    }
  }

  /// Verbless prompts: particles on English words are the only Korean signal here.
  func testParticlesAloneMarkAPromptAsKorean() {
    XCTAssertTrue(KoreanPrompt.isMainlyKorean("prod 랑 stage 만."))
    XCTAssertTrue(KoreanPrompt.isMainlyKorean("prod eu, uw1, au 는?"))
    XCTAssertTrue(KoreanPrompt.isMainlyKorean("바로 옵션 b"))
  }

  func testEnglishBorrowingAKoreanNounIsStillChecked() {
    let english = [
      "Could you check the 잔여 items in the list?",
      "Please add a 검증 step before the deploy.",
      "The build is failing because of a 권한 issue.",
      "Is there any 부작용 if I change the default model?",
      "CCM은 arena별로 개별 토글 => why should we do this? is it aws way?",
      "confirm the KMS binding with gcloud. 그런데 지금 배포하는거랑도 관련잇어?",
      "yes, create PR and close #68969. 그리고 다시 파이프라인을 돌려야 하지 않아?",
    ]
    for prompt in english {
      XCTAssertFalse(KoreanPrompt.isMainlyKorean(prompt), "should gate: \(prompt)")
    }
  }

  /// The failure that matters: a Korean instruction wrapping a block of the user's own
  /// English must still reach Bex, or the English is silently never checked.
  func testKoreanInstructionAroundAnEnglishDraftIsStillChecked() {
    let prompt = """
      봐봐. slack draft 을 작성해줘.
      ----
      i have talked with jachan.
      1. They just want to use "claude -p" in the jenkins pipeline.
      2. The claude does not need any permision and any tokens.
      """
    XCTAssertFalse(KoreanPrompt.isMainlyKorean(prompt))
  }

  func testTextWithoutHangulIsNeverTreatedAsKorean() {
    XCTAssertFalse(KoreanPrompt.isMainlyKorean("Fix the deploy pipeline please."))
    XCTAssertFalse(KoreanPrompt.isMainlyKorean(""))
    XCTAssertFalse(KoreanPrompt.isMainlyKorean("git rebase -i main && git push"))
  }
}

final class PromptGateIPCServerTests: XCTestCase {
  func testAuthenticatedReviewApprovalAndAcknowledgementRoundTrip() async throws {
    let rendezvous = temporaryDirectory("ipc")
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName)
    let server = PromptGateIPCServer(rendezvousURL: rendezvous, deadlineSeconds: 5)
    let recorder = IPCRequestRecorder()
    await server.setHandlers(
      onRequest: { request in
        await recorder.record(request)
        return true
      },
      onInvalidation: { requestID in
        await recorder.invalidate(requestID)
      }
    )
    try await server.start()
    defer { Task { await server.stop() } }

    let client = PromptGateIPCClient(rendezvousURL: rendezvous)
    let request = makeHookRequest()
    let responseTask = Task { try await client.submit(request) }
    await recorder.waitForRequest()

    let completionTask = Task {
      try await server.complete(
        requestID: request.requestID,
        outcome: .approved,
        awaitAcknowledgement: true
      )
    }
    let response = try await responseTask.value
    XCTAssertEqual(response.outcome, .approved)
    let token = try XCTUnwrap(response.acknowledgmentToken)
    try await client.acknowledge(requestID: request.requestID, token: token)
    try await completionTask.value
    let recordedRequest = await recorder.request()
    XCTAssertEqual(recordedRequest?.prompt, "Original prompt")
  }

  func testBypassCompletesWithoutBlockingAcknowledgment() async throws {
    let rendezvous = temporaryDirectory("ipc-bypass")
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName)
    let server = PromptGateIPCServer(rendezvousURL: rendezvous, deadlineSeconds: 5)
    let recorder = IPCRequestRecorder()
    await server.setHandlers(
      onRequest: { request in
        await recorder.record(request)
        return true
      },
      onInvalidation: { _ in }
    )
    try await server.start()
    defer { Task { await server.stop() } }

    let client = PromptGateIPCClient(rendezvousURL: rendezvous)
    let request = makeHookRequest()
    let responseTask = Task { try await client.submit(request) }
    await recorder.waitForRequest()

    try await server.complete(
      requestID: request.requestID,
      outcome: .bypassed,
      awaitAcknowledgement: false
    )
    let response = try await responseTask.value
    XCTAssertEqual(response.outcome, .bypassed)
    XCTAssertNil(response.acknowledgmentToken)
  }

  func testOMPApprovalBindsPromptAndDeliveryAcknowledgmentToIntegration() async throws {
    let rendezvous = temporaryDirectory("ipc-omp")
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName)
    let server = PromptGateIPCServer(rendezvousURL: rendezvous, deadlineSeconds: 5)
    let recorder = IPCRequestRecorder()
    await server.setHandlers(
      onRequest: { request in
        await recorder.record(request)
        return true
      },
      onInvalidation: { _ in }
    )
    try await server.start()
    defer { Task { await server.stop() } }

    let client = PromptGateIPCClient(rendezvousURL: rendezvous)
    let request = HookReviewRequest(
      client: .ohMyPi,
      integrationID: "omp-integration",
      prompt: "Original prompt",
      sessionID: "omp-session",
      cwd: "/tmp/project",
      helperPID: .max
    )
    let responseTask = Task { try await client.submit(request) }
    await recorder.waitForRequest()
    let completionTask = Task {
      try await server.complete(
        requestID: request.requestID,
        outcome: .approved,
        awaitAcknowledgement: true,
        approvedPrompt: "Approved correction",
        integrationID: "omp-integration"
      )
    }
    let response = try await responseTask.value
    XCTAssertEqual(response.integrationID, "omp-integration")
    XCTAssertEqual(response.approvedPrompt, "Approved correction")
    let acknowledgmentToken = try XCTUnwrap(response.acknowledgmentToken)
    let deliveryToken = try XCTUnwrap(response.deliveryToken)
    try await client.acknowledge(
      requestID: request.requestID,
      token: acknowledgmentToken,
      integrationID: "omp-integration",
      deliveryToken: deliveryToken,
      deliveryStatus: "delivered"
    )
    try await completionTask.value
  }

  func testIPCRejectsWrongAuthenticationAndSecondConcurrentReview() async throws {
    let rendezvous = temporaryDirectory("ipc-rejection")
      .appendingPathComponent(HookProtocolConstants.rendezvousFileName)
    let server = PromptGateIPCServer(rendezvousURL: rendezvous, deadlineSeconds: 5)
    let recorder = IPCRequestRecorder()
    await server.setHandlers(
      onRequest: { request in
        await recorder.record(request)
        return true
      },
      onInvalidation: { _ in }
    )
    try await server.start()
    defer { Task { await server.stop() } }

    let client = PromptGateIPCClient(rendezvousURL: rendezvous)
    let firstRequest = makeHookRequest()
    let firstTask = Task { try await client.submit(firstRequest) }
    await recorder.waitForRequest()

    let second = try await client.submit(makeHookRequest())
    XCTAssertEqual(second.outcome, .failed)
    try await server.complete(
      requestID: firstRequest.requestID,
      outcome: .cancelled,
      awaitAcknowledgement: false
    )
    let firstResponse = try await firstTask.value
    XCTAssertEqual(firstResponse.outcome, .cancelled)

    var badRendezvous = try client.loadRendezvous()
    badRendezvous = HookRendezvous(
      version: badRendezvous.version,
      port: badRendezvous.port,
      authenticationToken: "wrong-token",
      serverPID: badRendezvous.serverPID,
      createdAt: badRendezvous.createdAt
    )
    let body = try JSONEncoder().encode(
      HookReviewEnvelope(
        version: HookProtocolConstants.version,
        authenticationToken: badRendezvous.authenticationToken,
        request: makeHookRequest()
      ))
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:\(badRendezvous.port)\(HookProtocolConstants.reviewPath)")!
    )
    request.httpMethod = "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (_, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
  }
}

final class HookInstallationManagerTests: XCTestCase {
  func testBundledDebugHelperPassesSignaturePolicy() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/\(HookProtocolConstants.helperName)"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    try HookInstallationManager.verifyHelperSignature(helper)
  }

  func testInstallIsIdempotentPreservesUnrelatedConfigModeAndRestoresExactBaseline() async throws {
    let fixture = try InstallerFixture()
    let path = await fixture.manager.configuredPath(for: .claudeCode)
    let baseline = Data(
      "{\n  \"unrelated\" : {\"keep\":true},\n  \"hooks\" : {\"OtherEvent\":[{\"x\":1}]}\n}\n".utf8)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try baseline.write(to: path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o640],
      ofItemAtPath: path.path
    )

    try await fixture.manager.install(.claudeCode)
    try await fixture.manager.install(.claudeCode)
    let installed = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    )
    XCTAssertEqual((installed["unrelated"] as? [String: Bool])?["keep"], true)
    let handlers = try hookHandlers(installed)
    XCTAssertEqual(handlers.count, 1)
    let mode = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
    )
    XCTAssertEqual(mode.intValue, 0o640)

    try await fixture.manager.uninstall(.claudeCode)
    XCTAssertEqual(try Data(contentsOf: path), baseline)
    let restoredMode = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
    )
    XCTAssertEqual(restoredMode.intValue, 0o640)
  }

  func testReviewedInstallSupportsSymlinkedConfigurationAndPreservesLinkOnUninstall()
    async throws
  {
    let fixture = try InstallerFixture()
    let configuredPath = await fixture.manager.configuredPath(for: .claudeCode)
    let targetDirectory = fixture.root.appendingPathComponent("dotfiles")
    let target = targetDirectory.appendingPathComponent("settings-company.json")
    let baseline = Data("{\"unrelated\":true}\n".utf8)
    try FileManager.default.createDirectory(
      at: configuredPath.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: targetDirectory,
      withIntermediateDirectories: true
    )
    try baseline.write(to: target)
    try FileManager.default.createSymbolicLink(at: configuredPath, withDestinationURL: target)

    let descriptor = try await fixture.manager.resolve(.claudeCode)
    XCTAssertEqual(descriptor.configurationURL.path, target.path)
    let installReview = try await fixture.manager.prepare(.install, for: descriptor)
    XCTAssertTrue(installReview.actions.contains { $0.path == target.path })
    _ = try await fixture.manager.apply(reviewID: installReview.id)

    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: configuredPath.path),
      target.path
    )
    XCTAssertEqual(try hookHandlers(readRoot(target)).count, 1)

    let installedDescriptors = await fixture.manager.installedDescriptors()
    let installedDescriptor = try XCTUnwrap(
      installedDescriptors.first(where: { $0.client == .claudeCode })
    )
    let uninstallReview = try await fixture.manager.prepare(.uninstall, for: installedDescriptor)
    _ = try await fixture.manager.apply(reviewID: uninstallReview.id)

    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: configuredPath.path),
      target.path
    )
    XCTAssertEqual(try Data(contentsOf: target), baseline)
  }

  func testApplyRejectsRetargetedConfigurationSymlink() async throws {
    let fixture = try InstallerFixture()
    let configuredPath = await fixture.manager.configuredPath(for: .claudeCode)
    let targetDirectory = fixture.root.appendingPathComponent("dotfiles")
    let originalTarget = targetDirectory.appendingPathComponent("original.json")
    let replacementTarget = targetDirectory.appendingPathComponent("replacement.json")
    let baseline = Data("{\"unrelated\":true}\n".utf8)
    try FileManager.default.createDirectory(
      at: configuredPath.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: targetDirectory,
      withIntermediateDirectories: true
    )
    try baseline.write(to: originalTarget)
    try baseline.write(to: replacementTarget)
    try FileManager.default.createSymbolicLink(
      at: configuredPath,
      withDestinationURL: originalTarget
    )
    let descriptor = try await fixture.manager.resolve(.claudeCode)
    let review = try await fixture.manager.prepare(.install, for: descriptor)

    try FileManager.default.removeItem(at: configuredPath)
    try FileManager.default.createSymbolicLink(
      at: configuredPath,
      withDestinationURL: replacementTarget
    )

    do {
      _ = try await fixture.manager.apply(reviewID: review.id)
      XCTFail("Expected changed symlink rejection")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("symlink changed after review"))
    }
    XCTAssertEqual(try Data(contentsOf: originalTarget), baseline)
    XCTAssertEqual(try Data(contentsOf: replacementTarget), baseline)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.helperURL.path))
  }

  func testUninstallAfterLaterEditsRemovesOnlyBexHandler() async throws {
    let fixture = try InstallerFixture()
    try await fixture.manager.install(.codex)
    let path = await fixture.manager.configuredPath(for: .codex)
    var root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    )
    root["addedLater"] = ["preserve": true]
    let changed = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    try changed.write(to: path)

    try await fixture.manager.uninstall(.codex)
    let remaining = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
    )
    XCTAssertEqual((remaining["addedLater"] as? [String: Bool])?["preserve"], true)
    XCTAssertTrue(try hookHandlers(remaining).isEmpty)
  }

  func testStatusAllowsUnrelatedConfigChangesButRejectsOwnedHookChanges() async throws {
    let fixture = try InstallerFixture()
    let descriptor = try await fixture.manager.resolve(.claudeCode)
    let installReview = try await fixture.manager.prepare(.install, for: descriptor)
    _ = try await fixture.manager.apply(reviewID: installReview.id)

    var root = try readRoot(descriptor.configurationURL)
    root["addedLater"] = ["preserve": true]
    var changed = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys]
    )
    changed.append(0x0A)
    try changed.write(to: descriptor.configurationURL)

    let usableStatus = await fixture.manager.status(for: descriptor.id)
    XCTAssertTrue(usableStatus.permitsReceipt)
    XCTAssertEqual(usableStatus, .installedUnconfirmed)

    var hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
    hooks["UserPromptSubmit"] = []
    root["hooks"] = hooks
    var missingOwnedHook = try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys]
    )
    missingOwnedHook.append(0x0A)
    try missingOwnedHook.write(to: descriptor.configurationURL)

    guard case .needsRepair(let detail) = await fixture.manager.status(for: descriptor.id) else {
      return XCTFail("Expected missing owned hook to require repair")
    }
    XCTAssertTrue(detail.contains("Bex-owned hook fragment"))
  }

  func testInstallerRefusesMalformedShapesWithoutChangingBytes() async throws {
    for invalid in [
      Data("[]".utf8),
      Data("{\"hooks\":[]}".utf8),
      Data("{\"hooks\":{\"UserPromptSubmit\":{}}}".utf8),
    ] {
      let fixture = try InstallerFixture()
      let path = await fixture.manager.configuredPath(for: .claudeCode)
      try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try invalid.write(to: path)
      do {
        try await fixture.manager.install(.claudeCode)
        XCTFail("Expected malformed config refusal")
      } catch {}
      XCTAssertEqual(try Data(contentsOf: path), invalid)
    }
  }

  func testMidTransactionFailureRestoresWritesAndCreatedDirectories() async throws {
    let fixture = try InstallerFixture(
      transactionFaultInjector: { writeIndex, _ in
        if writeIndex == 1 {
          throw BexError.storageFailure("Injected transaction failure")
        }
      }
    )
    let descriptor = try await fixture.manager.resolve(.claudeCode)
    let review = try await fixture.manager.prepare(.install, for: descriptor)

    do {
      _ = try await fixture.manager.apply(reviewID: review.id)
      XCTFail("Expected injected transaction failure")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Injected transaction failure"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.configurationURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.helperURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.supportDirectory.path))
  }

  func testRollbackIdentityMismatchReturnsExplicitPartialFailure() async throws {
    let tampered = Data("tampered helper".utf8)
    let fixture = try InstallerFixture(
      transactionFaultInjector: { writeIndex, installedURL in
        guard writeIndex == 1, let installedURL else { return }
        try FileManager.default.removeItem(at: installedURL)
        try tampered.write(to: installedURL)
        throw BexError.storageFailure("Injected transaction failure")
      }
    )
    let descriptor = try await fixture.manager.resolve(.claudeCode)
    let review = try await fixture.manager.prepare(.install, for: descriptor)
    let result = try await fixture.manager.apply(reviewID: review.id)

    XCTAssertEqual(result.completed, [descriptor.helperURL.path])
    XCTAssertTrue(result.restored.isEmpty)
    XCTAssertTrue(result.failed.contains(descriptor.helperURL.path))
    XCTAssertEqual(try Data(contentsOf: descriptor.helperURL), tampered)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.configurationURL.path))
  }

  func testApplyRejectsSameBytesAtDifferentTargetIdentityWithoutChangingAnything() async throws {
    let fixture = try InstallerFixture()
    let descriptor = try await fixture.manager.resolve(.claudeCode)
    let baseline = Data("{\"unrelated\":true}\n".utf8)
    try FileManager.default.createDirectory(
      at: descriptor.configurationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try baseline.write(to: descriptor.configurationURL)
    let review = try await fixture.manager.prepare(.install, for: descriptor)

    try FileManager.default.removeItem(at: descriptor.configurationURL)
    try baseline.write(to: descriptor.configurationURL)

    do {
      _ = try await fixture.manager.apply(reviewID: review.id)
      XCTFail("Expected target identity rejection")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Nothing changed"))
    }
    XCTAssertEqual(try Data(contentsOf: descriptor.configurationURL), baseline)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.helperURL.path))
  }

  func testApplyRejectsReplacedAncestorWithoutChangingAnything() async throws {
    let fixture = try InstallerFixture()
    let descriptor = try await fixture.manager.resolve(.claudeCode)
    let baseline = Data("{\"unrelated\":true}\n".utf8)
    let configurationDirectory = descriptor.configurationURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: configurationDirectory,
      withIntermediateDirectories: true
    )
    try baseline.write(to: descriptor.configurationURL)
    let review = try await fixture.manager.prepare(.install, for: descriptor)

    let displacedDirectory = fixture.root.appendingPathComponent("displaced-claude")
    try FileManager.default.moveItem(at: configurationDirectory, to: displacedDirectory)
    try FileManager.default.createDirectory(
      at: configurationDirectory, withIntermediateDirectories: true)
    try baseline.write(to: descriptor.configurationURL)

    do {
      _ = try await fixture.manager.apply(reviewID: review.id)
      XCTFail("Expected ancestor identity rejection")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("ancestor identity changed"))
    }
    XCTAssertEqual(try Data(contentsOf: descriptor.configurationURL), baseline)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.helperURL.path))
  }

  func testNoncanonicalPreexistingHandlerCannotBecomeItsOwnRollbackBaseline() async throws {
    let fixture = try InstallerFixture()
    let path = await fixture.manager.configuredPath(for: .codex)
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let command = "exec \(HookInstallationManager.shellQuote(fixture.stableHelperURL.path)) codex"
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let preexisting = Data(
      "{ \"other\": 1, \"hooks\": { \"UserPromptSubmit\": [ { \"hooks\": [ { \"type\": \"command\", \"command\": \"\(escaped)\", \"timeout\": 3600, \"async\": false, \"statusMessage\": \"Bex is reviewing this prompt…\" } ] } ] } }"
        .utf8
    )
    try preexisting.write(to: path)

    do {
      try await fixture.manager.install(.codex)
      XCTFail("Expected missing-manifest refusal")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: path), preexisting)

    try await fixture.manager.uninstall(.codex)
    XCTAssertTrue(try hookHandlers(readRoot(path)).isEmpty)
    try await fixture.manager.install(.codex)
    try await fixture.manager.uninstall(.codex)
    XCTAssertTrue(try hookHandlers(readRoot(path)).isEmpty)
  }

  func testConfiguredPathsAndCodexShellEscapingAreExact() async throws {
    let fixture = try InstallerFixture(pathContainsQuote: true)
    let claudePath = await fixture.manager.configuredPath(for: .claudeCode)
    let codexPath = await fixture.manager.configuredPath(for: .codex)
    XCTAssertEqual(
      claudePath,
      fixture.claudeRoot.appendingPathComponent("settings.json")
    )
    XCTAssertEqual(
      codexPath,
      fixture.codexRoot.appendingPathComponent("hooks.json")
    )
    try await fixture.manager.install(.codex)
    let group = try XCTUnwrap(
      try hookHandlers(readRoot(fixture.codexRoot.appendingPathComponent("hooks.json"))).first
    )
    let handler = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
    XCTAssertEqual(
      handler["command"] as? String,
      "exec \(HookInstallationManager.shellQuote(fixture.stableHelperURL.path)) codex"
    )
  }
  func testLegacyManifestCanMigrateOrUninstallWithoutLosingOwnership() async throws {
    let migration = try InstallerFixture()
    try await migration.manager.install(.claudeCode)
    let descriptor = try await migration.manager.resolve(.claudeCode)
    let review = try await migration.manager.prepare(.repair, for: descriptor)
    _ = try await migration.manager.apply(reviewID: review.id)

    let migratedHandlers = try hookHandlers(readRoot(descriptor.configurationURL))
    let migratedGroup = try XCTUnwrap(migratedHandlers.first)
    let migratedCommand = try XCTUnwrap(
      (migratedGroup["hooks"] as? [[String: Any]])?.first?["command"] as? String
    )
    XCTAssertEqual(migratedCommand, descriptor.helperURL.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: migration.stableHelperURL.path))
    if case .installedUnconfirmed = await migration.manager.status(for: .claudeCode) {
    } else {
      XCTFail("Expected migrated Claude Code integration to be installed")
    }

    let removal = try InstallerFixture()
    try await removal.manager.install(.codex)
    let legacyDescriptors = await removal.manager.installedDescriptors()
    let legacyDescriptor = try XCTUnwrap(
      legacyDescriptors.first(where: { $0.client == .codex })
    )
    XCTAssertEqual(legacyDescriptor.helperURL, removal.stableHelperURL)
    let uninstall = try await removal.manager.prepare(.uninstall, for: legacyDescriptor)
    _ = try await removal.manager.apply(reviewID: uninstall.id)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: legacyDescriptor.configurationURL.path)
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: removal.stableHelperURL.path))
  }

  func testOMPResolutionRejectsUnavailableAndInvalidCapabilityProcesses() async throws {
    let fixture = try InstallerFixture()
    let workingDirectory = fixture.root.appendingPathComponent("workspace", isDirectory: true)
    let gateDirectory = fixture.root.appendingPathComponent("gates", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: true)

    func executable(named name: String, script: String) throws -> URL {
      let url = fixture.root.appendingPathComponent(name)
      try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
      )
      return url
    }

    let unavailableCapability =
      "{\"capabilities\":[],\"profile\":\"default\",\"agent_dir\":\"\(fixture.root.path)\",\"gate_dir\":\"\(gateDirectory.path)\",\"cwd\":\"\(workingDirectory.path)\"}"
    let unavailableExecutable = try executable(
      named: "omp-unavailable",
      script: "printf '%s\\n' '\(unavailableCapability)'"
    )
    let unavailable = try await fixture.manager.resolve(
      .ohMyPi(
        executable: unavailableExecutable,
        profile: nil,
        workingDirectory: workingDirectory
      )
    )
    if case .unavailable = unavailable.validation {
    } else {
      XCTFail("Expected OMP without prompt-gate-v1 to remain unavailable")
    }
    do {
      _ = try await fixture.manager.prepare(.install, for: unavailable)
      XCTFail("Expected unavailable OMP target to reject preparation")
    } catch {}

    let unsupportedExecutable = try executable(
      named: "omp-without-capability-command",
      script:
        "printf 'Error: unknown flag: --json\\nRun `omp --help` for available flags.\\n' >&2; exit 1"
    )
    do {
      _ = try await fixture.manager.resolve(
        .ohMyPi(
          executable: unsupportedExecutable,
          profile: "default",
          workingDirectory: workingDirectory
        )
      )
      XCTFail("Expected an OMP build without the native capability command to remain unavailable")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains(
          "does not implement the native prompt-gate-v1 interface required by Bex"
        )
      )
      XCTAssertFalse(error.localizedDescription.contains("unknown flag"))
    }

    let invalidExecutables = try [
      executable(named: "omp-malformed", script: "printf 'not-json\\n'"),
      executable(named: "omp-nonzero", script: "printf 'failure\\n' >&2; exit 7"),
      executable(named: "omp-oversized", script: "/usr/bin/yes x | /usr/bin/head -c 70000"),
      executable(named: "omp-timeout", script: "/bin/sleep 4"),
    ]
    for invalidExecutable in invalidExecutables {
      do {
        _ = try await fixture.manager.resolve(
          .ohMyPi(
            executable: invalidExecutable,
            profile: "default",
            workingDirectory: workingDirectory
          )
        )
        XCTFail("Expected invalid capability process to fail closed: \(invalidExecutable.path)")
      } catch {}
    }
  }

  func testOMPResolveReviewApplyStatusAndUninstallUseExactNativeGate() async throws {
    let fixture = try InstallerFixture()
    let workingDirectory = fixture.root.appendingPathComponent("workspace", isDirectory: true)
    let gateDirectory = fixture.root.appendingPathComponent("omp-gates", isDirectory: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: gateDirectory, withIntermediateDirectories: true)
    let executable = fixture.root.appendingPathComponent("omp")
    let canonicalRoot = fixture.root
    let canonicalGateDirectory = gateDirectory
    let canonicalWorkingDirectory = workingDirectory
    let capability = """
      {"capabilities":["prompt-gate-v1"],"profile":"team","agent_dir":"\(canonicalRoot.path)","gate_dir":"\(canonicalGateDirectory.path)","cwd":"\(canonicalWorkingDirectory.path)"}
      """
    try Data("#!/bin/sh\nprintf '%s\\n' '\(capability)'\n".utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path
    )

    let descriptor = try await fixture.manager.resolve(
      .ohMyPi(executable: executable, profile: "team", workingDirectory: workingDirectory)
    )
    XCTAssertEqual(descriptor.profile, "team")
    XCTAssertEqual(
      descriptor.configurationURL,
      canonicalGateDirectory.appendingPathComponent("bex.json")
    )
    let review = try await fixture.manager.prepare(.install, for: descriptor)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.configurationURL.path))
    XCTAssertTrue(review.actions.contains { $0.path == descriptor.configurationURL.path })
    XCTAssertTrue(review.actions.contains { $0.path == descriptor.helperURL.path })

    let result = try await fixture.manager.apply(reviewID: review.id)
    XCTAssertTrue(result.failed.isEmpty)
    let gate = try readRoot(descriptor.configurationURL)
    XCTAssertEqual(gate["event"] as? String, HookProtocolConstants.promptGateCapability)
    XCTAssertEqual(gate["integration_id"] as? String, descriptor.id)
    XCTAssertEqual(
      gate["command"] as? [String],
      [descriptor.helperURL.path, PromptClient.ohMyPi.rawValue, descriptor.id]
    )
    let installedStatus = await fixture.manager.status(for: descriptor.id)
    if case .installedUnconfirmed = installedStatus {
    } else {
      XCTFail(
        "Expected installed OMP integration to wait for its first heartbeat; got \(installedStatus)"
      )
    }

    let heartbeatDirectory = fixture.supportDirectory.appendingPathComponent(
      "PromptGate/heartbeats",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: heartbeatDirectory,
      withIntermediateDirectories: true
    )
    let heartbeatName = Data(descriptor.id.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    let heartbeatURL = heartbeatDirectory.appendingPathComponent("\(heartbeatName).json")
    func writeHeartbeat(integrationID: String, seenAt: Date) throws {
      try JSONEncoder().encode(
        HookHeartbeat(
          version: HookProtocolConstants.version,
          client: .ohMyPi,
          seenAt: seenAt,
          integrationID: integrationID
        )
      ).write(to: heartbeatURL, options: .atomic)
    }
    try writeHeartbeat(integrationID: "different-integration", seenAt: Date())
    if case .installedUnconfirmed = await fixture.manager.status(for: descriptor.id) {
    } else {
      XCTFail("Expected a heartbeat for another integration to be ignored")
    }
    try writeHeartbeat(integrationID: descriptor.id, seenAt: Date())
    if case .active = await fixture.manager.status(for: descriptor.id) {
    } else {
      XCTFail("Expected matching post-install heartbeat to activate OMP")
    }
    try writeHeartbeat(
      integrationID: descriptor.id,
      seenAt: Date().addingTimeInterval(301)
    )
    if case .installedUnconfirmed = await fixture.manager.status(for: descriptor.id) {
    } else {
      XCTFail("Expected an implausibly future-dated heartbeat to be ignored")
    }

    let uninstall = try await fixture.manager.prepare(.uninstall, for: descriptor)
    _ = try await fixture.manager.apply(reviewID: uninstall.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.configurationURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: descriptor.helperURL.path))
    let remainingDescriptors = await fixture.manager.installedDescriptors()
    XCTAssertTrue(remainingDescriptors.isEmpty)
  }
}

final class HookHelperOutputTests: XCTestCase {
  func testMalformedInputProducesExactFailClosedShapes() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bex-hook")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))

    let claude = try runHelper(helper, client: "claude", input: Data("not-json".utf8))
    let claudeObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: claude) as? [String: Any]
    )
    XCTAssertEqual(claudeObject["decision"] as? String, "block")
    XCTAssertEqual(
      claudeObject["reason"] as? String,
      "Bex could not review this prompt. The original was blocked.")

    let codex = try runHelper(helper, client: "codex", input: Data("not-json".utf8))
    let codexObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: codex) as? [String: Any]
    )
    XCTAssertEqual(codexObject["decision"] as? String, "block")
    XCTAssertEqual(
      codexObject["reason"] as? String,
      "Bex could not review this prompt. The original was blocked.")

    let omp = try runHelper(
      helper,
      client: "omp",
      additionalArguments: ["omp-test"],
      input: Data("not-json\n".utf8)
    )
    let ompObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: omp) as? [String: Any]
    )
    XCTAssertEqual(ompObject["event"] as? String, HookProtocolConstants.promptGateCapability)
    XCTAssertEqual(ompObject["integration_id"] as? String, "omp-test")
    XCTAssertEqual(ompObject["decision"] as? String, "block")
  }

  func testOMPTrivialPromptProducesOneAllowFrameAndHeartbeat() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bex-hook")
    let integrationID = "omp-test-\(UUID().uuidString)"
    let heartbeatName = Data(integrationID.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
    let heartbeatURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/PromptGate/heartbeats")
      .appendingPathComponent("\(heartbeatName).json")
    defer { try? FileManager.default.removeItem(at: heartbeatURL) }
    var input = try JSONSerialization.data(withJSONObject: [
      "version": HookProtocolConstants.version,
      "event": HookProtocolConstants.promptGateCapability,
      "integration_id": integrationID,
      "text": "안녕하세요",
      "images": [],
      "session_id": "omp-helper-test",
      "cwd": "/tmp",
      "profile": "default",
      "source": "prompt",
    ])
    input.append(0x0A)

    let output = try runHelper(
      helper,
      client: "omp",
      additionalArguments: [integrationID],
      input: input
    )
    let lines = output.split(separator: 0x0A)
    XCTAssertEqual(lines.count, 1)
    let frame = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any]
    )
    XCTAssertEqual(frame["decision"] as? String, "allow")
    XCTAssertEqual(frame["integration_id"] as? String, integrationID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: heartbeatURL.path))
  }
}

private actor IPCRequestRecorder {
  private var recorded: HookReviewRequest?
  private var invalidated: [UUID] = []
  private var waiter: CheckedContinuation<Void, Never>?

  func record(_ request: HookReviewRequest) {
    recorded = request
    waiter?.resume()
    waiter = nil
  }

  func request() -> HookReviewRequest? { recorded }
  func invalidate(_ id: UUID) { invalidated.append(id) }

  func waitForRequest() async {
    if recorded != nil { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

private struct InstallerFixture {
  let root: URL
  let claudeRoot: URL
  let codexRoot: URL
  let manager: HookInstallationManager
  let supportDirectory: URL
  let stableHelperURL: URL

  init(
    pathContainsQuote: Bool = false,
    transactionFaultInjector: @escaping @Sendable (Int, URL?) throws -> Void = { _, _ in }
  ) throws {
    root = temporaryDirectory(pathContainsQuote ? "installer-'quote" : "installer")
    claudeRoot = root.appendingPathComponent("claude")
    codexRoot = root.appendingPathComponent("codex")
    let embedded = root.appendingPathComponent("embedded-bex-hook")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = """
      #!/bin/sh
      if [ "$1" = "--self-check" ]; then
        echo '{"protocolVersion":1,"maximumMessageBytes":1048576}'
        exit 0
      fi
      exit 0
      """
    try Data(script.utf8).write(to: embedded)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: embedded.path
    )
    supportDirectory = root.appendingPathComponent(pathContainsQuote ? "support-'dir" : "support")
    stableHelperURL = supportDirectory.appendingPathComponent("bin/bex-hook")
    manager = HookInstallationManager(
      environment: [
        "CLAUDE_CONFIG_DIR": claudeRoot.path,
        "CODEX_HOME": codexRoot.path,
      ],
      homeDirectory: root,
      embeddedHelperURL: embedded,
      supportDirectory: supportDirectory,
      signatureVerifier: { _ in },
      transactionFaultInjector: transactionFaultInjector
    )
  }
}

private func makeHookRequest() -> HookReviewRequest {
  HookReviewRequest(
    requestID: UUID(),
    client: .claudeCode,
    prompt: "Original prompt",
    sessionID: "session",
    cwd: "/tmp/project",
    helperPID: .max,
    sourcePID: ProcessInfo.processInfo.processIdentifier,
    sourceBundleID: "com.bex.tests"
  )
}

private func temporaryDirectory(_ prefix: String) -> URL {
  let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
  let canonicalTemporary =
    temporary.path == "/var" || temporary.path.hasPrefix("/var/")
    ? URL(fileURLWithPath: "/private\(temporary.path)", isDirectory: true)
    : temporary
  return
    canonicalTemporary
    .appendingPathComponent("Bex-\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func readRoot(_ path: URL) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
}

private func hookHandlers(_ root: [String: Any]) throws -> [[String: Any]] {
  guard let hooks = root["hooks"] as? [String: Any] else { return [] }
  return hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
}

private func runHelper(
  _ helper: URL,
  client: String,
  additionalArguments: [String] = [],
  input: Data
) throws -> Data {
  let process = Process()
  let stdin = Pipe()
  let stdout = Pipe()
  process.executableURL = helper
  process.arguments = [client] + additionalArguments
  process.standardInput = stdin
  process.standardOutput = stdout
  try process.run()
  stdin.fileHandleForWriting.write(input)
  try stdin.fileHandleForWriting.close()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0)
  return stdout.fileHandleForReading.readDataToEndOfFile()
}
