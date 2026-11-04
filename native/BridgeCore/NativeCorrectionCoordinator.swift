import Foundation

/// Trusted native UI only. Show the provider, exact text and source before granting.
/// Cancellation must dismiss the matching UI; return only after its work has stopped.
@MainActor public protocol NativeCorrectionConsentService: AnyObject {
    func requestConsent(for request: BridgeRequest, providerName: String) async throws -> Bool
}

/// Bound to one immutable account/destination when injected. Implement the FULL request
/// contract, including policy/source and technical-span protection. Never delegate a
/// partial conversion to GrammarService. Return only after owned child work has stopped.
@MainActor public protocol NativeCorrectionProviderService: AnyObject {
    func correct(_ request: BridgeRequest) async throws -> String
}

// Internal scheduler seam: production always uses the independent native Task.sleep.
// schedule must not call inline; cancel must synchronously disarm the callback.
// Scheduled timer work itself must terminate cooperatively (unlike external services).
@MainActor protocol NativeDeadline: AnyObject { func cancel() }
@MainActor protocol NativeDeadlineScheduler: AnyObject {
    func schedule(nanoseconds: UInt64, action: @escaping @MainActor () -> Void) -> NativeDeadline
}
@MainActor private final class TaskDeadline: NativeDeadline {
    private var task: Task<Void, Never>?
    init(nanoseconds: UInt64, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
@MainActor private final class TaskDeadlineScheduler: NativeDeadlineScheduler {
    func schedule(nanoseconds: UInt64, action: @escaping @MainActor () -> Void) -> NativeDeadline {
        TaskDeadline(nanoseconds: nanoseconds, action: action)
    }
}

/// Execution owner for one authenticated packaged document/account/provider lifetime.
/// The host MUST authenticate the main frame before receiveTrustedDocumentMessage.
/// Never wire this entry point to Vite. This class itself performs no network/UI work.
@MainActor public final class NativeCorrectionCoordinator {
    private final class Relay { weak var owner: NativeCorrectionCoordinator? }
    private enum Stage { case consent, provider }
    private struct Operation {
        let job: NativeCorrectionBridge.Job
        let stage: Stage
        let task: Task<Void, Never>
        let deadline: NativeDeadline
        var cancelled = false
    }
    private let bridge: NativeCorrectionBridge
    private let scheduler: NativeDeadlineScheduler
    private let consentTimeout: UInt64
    private let providerTimeout: UInt64
    private var consent: NativeCorrectionConsentService?
    private var provider: NativeCorrectionProviderService?
    private var emit: ((String) -> Void)?
    private var operations: [String: Operation] = [:]
    // Sendable handles also allow nonisolated deinit to request cancellation without
    // reaching into actor-isolated service/deadline objects. Kept in lockstep below.
    private var runningTasks: [String: Task<Void, Never>] = [:]
    private var closed = false

    public convenience init(providerName: String,
                            consent: NativeCorrectionConsentService,
                            provider: NativeCorrectionProviderService,
                            consentTimeoutNanoseconds: UInt64 = 30_000_000_000,
                            providerTimeoutNanoseconds: UInt64 = 30_000_000_000,
                            emit: @escaping (String) -> Void) throws {
        try self.init(providerName: providerName, consent: consent, provider: provider,
                      consentTimeoutNanoseconds: consentTimeoutNanoseconds,
                      providerTimeoutNanoseconds: providerTimeoutNanoseconds,
                      scheduler: TaskDeadlineScheduler(), emit: emit)
    }
    init(providerName: String, consent: NativeCorrectionConsentService,
         provider: NativeCorrectionProviderService, consentTimeoutNanoseconds: UInt64,
         providerTimeoutNanoseconds: UInt64, scheduler: NativeDeadlineScheduler,
         emit: @escaping (String) -> Void) throws {
        // Prevent accidentally disabling the host deadline through zero/overflow values.
        guard (1...300_000_000_000).contains(consentTimeoutNanoseconds),
              (1...300_000_000_000).contains(providerTimeoutNanoseconds) else {
            throw BridgeValidation.invalid
        }
        let relay = Relay()
        bridge = try NativeCorrectionBridge(providerName: providerName, emit: { [relay] json in
            relay.owner?.emit?(json)
        }, dispatch: { [relay] event in relay.owner?.handle(event) })
        self.consent = consent
        self.provider = provider
        self.scheduler = scheduler
        self.consentTimeout = consentTimeoutNanoseconds
        self.providerTimeout = providerTimeoutNanoseconds
        self.emit = emit
        relay.owner = self
    }

    deinit {
        // Dropping the owner must still signal cancellation. Hosts should explicitly
        // closeAndWait to establish quiescence rather than relying on destruction.
        for task in runningTasks.values { task.cancel() }
    }

    public func receiveTrustedDocumentMessage(_ json: String) {
        guard !closed else { return }
        bridge.receive(json)
    }

    /// Includes cancelled services which have not yet returned. Cancellation is not an ack.
    public var outstandingOperationCount: Int { operations.count }
    public var isQuiescent: Bool { operations.isEmpty }

    /// Immediately revoke delivery and admission, cancel UI/provider work, and sever idle
    /// account/UI references. Running tasks retain their original service until termination.
    public func close() {
        guard !closed else { return }
        closed = true
        emit = nil
        bridge.close()
        consent = nil
        provider = nil
    }

    /// Use on document/account replacement BEFORE constructing another coordinator. A
    /// noncooperative service deliberately keeps this suspended instead of silently allowing
    /// unbounded work across repeated replacements. UI may revoke the account immediately.
    public func closeAndWait() async {
        close()
        await waitForCurrentOperations()
    }

    // Snapshot barrier used by deterministic tests; unlike closeAndWait this does not
    // revoke admission and therefore is not a lifetime replacement barrier.
    func waitForCurrentOperations() async {
        let tasks = operations.values.map(\.task)
        for task in tasks { await task.value }
    }

    private func handle(_ event: NativeCorrectionBridge.Event) {
        switch event {
        case let .consentRequired(job, request, providerName):
            guard !closed, let consent else { return }
            let timer = deadline(for: job, stage: .consent, nanoseconds: consentTimeout)
            let task = Task { @MainActor [weak self, consent] in
                let granted: Bool
                do {
                    try Task.checkCancellation()
                    granted = try await consent.requestConsent(for: request, providerName: providerName)
                } catch { granted = false }
                self?.consentReturned(job, granted: granted)
            }
            operations[job.requestID] = Operation(job: job, stage: .consent, task: task, deadline: timer)
            runningTasks[job.requestID] = task
        case let .correctionAuthorized(job, request):
            guard !closed, let provider else { return }
            let timer = deadline(for: job, stage: .provider, nanoseconds: providerTimeout)
            let task = Task { @MainActor [weak self, provider] in
                let result: String?
                do {
                    try Task.checkCancellation()
                    result = try await provider.correct(request)
                } catch { result = nil }
                self?.providerReturned(job, result: result)
            }
            operations[job.requestID] = Operation(job: job, stage: .provider, task: task, deadline: timer)
            runningTasks[job.requestID] = task
        case let .cancellationRequested(job):
            guard var operation = operations[job.requestID], operation.job == job else { return }
            operation.cancelled = true
            operations[job.requestID] = operation
            operation.deadline.cancel()
            operation.task.cancel()
        }
    }
    private func deadline(for job: NativeCorrectionBridge.Job, stage: Stage,
                          nanoseconds: UInt64) -> NativeDeadline {
        scheduler.schedule(nanoseconds: nanoseconds) { [weak self] in
            guard let self, let operation = self.operations[job.requestID],
                  operation.job == job, operation.stage == stage, !operation.cancelled else { return }
            self.bridge.expire(job)
        }
    }
    private func take(_ job: NativeCorrectionBridge.Job, stage: Stage) -> Operation? {
        guard let operation = operations[job.requestID], operation.job == job,
              operation.stage == stage else { return nil }
        operations.removeValue(forKey: job.requestID)
        runningTasks.removeValue(forKey: job.requestID)
        operation.deadline.cancel()
        return operation
    }
    private func consentReturned(_ job: NativeCorrectionBridge.Job, granted: Bool) {
        guard let operation = take(job, stage: .consent) else { return }
        if closed || operation.cancelled { bridge.acknowledgeCancellation(job) }
        else { bridge.resolveConsent(job, granted: granted) }
    }
    private func providerReturned(_ job: NativeCorrectionBridge.Job, result: String?) {
        guard let operation = take(job, stage: .provider) else { return }
        if closed || operation.cancelled { bridge.acknowledgeCancellation(job) }
        else if let result { bridge.complete(job, resultJSON: result) }
        else { bridge.fail(job) }
    }
}
