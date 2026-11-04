import Foundation
import XCTest
@testable import Bex

@MainActor
private final class StoreBarrierLatch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

@MainActor
final class AccountStoreBarrierTests: XCTestCase {
  func testSeparateKeychainInstancesShareBackingAndCannotWriteBeforeDrain() async throws {
    let domain = "bex.test.barrier.\(UUID())"
    let first = KeychainStore(service: domain, inMemory: true)
    let second = KeychainStore(service: domain, inMemory: true)
    try await first.saveAPIKey("old", for: .openAI)
    let initial = try await second.apiKey(for: .openAI)
    XCTAssertEqual(initial, "old")
    let gate = AccountMutationCoordinator.shared
    let started = StoreBarrierLatch()
    let release = StoreBarrierLatch()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      // Read from BOTH stores during drain. Holding an actor lock or mutation
      // permit across a read would deadlock this exact path.
      let firstRead = try? await first.apiKey(for: .openAI)
      let secondRead = try? await second.apiKey(for: .openAI)
      XCTAssertEqual(firstRead, "old")
      XCTAssertEqual(secondRead, "old")
      started.open()
      await release.wait()
    })
    let mutation = Task { try await second.saveAPIKey("new", for: .openAI) }
    await started.wait()
    let before = try await first.apiKey(for: .openAI)
    XCTAssertEqual(before, "old")
    XCTAssertTrue(gate.isAdmissionClosed)
    release.open()
    try await mutation.value
    let after = try await first.apiKey(for: .openAI)
    XCTAssertEqual(after, "new")
  }

  func testPreferencesReadAndNestedCorrectionOverrideDuringDrain() async throws {
    let suite = "bex.test.barrier.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = PreferencesStore(defaults: defaults)
    let second = PreferencesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    await first.setSelectedProvider(.openAI)
    await first.setSelectedModel("old", for: .openAI)
    let gate = AccountMutationCoordinator.shared
    let started = StoreBarrierLatch()
    let release = StoreBarrierLatch()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      let destination = try? await first.outboundDestination()
      XCTAssertEqual(destination?.model, "old")
      started.open()
      await release.wait()
    })
    let mutation = Task {
      await second.setModelOverride("new", for: .correction, provider: .openAI)
    }
    await started.wait()
    let before = await first.selectedModel(for: .openAI)
    XCTAssertEqual(before, "old")
    mutation.cancel() // nonthrowing setter must finish rather than silently skip
    release.open()
    await mutation.value
    let after = await first.selectedModel(for: .openAI)
    XCTAssertEqual(after, "new")
    XCTAssertFalse(gate.isAdmissionClosed)
  }

  func testRetiredModelReadHasNoWriteAndExplicitMigrationUsesBarrier() async throws {
    let suite = "bex.test.barrier.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("gpt-5.6", forKey: "selectedModel.openAICodex")
    let preferences = PreferencesStore(defaults: defaults)
    let read = await preferences.selectedModel(for: .openAICodex)
    XCTAssertEqual(read, LLMProvider.openAICodex.defaultModel)
    XCTAssertEqual(defaults.string(forKey: "selectedModel.openAICodex"), "gpt-5.6")
    let gate = AccountMutationCoordinator.shared
    let started = StoreBarrierLatch()
    let release = StoreBarrierLatch()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      started.open()
      await release.wait()
    })
    let mutation = Task { await preferences.migrateRetiredModels() }
    await started.wait()
    XCTAssertEqual(defaults.string(forKey: "selectedModel.openAICodex"), "gpt-5.6")
    release.open()
    await mutation.value
    XCTAssertEqual(defaults.string(forKey: "selectedModel.openAICodex"),
      LLMProvider.openAICodex.defaultModel)
  }

  func testAllAccountPreferenceSettersInvalidateReservations() async throws {
    let suite = "bex.test.barrier.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = PreferencesStore(defaults: defaults)
    let gate = AccountMutationCoordinator.shared
    let destination = try OutboundDestination(provider: .openAI, model: "synthetic")
    let writes: [@MainActor () async -> Void] = [
      { await preferences.setSelectedProvider(.openAI) },
      { await preferences.setSelectedModel("synthetic", for: .openAI) },
      { await preferences.setSelectedEffort(LLMProvider.openAI.defaultEffort, for: .openAI) },
      { await preferences.setOllamaURL("http://127.0.0.1:11434") },
      { await preferences.setModelOverride("synthetic", for: .correction, provider: .openAI) },
      { await preferences.setCodexPriorityTier(false) },
      { await preferences.setConfirmsHookOutboundPayloads(true) },
      { await preferences.acceptCurrentOutboundDisclosure(for: destination) },
      { await preferences.revokeOutboundDisclosure(for: destination) },
    ]
    for write in writes {
      let reservation = try gate.reserveAdmission()
      await write()
      XCTAssertThrowsError(try gate.validateAdmission(reservation))
    }
  }

  func testProfileDeletionParsesLowercaseUUIDsAndPreservesOtherProfiles() async throws {
    let suite = "bex.test.barrier.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let deleted = UUID()
    let retained = UUID()
    defaults.set(deleted.uuidString.lowercased(), forKey: "activeProfileID")
    defaults.set(retained.uuidString.lowercased(), forKey: "defaultProfileID")
    let preferences = PreferencesStore(defaults: defaults)
    await preferences.profileDeleted(id: deleted)
    let active = await preferences.activeProfileID()
    let defaultProfile = await preferences.defaultProfileID()
    XCTAssertNil(active)
    XCTAssertEqual(defaultProfile, retained)
    XCTAssertNil(defaults.string(forKey: "activeProfileID"))
    defaults.set(deleted.uuidString.lowercased(), forKey: "defaultProfileID")
    await preferences.profileDeleted(id: deleted)
    let removedDefault = await preferences.defaultProfileID()
    XCTAssertNil(removedDefault)
    XCTAssertNil(defaults.string(forKey: "defaultProfileID"))
  }

  func testCancelledKeychainWriteDoesNotMutateOrReopenBeforeDrain() async throws {
    let store = KeychainStore(inMemory: true)
    try await store.saveAPIKey("old", for: .openAI)
    let gate = AccountMutationCoordinator.shared
    let started = StoreBarrierLatch()
    let release = StoreBarrierLatch()
    _ = try gate.registerHost(reservation: gate.reserveAdmission(), revoke: {}, drain: {
      started.open()
      await release.wait()
    })
    let mutation = Task { try await store.deleteAPIKey(for: .openAI) }
    await started.wait()
    mutation.cancel()
    XCTAssertTrue(gate.isAdmissionClosed)
    let during = try await store.apiKey(for: .openAI)
    XCTAssertEqual(during, "old")
    release.open()
    do { try await mutation.value; XCTFail("Expected cancellation") }
    catch is CancellationError { }
    let after = try await store.apiKey(for: .openAI)
    XCTAssertEqual(after, "old")
    XCTAssertFalse(gate.isAdmissionClosed)
    try await store.saveAPIKey("next", for: .openAI)
    let next = try await store.apiKey(for: .openAI)
    XCTAssertEqual(next, "next")
  }
}
