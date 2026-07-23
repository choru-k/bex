import CryptoKit
import Darwin
import Foundation

enum PromptApprovalError: LocalizedError, Equatable, Sendable {
  case storageFailure(String)

  var errorDescription: String? {
    switch self {
    case .storageFailure(let message): message
    }
  }
}

actor PromptApprovalStore {
  private struct Receipt: Codable, Sendable {
    let version: Int
    let id: UUID
    let client: PromptClient
    let integrationID: String?
    let sessionID: String?
    let cwd: String?
    let textSHA256: String
    let createdAt: Date
    let expiresAt: Date
  }

  private let directoryURL: URL
  private let now: @Sendable () -> Date
  private let timeToLive: TimeInterval

  init(
    directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Bex/PromptGate/receipts", isDirectory: true),
    timeToLive: TimeInterval = 120,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.directoryURL = directoryURL
    self.timeToLive = timeToLive
    self.now = now
  }

  func issue(
    client: PromptClient,
    integrationID: String? = nil,
    text: String,
    sessionID: String?,
    cwd: String?
  ) throws -> UUID {
    try ensureDirectory()
    let createdAt = now()
    let receipt = Receipt(
      version: HookProtocolConstants.version,
      id: UUID(),
      client: client,
      integrationID: try Self.canonicalIntegrationID(client: client, integrationID: integrationID),
      sessionID: sessionID,
      cwd: cwd,
      textSHA256: Self.digest(text),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(timeToLive)
    )
    let data = try JSONEncoder().encode(receipt)
    try atomicWrite(data, to: receiptURL(id: receipt.id))
    return receipt.id
  }

  func revoke(id: UUID) throws {
    let path = receiptURL(id: id).path
    guard unlink(path) == 0 || errno == ENOENT else {
      throw PromptApprovalError.storageFailure("Bex could not revoke prompt approval.")
    }
  }

  func consume(
    client: PromptClient,
    integrationID: String? = nil,
    text: String,
    sessionID: String?,
    cwd: String?
  ) throws -> Bool {
    try ensureDirectory()
    let candidates = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("receipt-") }
    let expectedDigest = Self.digest(text)
    let expectedIntegrationID = try Self.canonicalIntegrationID(
      client: client,
      integrationID: integrationID
    )

    for candidate in candidates {
      guard
        let candidateData = try? Data(contentsOf: candidate),
        let candidateReceipt = try? JSONDecoder().decode(Receipt.self, from: candidateData)
      else {
        try? FileManager.default.removeItem(at: candidate)
        continue
      }
      if candidateReceipt.expiresAt < now() {
        try? FileManager.default.removeItem(at: candidate)
        continue
      }
      guard matches(
        candidateReceipt,
        client: client,
        integrationID: expectedIntegrationID,
        digest: expectedDigest,
        sessionID: sessionID,
        cwd: cwd
      ) else {
        continue
      }

      let claim = directoryURL.appendingPathComponent(
        ".claim-\(getpid())-\(UUID().uuidString)-\(candidate.lastPathComponent)"
      )
      guard rename(candidate.path, claim.path) == 0 else {
        if errno == ENOENT { continue }
        throw PromptApprovalError.storageFailure("Bex could not claim prompt approval.")
      }
      defer { try? FileManager.default.removeItem(at: claim) }

      guard
        let claimedData = try? Data(contentsOf: claim),
        let receipt = try? JSONDecoder().decode(Receipt.self, from: claimedData),
        receipt.expiresAt >= now(),
        matches(
          receipt,
          client: client,
          integrationID: expectedIntegrationID,
          digest: expectedDigest,
          sessionID: sessionID,
          cwd: cwd
        )
      else {
        continue
      }
      return true
    }
    return false
  }

  private func matches(
    _ receipt: Receipt,
    client: PromptClient,
    integrationID: String,
    digest: String,
    sessionID: String?,
    cwd: String?
  ) -> Bool {
    receipt.version == HookProtocolConstants.version
      && Self.receiptIntegrationID(receipt) == integrationID
      && receipt.client == client
      && receipt.textSHA256 == digest
      && (receipt.sessionID.map { $0 == sessionID } ?? true)
      && (receipt.cwd.map { $0 == cwd } ?? true)
  }

  private static func canonicalIntegrationID(
    client: PromptClient,
    integrationID: String?
  ) throws -> String {
    if let integrationID, !integrationID.isEmpty { return integrationID }
    guard client != .ohMyPi else {
      throw PromptApprovalError.storageFailure("OMP prompt approval requires an integration identity.")
    }
    return client.rawValue
  }

  private static func receiptIntegrationID(_ receipt: Receipt) -> String? {
    if let integrationID = receipt.integrationID, !integrationID.isEmpty { return integrationID }
    return receipt.client == .ohMyPi ? nil : receipt.client.rawValue
  }

  private func ensureDirectory() throws {
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard chmod(directoryURL.path, 0o700) == 0 else {
        throw PromptApprovalError.storageFailure(
          "Bex could not secure the prompt approval directory."
        )
      }
    } catch let error as PromptApprovalError {
      throw error
    } catch {
      throw PromptApprovalError.storageFailure(
        "Bex could not create the prompt approval directory."
      )
    }
  }

  private func receiptURL(id: UUID) -> URL {
    directoryURL.appendingPathComponent("receipt-\(id.uuidString.lowercased()).json")
  }

  private func atomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = directoryURL.appendingPathComponent(".receipt-\(UUID().uuidString).tmp")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw PromptApprovalError.storageFailure("Bex could not create prompt approval.")
    }

    var writeError: PromptApprovalError?
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let result = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        if result <= 0 {
          writeError = .storageFailure("Bex could not write prompt approval.")
          break
        }
        offset += result
      }
    }
    if writeError == nil, fsync(descriptor) != 0 {
      writeError = .storageFailure("Bex could not synchronize prompt approval.")
    }
    if close(descriptor) != 0, writeError == nil {
      writeError = .storageFailure("Bex could not close prompt approval.")
    }
    if let writeError {
      unlink(temporary.path)
      throw writeError
    }
    guard rename(temporary.path, destination.path) == 0 else {
      unlink(temporary.path)
      throw PromptApprovalError.storageFailure("Bex could not publish prompt approval.")
    }
  }

  private static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
