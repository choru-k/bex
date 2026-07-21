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
    let body = try JSONEncoder().encode(HookReviewEnvelope(
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
  func testInstallIsIdempotentPreservesUnrelatedConfigModeAndRestoresExactBaseline() async throws {
    let fixture = try InstallerFixture()
    let path = await fixture.manager.configuredPath(for: .claudeCode)
    let baseline = Data("{\n  \"unrelated\" : {\"keep\":true},\n  \"hooks\" : {\"OtherEvent\":[{\"x\":1}]}\n}\n".utf8)
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
      "{ \"other\": 1, \"hooks\": { \"UserPromptSubmit\": [ { \"hooks\": [ { \"type\": \"command\", \"command\": \"\(escaped)\", \"timeout\": 3600, \"async\": false, \"statusMessage\": \"Bex is reviewing this prompt…\" } ] } ] } }".utf8
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
}

final class HookHelperOutputTests: XCTestCase {
  func testMalformedInputProducesExactFailClosedShapes() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bex-hook")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))

    let claude = try runHelper(helper, client: "claude", input: Data("not-json".utf8))
    let claudeObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: claude) as? [String: Any]
    )
    XCTAssertEqual(claudeObject["continue"] as? Bool, false)
    XCTAssertEqual(claudeObject["stopReason"] as? String, "Bex could not review this prompt. The original was blocked.")

    let codex = try runHelper(helper, client: "codex", input: Data("not-json".utf8))
    let codexObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: codex) as? [String: Any]
    )
    XCTAssertEqual(codexObject["decision"] as? String, "block")
    XCTAssertEqual(codexObject["reason"] as? String, "Bex could not review this prompt. The original was blocked.")
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
  let stableHelperURL: URL

  init(pathContainsQuote: Bool = false) throws {
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
    let support = root.appendingPathComponent(pathContainsQuote ? "support-'dir" : "support")
    stableHelperURL = support.appendingPathComponent("bin/bex-hook")
    manager = HookInstallationManager(
      environment: [
        "CLAUDE_CONFIG_DIR": claudeRoot.path,
        "CODEX_HOME": codexRoot.path,
      ],
      homeDirectory: root,
      embeddedHelperURL: embedded,
      supportDirectory: support
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
  FileManager.default.temporaryDirectory
    .appendingPathComponent("Bex-\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func readRoot(_ path: URL) throws -> [String: Any] {
  try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
}

private func hookHandlers(_ root: [String: Any]) throws -> [[String: Any]] {
  guard let hooks = root["hooks"] as? [String: Any] else { return [] }
  return hooks["UserPromptSubmit"] as? [[String: Any]] ?? []
}

private func runHelper(_ helper: URL, client: String, input: Data) throws -> Data {
  let process = Process()
  let stdin = Pipe()
  let stdout = Pipe()
  process.executableURL = helper
  process.arguments = [client]
  process.standardInput = stdin
  process.standardOutput = stdout
  try process.run()
  stdin.fileHandleForWriting.write(input)
  try stdin.fileHandleForWriting.close()
  process.waitUntilExit()
  XCTAssertEqual(process.terminationStatus, 0)
  return stdout.fileHandleForReading.readDataToEndOfFile()
}
