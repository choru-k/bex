import Foundation

/// Process-wide barrier for cooperative Bex writes. Deliberately broader than any
/// service/suite pair: sharing EITHER backing domain cannot bypass this barrier.
/// External processes and direct writes outside these stores are not covered.
@MainActor
final class AccountMutationCoordinator {
  nonisolated static let shared = AccountMutationCoordinator()

  struct AdmissionReservation: Sendable {
    fileprivate let coordinator: UUID
    fileprivate let epoch: UUID
  }

  struct CredentialOperationToken: Sendable {
    fileprivate let coordinator: UUID
    fileprivate let domain: String
    fileprivate let generation: UUID
    fileprivate let sessionVersion: UUID? // nil identifies a login, not a refresh
  }

  enum AdmissionError: Error { case closed, staleReservation }

  private struct HostLifetime {
    let revoke: @MainActor @Sendable () -> Void
    let drain: @MainActor @Sendable () async -> Void
  }

  private struct CredentialState {
    var generation = UUID()
    var sessionVersion = UUID()
  }

  private let identity = UUID()
  private var epoch = UUID()
  private var admissionClosed = false
  private var draining = false
  private var activeMutation = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var hosts: [UUID: HostLifetime] = [:]
  private var credentials: [String: CredentialState] = [:]

  // Internal diagnostics for deterministic lifecycle assertions, not authority.
  var isAdmissionClosed: Bool { admissionClosed }
  var registeredHostCount: Int { hosts.count }
  var queuedMutationCount: Int { waiters.count }

  // Nonisolated construction is inert. Production stores always default to shared.
  // An isolated coordinator is useful for deterministic synthetic tests only.
  nonisolated init() {}

  func reserveAdmission() throws -> AdmissionReservation {
    guard !admissionClosed else { throw AdmissionError.closed }
    return AdmissionReservation(coordinator: identity, epoch: epoch)
  }

  /// Call after each suspension while assembling the epoch-bound configuration.
  func validateAdmission(_ reservation: AdmissionReservation) throws {
    guard !admissionClosed else { throw AdmissionError.closed }
    guard reservation.coordinator == identity, reservation.epoch == epoch else {
      throw AdmissionError.staleReservation
    }
  }

  /// Validation and registration are one synchronous MainActor operation. The
  /// caller must load its document without suspending after this succeeds.
  func registerHost(
    reservation: AdmissionReservation,
    revoke: @escaping @MainActor @Sendable () -> Void,
    drain: @escaping @MainActor @Sendable () async -> Void
  ) throws -> UUID {
    try validateAdmission(reservation)
    let id = UUID()
    hosts[id] = HostLifetime(revoke: revoke, drain: drain)
    return id
  }

  /// Only call after the entire owned host lifetime, including cancelled work,
  /// has terminated. Revocation or cancellation alone is insufficient.
  func removeHost(_ id: UUID) {
    hosts.removeValue(forKey: id)
  }

  /// Nonthrowing preferences writes preserve their existing completion contract:
  /// once enqueued they finish even if the caller is cancelled. No silent skip.
  func withMutation<T: Sendable>(
    _ write: @MainActor @Sendable () -> T
  ) async -> T {
    await acquireMutation()
    defer { releaseMutation() }
    return write()
  }

  /// Cancellation can skip a throwing write only BEFORE its synchronous commit.
  /// It never abandons a drain, releases another writer, or rolls back a write
  /// which already started. The sync commit has no actor hop or suspension.
  func withThrowingMutation<T: Sendable>(
    _ write: @MainActor @Sendable () throws -> T
  ) async throws -> T {
    await acquireMutation()
    defer { releaseMutation() }
    try Task.checkCancellation()
    return try write()
  }

  func beginCredentialOperation(domain: String) -> CredentialOperationToken {
    invalidateCredentialOperations(domain: domain)
    let state = credentialState(domain: domain)
    return CredentialOperationToken(coordinator: identity, domain: domain,
      generation: state.generation, sessionVersion: nil)
  }

  @discardableResult
  func cancelCredentialOperation(_ token: CredentialOperationToken, domain: String) -> Bool {
    guard token.domain == domain, token.sessionVersion == nil, isCurrent(token) else { return false }
    invalidateCredentialOperations(domain: token.domain)
    return true
  }

  func invalidateCredentialOperations(domain: String) {
    var state = credentialState(domain: domain)
    state.generation = UUID()
    credentials[domain] = state
  }

  /// The backing read and version capture are synchronous in this actor turn,
  /// so a cooperative commit cannot separate them. No mutation permit is held.
  func credentialSnapshot<T: Sendable>(
    domain: String,
    read: @MainActor @Sendable () throws -> T?
  ) rethrows -> (value: T, token: CredentialOperationToken)? {
    guard let value = try read() else { return nil }
    let state = credentialState(domain: domain)
    return (value, CredentialOperationToken(coordinator: identity, domain: domain,
      generation: state.generation, sessionVersion: state.sessionVersion))
  }

  /// An unconditional replacement/deletion invalidates old network work on
  /// INTENT, before waiting for hosts. A failed/cancelled write never revives it.
  func replaceCredential<T: Sendable>(
    domain: String,
    write: @MainActor @Sendable () throws -> T
  ) async throws -> T {
    invalidateCredentialOperations(domain: domain)
    return try await withThrowingMutation {
      // Also invalidate work begun while this replacement was draining/queued.
      self.invalidateCredentialOperations(domain: domain)
      var state = self.credentialState(domain: domain)
      state.sessionVersion = UUID()
      self.credentials[domain] = state
      return try write()
    }
  }

  /// Returns false for a stale login/refresh. Both checks are required: another
  /// login or disconnect may arrive while this mutation is awaiting host drain.
  func commitCredential(
    domain: String,
    token: CredentialOperationToken,
    write: @MainActor @Sendable () throws -> Void
  ) async throws -> Bool {
    guard token.domain == domain, isCurrent(token) else { return false }
    return try await withThrowingMutation {
      guard self.isCurrent(token) else { return false }
      var state = self.credentialState(domain: domain)
      // Consume the operation before attempting storage. A storage error cannot
      // let a duplicate completion overwrite a subsequent successful operation.
      if token.sessionVersion == nil { state.generation = UUID() }
      state.sessionVersion = UUID()
      self.credentials[domain] = state
      try write()
      return true
    }
  }

  private func credentialState(domain: String) -> CredentialState {
    if let state = credentials[domain] { return state }
    let state = CredentialState()
    credentials[domain] = state
    return state
  }

  private func isCurrent(_ token: CredentialOperationToken) -> Bool {
    guard token.coordinator == identity else { return false }
    let state = credentialState(domain: token.domain)
    return token.generation == state.generation
      && (token.sessionVersion == nil || token.sessionVersion == state.sessionVersion)
  }

  private func acquireMutation() async {
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
      if !admissionClosed {
        admissionClosed = true
        epoch = UUID()
        // Revoke EVERY host before the first await. Task cancellation is only a
        // request; the retained lifetime remains registered until drain ends.
        let captured = hosts
        draining = true
        for lifetime in captured.values { lifetime.revoke() }
        // This unstructured worker does not inherit caller cancellation. A host
        // that never terminates deliberately keeps all writes/admission blocked.
        Task { @MainActor in
          for lifetime in captured.values { await lifetime.drain() }
          for id in captured.keys { self.hosts.removeValue(forKey: id) }
          self.draining = false
          self.resumeNextMutation()
        }
      } else {
        resumeNextMutation()
      }
    }
  }

  private func resumeNextMutation() {
    guard !draining, !activeMutation else { return }
    guard !waiters.isEmpty else {
      admissionClosed = false
      return
    }
    activeMutation = true
    waiters.removeFirst().resume()
  }

  private func releaseMutation() {
    precondition(activeMutation)
    activeMutation = false
    // Do not reopen admission between queued mutations.
    resumeNextMutation()
  }
}
