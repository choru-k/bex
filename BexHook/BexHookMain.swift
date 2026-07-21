import AppKit
import Darwin
import Foundation

@main
struct BexHookMain {
  private static let reviewedReason = "Bex reviewed this prompt. The original was not sent."
  private static let cancelledReason = "Bex cancelled this prompt. The original was not sent."
  private static let recoveryReason = "Bex could not review this prompt. The original was blocked."

  static func main() async {
    let arguments = CommandLine.arguments
    if arguments.dropFirst().first == "--self-check" {
      writeSelfCheck()
      return
    }

    guard let rawClient = arguments.dropFirst().first,
      let client = PromptClient(rawValue: rawClient)
    else {
      writeBlock(client: .claudeCode, reason: recoveryReason)
      return
    }

    do {
      let data = try readStandardInput()
      let input = try JSONDecoder().decode(HookInput.self, from: data)
      guard input.hookEventName == "UserPromptSubmit",
        !input.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !input.sessionID.isEmpty,
        !input.cwd.isEmpty
      else {
        throw HookIPCError.invalidResponse
      }

      let approvalStore = PromptApprovalStore()
      if try await approvalStore.consume(
        client: client,
        text: input.prompt,
        sessionID: input.sessionID,
        cwd: input.cwd
      ) {
        try writeHeartbeat(client: client)
        return
      }

      let sourceApplication = NSWorkspace.shared.frontmostApplication
      let request = HookReviewRequest(
        client: client,
        prompt: input.prompt,
        sessionID: input.sessionID,
        cwd: input.cwd,
        helperPID: ProcessInfo.processInfo.processIdentifier,
        promptID: input.promptID,
        turnID: input.turnID,
        sourcePID: sourceApplication?.processIdentifier,
        sourceBundleID: sourceApplication?.bundleIdentifier
      )
      let ipc = PromptGateIPCClient()
      let response = try await ipc.submit(request)
      switch response.outcome {
      case .approved:
        guard let token = response.acknowledgmentToken else {
          throw HookIPCError.invalidResponse
        }
        writeBlock(client: client, reason: reviewedReason, closeOutput: true)
        try await ipc.acknowledge(requestID: request.requestID, token: token)
        try writeHeartbeat(client: client)
      case .cancelled:
        writeBlock(client: client, reason: cancelledReason)
      case .failed:
        writeBlock(client: client, reason: recoveryReason)
      }
    } catch {
      writeBlock(client: client, reason: recoveryReason)
    }
  }

  private static func readStandardInput() throws -> Data {
    let data = try FileHandle.standardInput.readToEnd() ?? Data()
    guard data.count <= HookProtocolConstants.maximumMessageBytes else {
      throw HookIPCError.messageTooLarge
    }
    return data
  }

  private static func writeBlock(
    client: PromptClient,
    reason: String,
    closeOutput: Bool = false
  ) {
    let output = HookBlockOutput(client: client, reason: reason)
    guard var data = try? output.encoded() else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
    try? FileHandle.standardOutput.synchronize()
    if closeOutput {
      try? FileHandle.standardOutput.close()
    }
  }

  private static func writeSelfCheck() {
    let object: [String: Any] = [
      "protocolVersion": HookProtocolConstants.version,
      "helper": HookProtocolConstants.helperName,
    ]
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else {
      return
    }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
  }

  private static func writeHeartbeat(client: PromptClient) throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/PromptGate/heartbeats", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    let heartbeat = HookHeartbeat(
      version: HookProtocolConstants.version,
      client: client,
      seenAt: Date()
    )
    let data = try JSONEncoder().encode(heartbeat)
    let destination = directory.appendingPathComponent("\(client.rawValue).json")
    let temporary = directory.appendingPathComponent(".heartbeat-\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .withoutOverwriting)
    chmod(temporary.path, 0o600)
    guard rename(temporary.path, destination.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw HookIPCError.unavailable
    }
  }
}
