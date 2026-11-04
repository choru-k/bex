import Foundation

/// Field identities stay in the agent. Only an opaque, connection-local token crosses IPC.
@MainActor
protocol AccessibilityCapturedField: AnyObject {
  var processID: Int32 { get }
  var bundleIdentifier: String { get }
  var applicationName: String { get }
  var launchDate: Date { get }
  var original: String { get }
  func revalidate(before deadline: AccessibilityObservationDeadline) throws
}

@MainActor
protocol AccessibilityAgentObserving: AnyObject {
  var isTrusted: Bool { get }
  func capture(excluding processID: Int32, before deadline: AccessibilityObservationDeadline) throws -> any AccessibilityCapturedField
}

@MainActor
final class AccessibilityCaptureStore {
  private struct Entry {
    let field: any AccessibilityCapturedField
    let expiresAt: Date
  }
  private let observer: any AccessibilityAgentObserving
  private let callerProcessID: Int32
  private let now: @MainActor () -> Date
  private let limit: Int
  private var captures: [UUID: Entry] = [:]
  private(set) var session: UUID?
  private var closed = false

  init(observer: any AccessibilityAgentObserving, callerProcessID: Int32,
       limit: Int = AccessibilityAgentContract.maximumCaptures, now: @escaping @MainActor () -> Date = { Date() }) {
    self.observer = observer
    self.callerProcessID = callerProcessID
    self.limit = max(1, limit)
    self.now = now
  }

  func handle(_ request: AccessibilityAgentRequest, deadline: AccessibilityObservationDeadline = AccessibilityObservationDeadline()) -> AccessibilityAgentResponse {
    do {
      try deadline.check()
      guard !closed else { throw AccessibilityAgentFailure.cancelled }
      guard request.hasValidShape else { throw AccessibilityAgentFailure.malformed }
      if request.operation == .hello {
        guard session == nil else { throw AccessibilityAgentFailure.unauthorized }
        session = UUID()
        // Only constants and a random challenge/session travel before authenticated hello.
        return AccessibilityAgentResponse(requestID: request.id, session: session, challenge: request.challenge)
      }
      guard let session, request.session == session else { throw AccessibilityAgentFailure.unauthorized }
      captures = captures.filter { $0.value.expiresAt > now() }
      if !observer.isTrusted {
        captures.removeAll()
        if request.operation == .status {
          return AccessibilityAgentResponse(requestID: request.id, session: session, trusted: false)
        }
        if request.operation != .discard { throw AccessibilityAgentFailure.untrusted }
      }
      switch request.operation {
      case .hello: throw AccessibilityAgentFailure.unauthorized
      case .status:
        return AccessibilityAgentResponse(requestID: request.id, session: session, trusted: observer.isTrusted)
      case .capture:
        guard observer.isTrusted else { throw AccessibilityAgentFailure.untrusted }
        guard captures.count < limit else { throw AccessibilityAgentFailure.capacity }
        let field = try observer.capture(excluding: callerProcessID, before: deadline)
        guard field.processID > 0, field.processID != callerProcessID,
          !field.bundleIdentifier.isEmpty, field.bundleIdentifier.utf8.count <= 512,
          field.applicationName.utf8.count <= 512,
          !field.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          field.original.utf8.count <= AccessibilityAgentContract.maximumDraftBytes
        else { throw AccessibilityAgentFailure.unsupported }
        try field.revalidate(before: deadline)
        try deadline.check()
        let token = UUID()
        let capture = AccessibilityAgentCapture(token: token, processID: field.processID,
          bundleIdentifier: field.bundleIdentifier, applicationName: field.applicationName,
          launchDate: field.launchDate, original: field.original)
        let response = AccessibilityAgentResponse(requestID: request.id, session: session, captured: capture)
        _ = try AccessibilityAgentCodec.encode(response)
        captures[token] = Entry(field: field, expiresAt: now().addingTimeInterval(AccessibilityAgentContract.captureLifetime))
        return response
      case .validate, .consume:
        guard observer.isTrusted, let token = request.capture, let entry = captures[token] else {
          throw AccessibilityAgentFailure.stale
        }
        do { try entry.field.revalidate(before: deadline) } catch {
          captures.removeValue(forKey: token)
          throw AccessibilityAgentFailure.stale
        }
        if request.operation == .consume { captures.removeValue(forKey: token) }
        return AccessibilityAgentResponse(requestID: request.id, session: session)
      case .discard:
        if let token = request.capture { captures.removeValue(forKey: token) }
        return AccessibilityAgentResponse(requestID: request.id, session: session)
      }
    } catch {
      return AccessibilityAgentResponse(requestID: request.id,
        failure: (error as? AccessibilityAgentFailure) ?? .unavailable)
    }
  }

  func close() {
    closed = true
    captures.removeAll()
    session = nil
  }
}
