import Foundation
import XCTest

@testable import Bex

final class HookHelperLifecycleTests: XCTestCase {
  func testContractRequiresExplicitRuntimeIdentityAndCapabilities() throws {
    let current = try contractObject()
    XCTAssertTrue(HookHelperContract.current.satisfiesCurrentApp)
    for (key, value) in [
      ("contractVersion", 2), ("protocolVersion", 2),
      ("runtimeRevision", 2), ("maximumMessageBytes", 1),
    ] {
      var changed = current
      changed[key] = value
      XCTAssertFalse(try decodeContract(changed).satisfiesCurrentApp, key)
    }
    var wrongHelper = current
    wrongHelper["helper"] = "another-helper"
    XCTAssertFalse(try decodeContract(wrongHelper).satisfiesCurrentApp)
    var missingCapability = current
    missingCapability["capabilities"] = ["review-v1"]
    XCTAssertFalse(try decodeContract(missingCapability).satisfiesCurrentApp)
    var extraCapability = current
    extraCapability["capabilities"] = HookHelperContract.current.capabilities + ["future-capability"]
    XCTAssertTrue(try decodeContract(extraCapability).satisfiesCurrentApp)
    for key in current.keys {
      var missing = current
      missing.removeValue(forKey: key)
      XCTAssertThrowsError(try decodeContract(missing), key)
    }
  }

  func testBundledSignedContractMatchesRuntimeContract() throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bex-hook")
    try HookInstallationManager.verifyHelperSignature(helper)
    XCTAssertEqual(try HookInstallationManager.readHelperContract(at: helper), .current)
  }

  func testCompatibleRebuildRetainsBytesInodeHeartbeatAndTrustState() async throws {
    for client in [PromptClient.claudeCode, .codex] {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let descriptor = try await fixture.install(client)
      let heartbeatDate = try fixture.writeHeartbeat(for: client)
      let before = try fixture.snapshot(descriptor)
      try fixture.rebuildEmbedded(label: "ui-and-provider-policy-build-2")

      try await fixture.manager.refreshInstalledHelper()
      for _ in 0..<2 {
        let status = await fixture.manager.status(for: descriptor.id)
        XCTAssertEqual(status, .active(lastSeen: heartbeatDate))
      }
      XCTAssertEqual(try fixture.snapshot(descriptor), before)
      let installed = await fixture.manager.installedDescriptors()
      XCTAssertEqual(installed.first?.helperURL, descriptor.helperURL)
      let newlyResolved = try await fixture.manager.resolve(fixture.target(client))
      XCTAssertNotEqual(newlyResolved.helperURL, descriptor.helperURL)
      XCTAssertFalse(FileManager.default.fileExists(atPath: newlyResolved.helperURL.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.legacyHelper.path))
    }
  }

  func testCompatibleRebuildDoesNotInventHostApprovalOrHeartbeat() async throws {
    for client in [PromptClient.claudeCode, .codex] {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let descriptor = try await fixture.install(client)
      try fixture.rebuildEmbedded(label: "ui-build-2")
      let status = await fixture.manager.status(for: descriptor.id)
      XCTAssertEqual(status, client == .codex ? .awaitingCodexTrust : .installedUnconfirmed)
    }
  }

  func testSecondIntegrationKeepsSharedHelperInodeAndUninstallReference() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let claude = try await fixture.install(.claudeCode)
    let before = try fixture.snapshot(claude)
    let codex = try await fixture.install(.codex)
    XCTAssertEqual(claude.helperURL, codex.helperURL)
    let after = try fixture.snapshot(claude)
    XCTAssertEqual(before[0], after[0], "Shared helper bytes must not change")
    XCTAssertEqual(before[1], after[1], "Existing host configuration must not change")
    XCTAssertEqual(before[3], after[3], "A keep action must retain the inode")
    let firstRemoval = try await fixture.manager.prepare(.uninstall, for: codex)
    _ = try await fixture.manager.apply(reviewID: firstRemoval.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: claude.helperURL.path))
    let finalRemoval = try await fixture.manager.prepare(.uninstall, for: claude)
    _ = try await fixture.manager.apply(reviewID: finalRemoval.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: claude.helperURL.path))
  }

  func testUnknownOrIncompatibleContractRequiresReviewAndBlocksReceipts() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let descriptor = try await fixture.install(.codex)
    _ = try fixture.writeHeartbeat(for: .codex)
    let before = try fixture.snapshot(descriptor)
    try fixture.rebuildEmbedded(label: "app-build-2")
    var incompatible = try contractObject()
    incompatible["runtimeRevision"] = 0
    let oldContract = try decodeContract(incompatible)

    for contract in [oldContract, nil] as [HookHelperContract?] {
      let manager = fixture.makeManager(contractReader: { url in
        guard url != descriptor.helperURL else {
          if let contract { return contract }
          throw BexError.storageFailure("Old helper has no sealed compatibility contract")
        }
        return .current
      })
      let status = await manager.status(for: descriptor.id)
      XCTAssertEqual(status, .updateAvailable)
      XCTAssertFalse(status.permitsReceipt)
      try await manager.refreshInstalledHelper()
      XCTAssertEqual(try fixture.snapshot(descriptor), before)
    }
  }

  func testInvalidSignatureCannotClaimCompatibilityOrRunHelper() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let descriptor = try await fixture.install(.claudeCode)
    try fixture.rebuildEmbedded(label: "new-build")
    let manager = fixture.makeManager(signatureVerifier: { url in
      if url == descriptor.helperURL { throw BexError.storageFailure("Invalid signature") }
    }, contractReader: { _ in
      XCTFail("Contract must not be read after signature rejection")
      return .current
    })
    let status = await manager.status(for: descriptor.id)
    guard case .needsRepair = status else { return XCTFail("Expected signature rejection") }
    XCTAssertFalse(status.permitsReceipt)
  }

  func testMatchingDigestStillRequiresCurrentSignedContract() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let descriptor = try await fixture.install(.codex)
    _ = try fixture.writeHeartbeat(for: .codex)
    var incompatible = try contractObject()
    incompatible["runtimeRevision"] = 0
    let oldContract = try decodeContract(incompatible)
    for contract in [oldContract, nil] as [HookHelperContract?] {
      let manager = fixture.makeManager(contractReader: { _ in
        if let contract { return contract }
        throw BexError.storageFailure("Missing signed contract")
      })
      let status = await manager.status(for: descriptor.id)
      XCTAssertEqual(status, .updateAvailable)
      XCTAssertFalse(status.permitsReceipt)
    }
  }

  func testKeepRechecksBytesWhenTheSameInodeChangesAfterPreflight() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let claude = try await fixture.install(.claudeCode)
    let before = try fixture.snapshot(claude)
    let manager = fixture.makeManager(transactionFaultInjector: { index, _ in
      guard index == 0 else { return }
      let file = try FileHandle(forWritingTo: claude.helperURL)
      defer { try? file.close() }
      try file.seek(toOffset: 0)
      try file.write(contentsOf: Data([0]))
    })
    let codex = try await manager.resolve(.codex)
    let review = try await manager.prepare(.install, for: codex)
    do {
      _ = try await manager.apply(reviewID: review.id)
      XCTFail("An unchanged inode cannot hide changed bytes")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("artifact drifted after review"))
    }
    let after = try fixture.snapshot(claude)
    XCTAssertEqual(before[1], after[1], "Existing configuration must not change")
    XCTAssertEqual(before[2], after[2], "Ownership must not commit after drift")
    XCTAssertEqual(before[3], after[3], "Fixture mutation preserved the inode")
    XCTAssertFalse(FileManager.default.fileExists(atPath: codex.configurationURL.path))
  }

  func testTamperedHelperAndSymlinkAreNeverReused() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let descriptor = try await fixture.install(.claudeCode)
    let bytes = try Data(contentsOf: descriptor.helperURL)
    try Data("tampered".utf8).write(to: descriptor.helperURL)
    let tampered = await fixture.manager.status(for: descriptor.id)
    guard case .needsRepair = tampered else { return XCTFail("Expected digest rejection") }
    try FileManager.default.removeItem(at: descriptor.helperURL)
    let other = fixture.root.appendingPathComponent("other-helper")
    try bytes.write(to: other)
    try FileManager.default.createSymbolicLink(at: descriptor.helperURL, withDestinationURL: other)
    let symlinked = await fixture.manager.status(for: descriptor.id)
    guard case .needsRepair = symlinked else { return XCTFail("Expected symlink rejection") }
  }

  func testReviewedUpdateUsesNewHelperFromPreviouslyInstalledDescriptor() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let installed = try await fixture.install(.codex)
    let before = try fixture.snapshot(installed)
    try fixture.rebuildEmbedded(label: "explicit-runtime-update")
    let review = try await fixture.manager.prepare(.update, for: installed)
    XCTAssertNotEqual(review.descriptor.helperURL, installed.helperURL)
    XCTAssertEqual(try fixture.snapshot(installed), before, "Preparing must not write")
    _ = try await fixture.manager.apply(reviewID: review.id)
    let configuration = String(decoding: try Data(contentsOf: installed.configurationURL), as: UTF8.self)
    XCTAssertTrue(configuration.contains(review.descriptor.helperURL.path))
    XCTAssertFalse(configuration.contains(installed.helperURL.path))
    let status = await fixture.manager.status(for: installed.id)
    XCTAssertEqual(status, .awaitingCodexTrust, "A changed command still needs host approval")
  }

  func testUninstallAfterRebuildRemovesOwnedHelperNotNewEmbeddedPath() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let installed = try await fixture.install(.codex)
    try fixture.rebuildEmbedded(label: "ui-build-2")
    let fresh = try await fixture.manager.resolve(.codex)
    let review = try await fixture.manager.prepare(.uninstall, for: fresh)
    XCTAssertEqual(review.descriptor.helperURL, installed.helperURL)
    _ = try await fixture.manager.apply(reviewID: review.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.helperURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.configurationURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.embedded.path))
  }

  func testReviewedUpdateThenUninstallPreservesInterveningHostEdits() async throws {
    for hadOriginalFile in [false, true] {
      let fixture = try LifecycleFixture()
      defer { fixture.remove() }
      let configuration = await fixture.manager.configuredPath(for: .codex)
      if hadOriginalFile {
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"originalSetting\":true}".utf8).write(to: configuration)
      }
      let installed = try await fixture.install(.codex)
      var edited = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
      edited["userAddedSetting"] = "keep this after update and uninstall"
      try JSONSerialization.data(withJSONObject: edited).write(to: configuration)
      try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: configuration.path)
      try fixture.rebuildEmbedded(label: "new-runtime")
      let update = try await fixture.manager.prepare(.update, for: installed)
      _ = try await fixture.manager.apply(reviewID: update.id)
      let removal = try await fixture.manager.prepare(.uninstall, for: update.descriptor)
      _ = try await fixture.manager.apply(reviewID: removal.id)
      let remaining = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
      XCTAssertEqual(remaining["userAddedSetting"] as? String, "keep this after update and uninstall")
      XCTAssertEqual(remaining["originalSetting"] as? Bool, hadOriginalFile ? true : nil)
      let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: configuration.path)[.posixPermissions] as? NSNumber)
      XCTAssertEqual(mode.intValue, 0o640)
      XCTAssertFalse(String(decoding: try Data(contentsOf: configuration), as: UTF8.self).contains("bex-hook"))
    }
  }

  func testUninstallDoesNotNeedEmbeddedHelperOrRunInstalledHelper() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let installed = try await fixture.install(.claudeCode)
    try FileManager.default.removeItem(at: fixture.embedded)
    let manager = fixture.makeManager(signatureVerifier: { _ in
      XCTFail("Removal does not activate a helper or need signature approval")
    }, contractReader: { _ in
      XCTFail("Removal must not probe a helper")
      return .current
    })
    let review = try await manager.prepare(.uninstall, for: installed)
    _ = try await manager.apply(reviewID: review.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.helperURL.path))
  }

  func testEmbeddedChangeAfterReviewIsRejectedWithoutWrites() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let installed = try await fixture.install(.claudeCode)
    try fixture.rebuildEmbedded(label: "build-2")
    let review = try await fixture.manager.prepare(.update, for: installed)
    let before = try fixture.snapshot(installed)
    try fixture.rebuildEmbedded(label: "build-3")
    do {
      _ = try await fixture.manager.apply(reviewID: review.id)
      XCTFail("Expected stale source rejection")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("embedded helper changed after review"))
    }
    XCTAssertEqual(try fixture.snapshot(installed), before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: review.descriptor.helperURL.path))
  }

  func testLaunchAndLegacyInstallNeverReplaceExistingHelper() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    try await fixture.manager.install(.claudeCode)
    let before = try Data(contentsOf: fixture.legacyHelper)
    try fixture.rebuildEmbedded(label: "build-2")
    try await fixture.manager.refreshInstalledHelper()
    XCTAssertEqual(try Data(contentsOf: fixture.legacyHelper), before)
    do {
      try await fixture.manager.install(.claudeCode)
      XCTFail("Legacy install must require reviewed migration")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Review an Update or Repair"))
    }
    XCTAssertEqual(try Data(contentsOf: fixture.legacyHelper), before)
  }

  private func contractObject() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HookHelperContract.current)) as? [String: Any])
  }

  private func decodeContract(_ object: [String: Any]) throws -> HookHelperContract {
    try JSONDecoder().decode(HookHelperContract.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

private struct LifecycleFixture {
  let root: URL
  let embedded: URL
  let support: URL
  let manager: HookInstallationManager
  var legacyHelper: URL { support.appendingPathComponent("bin/bex-hook") }

  init() throws {
    root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("Bex-helper-lifecycle-\(UUID().uuidString)")
    embedded = root.appendingPathComponent("embedded-bex-hook")
    support = root.appendingPathComponent("support")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // These are inert fixture bytes. Lifecycle checks inspect metadata; they never execute them.
    try Data("inert helper build-1".utf8).write(to: embedded)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: embedded.path)
    manager = HookInstallationManager(
      environment: [:], homeDirectory: root, embeddedHelperURL: embedded,
      supportDirectory: support, signatureVerifier: { _ in }, helperContractReader: { _ in .current }
    )
  }

  func makeManager(
    signatureVerifier: @escaping @Sendable (URL) throws -> Void = { _ in },
    contractReader: @escaping @Sendable (URL) throws -> HookHelperContract = { _ in .current },
    transactionFaultInjector: @escaping @Sendable (Int, URL?) throws -> Void = { _, _ in }
  ) -> HookInstallationManager {
    HookInstallationManager(
      environment: [:], homeDirectory: root, embeddedHelperURL: embedded,
      supportDirectory: support, signatureVerifier: signatureVerifier, helperContractReader: contractReader,
      transactionFaultInjector: transactionFaultInjector
    )
  }

  func target(_ client: PromptClient) -> HookIntegrationTarget {
    client == .codex ? .codex : .claudeCode
  }

  func install(_ client: PromptClient) async throws -> HookIntegrationDescriptor {
    let descriptor = try await manager.resolve(target(client))
    let review = try await manager.prepare(.install, for: descriptor)
    _ = try await manager.apply(reviewID: review.id)
    return descriptor
  }

  func rebuildEmbedded(label: String) throws {
    try Data("inert helper \(label)".utf8).write(to: embedded)
  }

  func writeHeartbeat(for client: PromptClient) throws -> Date {
    let directory = support.appendingPathComponent("PromptGate/heartbeats")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let date = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.up))
    try JSONEncoder().encode(HookHeartbeat(
      version: HookProtocolConstants.version, client: client, seenAt: date, integrationID: client.rawValue
    )).write(to: directory.appendingPathComponent("\(client.rawValue).json"))
    return date
  }

  func snapshot(_ descriptor: HookIntegrationDescriptor) throws -> [Data] {
    let inode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: descriptor.helperURL.path)[.systemFileNumber] as? NSNumber)
    return try [
      Data(contentsOf: descriptor.helperURL), Data(contentsOf: descriptor.configurationURL),
      Data(contentsOf: support.appendingPathComponent("PromptGate/install-manifest.json")),
      Data(inode.stringValue.utf8),
    ]
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
