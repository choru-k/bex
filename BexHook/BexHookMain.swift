import AppKit
import Darwin
import Foundation

private struct OMPStageAcknowledgment: Decodable {
  let event: String
  let deliveryToken: String
  let status: String

  private enum CodingKeys: String, CodingKey {
    case event
    case deliveryToken = "delivery_token"
    case status
  }
}

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

    if client == .ohMyPi {
      await runOMP(expectedIntegrationID: arguments.dropFirst(2).first)
    } else {
      await runLegacy(client: client)
    }
  }

  private static func runLegacy(client: PromptClient) async {
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

      if client == .claudeCode, ClaudePromptSource.isNonInteractivePrompt(input) {
        try? writeHeartbeat(client: client, integrationID: input.integrationID)
        return
      }

      if KoreanPrompt.isMainlyKorean(input.prompt) {
        try? writeHeartbeat(client: client, integrationID: input.integrationID)
        return
      }

      let approvalStore = PromptApprovalStore()
      if try await approvalStore.consume(
        client: client,
        integrationID: input.integrationID,
        text: input.prompt,
        sessionID: input.sessionID,
        cwd: input.cwd
      ) {
        try writeHeartbeat(client: client, integrationID: input.integrationID)
        return
      }

      let sourceApplication = NSWorkspace.shared.frontmostApplication
      let request = HookReviewRequest(
        client: client,
        integrationID: input.integrationID,
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
      case .bypassed:
        try? writeHeartbeat(client: client, integrationID: input.integrationID)
        return
      case .approved:
        guard let token = response.acknowledgmentToken else {
          throw HookIPCError.invalidResponse
        }
        writeBlock(client: client, reason: reviewedReason, closeOutput: true)
        try await ipc.acknowledge(requestID: request.requestID, token: token)
        try writeHeartbeat(client: client, integrationID: input.integrationID)
      case .cancelled:
        writeBlock(client: client, reason: cancelledReason)
      case .failed:
        writeBlock(client: client, reason: recoveryReason)
      }
    } catch {
      writeBlock(client: client, reason: recoveryReason)
    }
  }

  private static func runOMP(expectedIntegrationID: String?) async {
    var integrationID = expectedIntegrationID ?? ""
    var decisionWritten = false
    do {
      let inputData = try readStandardInputLine()
      let input = try JSONDecoder().decode(OMPPromptGateInput.self, from: inputData)
      guard input.version == HookProtocolConstants.version,
        input.event == HookProtocolConstants.promptGateCapability,
        input.integrationID == expectedIntegrationID,
        !input.integrationID.isEmpty,
        input.images.isEmpty,
        !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !input.sessionID.isEmpty,
        !input.cwd.isEmpty
      else {
        throw HookIPCError.invalidResponse
      }
      integrationID = input.integrationID

      if KoreanPrompt.isMainlyKorean(input.text) {
        try writeFrame(OMPPromptGateFrame.allow(integrationID: integrationID))
        decisionWritten = true
        try writeHeartbeat(client: .ohMyPi, integrationID: integrationID)
        return
      }

      let approvalStore = PromptApprovalStore()
      if try await approvalStore.consume(
        client: .ohMyPi,
        integrationID: integrationID,
        text: input.text,
        sessionID: input.sessionID,
        cwd: input.cwd
      ) {
        try writeFrame(OMPPromptGateFrame.allow(integrationID: integrationID))
        decisionWritten = true
        try writeHeartbeat(client: .ohMyPi, integrationID: integrationID)
        return
      }

      try writeFrame(
        OMPPromptGateFrame.block(
          integrationID: integrationID,
          reason: reviewedReason
        )
      )
      decisionWritten = true

      let request = HookReviewRequest(
        client: .ohMyPi,
        integrationID: integrationID,
        prompt: input.text,
        sessionID: input.sessionID,
        cwd: input.cwd,
        helperPID: ProcessInfo.processInfo.processIdentifier
      )
      let ipc = PromptGateIPCClient()
      let response = try await ipc.submit(request)
      guard response.outcome == .approved,
        response.integrationID == integrationID,
        let approvedPrompt = response.approvedPrompt,
        !approvedPrompt.isEmpty,
        let deliveryToken = response.deliveryToken,
        !deliveryToken.isEmpty,
        let acknowledgmentToken = response.acknowledgmentToken
      else {
        return
      }

      try writeFrame(
        OMPPromptGateFrame.stageApproved(
          integrationID: integrationID,
          text: approvedPrompt,
          deliveryToken: deliveryToken
        )
      )
      let acknowledgmentData = try readStandardInputLine()
      let acknowledgment = try JSONDecoder().decode(
        OMPStageAcknowledgment.self,
        from: acknowledgmentData
      )
      guard acknowledgment.event == "stage_delivery",
        acknowledgment.deliveryToken == deliveryToken,
        acknowledgment.status == "delivered"
      else {
        throw HookIPCError.invalidResponse
      }
      try await ipc.acknowledge(
        requestID: request.requestID,
        token: acknowledgmentToken,
        integrationID: integrationID,
        deliveryToken: deliveryToken,
        deliveryStatus: acknowledgment.status
      )
      try writeHeartbeat(client: .ohMyPi, integrationID: integrationID)
    } catch {
      if !decisionWritten, !integrationID.isEmpty {
        try? writeFrame(
          OMPPromptGateFrame.block(
            integrationID: integrationID,
            reason: recoveryReason
          )
        )
      } else {
        try? FileHandle.standardOutput.close()
      }
    }
  }

  private static func readStandardInput() throws -> Data {
    let data = try FileHandle.standardInput.readToEnd() ?? Data()
    guard data.count <= HookProtocolConstants.maximumMessageBytes else {
      throw HookIPCError.messageTooLarge
    }
    return data
  }

  private static func readStandardInputLine() throws -> Data {
    var data = Data()
    while data.count <= HookProtocolConstants.maximumMessageBytes {
      guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else {
        break
      }
      if byte[byte.startIndex] == 0x0A {
        return data
      }
      data.append(byte)
    }
    guard data.count <= HookProtocolConstants.maximumMessageBytes else {
      throw HookIPCError.messageTooLarge
    }
    return data
  }

  private static func writeFrame(_ data: Data) throws {
    FileHandle.standardOutput.write(data)
    try FileHandle.standardOutput.synchronize()
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

  private static func writeHeartbeat(
    client: PromptClient,
    integrationID: String?
  ) throws {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(
        "Library/Application Support/Bex/PromptGate/heartbeats", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    chmod(directory.path, 0o700)
    let heartbeat = HookHeartbeat(
      version: HookProtocolConstants.version,
      client: client,
      seenAt: Date(),
      integrationID: integrationID
    )
    let data = try JSONEncoder().encode(heartbeat)
    let filename = integrationID.map(filenameSafeIdentity) ?? client.rawValue
    let destination = directory.appendingPathComponent("\(filename).json")
    let temporary = directory.appendingPathComponent(".heartbeat-\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .withoutOverwriting)
    chmod(temporary.path, 0o600)
    guard rename(temporary.path, destination.path) == 0 else {
      try? FileManager.default.removeItem(at: temporary)
      throw HookIPCError.unavailable
    }
  }
  private static func filenameSafeIdentity(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "=", with: "")
  }

}
