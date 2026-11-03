import Foundation

// Deliberately not wired to WKWebView, Vite, credentials, or GrammarService.
// The embedding host must authenticate the packaged main frame BEFORE receive().
// All access and injected callbacks are serialized by the main actor.
@MainActor
public final class NativeCorrectionBridge {
    public static let maximumBytes = 128_000
    public static let maximumRequestsPerSession = 4_096

    public struct Job: Equatable {
        public let sessionID: String
        public let requestID: String
        // Host-generated identity: renderer IDs never grant consent or completion authority.
        fileprivate let nonce: UUID
    }
    public enum Event {
        case consentRequired(Job, BridgeRequest, providerName: String)
        case correctionAuthorized(Job, BridgeRequest)
        case cancellationRequested(Job)
    }
    private enum Stage { case consent, provider, cancelled }
    private struct Pending {
        let job: Job
        let request: BridgeRequest
        var stage: Stage
    }
    private let providerName: String
    private let emit: (String) -> Void
    private let dispatch: (Event) -> Void
    private var sessionID: String?
    private var usedIDs = Set<String>()
    private var pending: [String: Pending] = [:]
    private var closed = false

    public init(providerName: String, emit: @escaping (String) -> Void,
                dispatch: @escaping (Event) -> Void) throws {
        guard validText(providerName, maximum: 80, nonblank: true) else { throw BridgeValidation.invalid }
        self.providerName = providerName
        self.emit = emit
        self.dispatch = dispatch
    }

    // No origin string/boolean supplied by renderer can authorize this entry point.
    // One instance belongs to exactly one trusted document/account/provider lifetime.
    public func receive(_ json: String) {
        guard !closed, json.utf8.count <= Self.maximumBytes,
              let data = json.data(using: .utf8),
              let message = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        if message.kind == .cancel {
            guard message.sessionID == sessionID, let entry = pending[message.requestID] else { return }
            cancel(entry)
            return
        }
        if message.kind == .hello {
            guard sessionID == nil else { return } // Never replace an active session from untrusted input.
            sessionID = message.sessionID
            usedIDs.insert(message.requestID)
            reply(message.requestID, payload: ["kind": "capabilities", "capabilities": [
                "providerName": providerName, "perRequestConsent": true, "operations": ["correct", "cancel"],
                "explanationLanguages": ["ko", "en"]
            ]])
            return
        }
        guard message.sessionID == sessionID, !usedIDs.contains(message.requestID) else { return }
        guard usedIDs.count < Self.maximumRequestsPerSession else { close(); return }
        // Consume IDs even when overloaded, preventing a replay from later opening consent.
        usedIDs.insert(message.requestID)
        guard pending.count < 4 else { failure(message.requestID, code: "unavailable"); return }
        guard let request = message.request else { return }
        let job = Job(sessionID: message.sessionID, requestID: message.requestID, nonce: UUID())
        pending[message.requestID] = Pending(job: job, request: request, stage: .consent)
        dispatch(.consentRequired(job, request, providerName: providerName))
    }

    // Called ONLY by the native consent UI after showing provider, full text, and source excerpt.
    // No renderer message can reach this API. Repeated/stale/forged job completions do nothing.
    public func resolveConsent(_ job: Job, granted: Bool) {
        guard !closed, var entry = lookup(job), entry.stage == .consent else { return }
        if !granted {
            pending.removeValue(forKey: job.requestID)
            failure(job.requestID, code: "consent-denied")
            return
        }
        entry.stage = .provider
        pending[job.requestID] = entry
        dispatch(.correctionAuthorized(job, entry.request))
    }

    // The native provider adapter supplies bounded JSON AFTER its own technical-span
    // masking/restoration/validation. This parser does not prove semantic preservation.
    public func complete(_ job: Job, resultJSON: String) {
        guard let entry = lookup(job) else { return }
        if entry.stage == .cancelled { pending.removeValue(forKey: job.requestID); return }
        guard !closed, entry.stage == .provider else { return }
        pending.removeValue(forKey: job.requestID)
        guard let canonical = try? Self.validateResultJSON(resultJSON, original: entry.request.text),
              let encoded = canonical.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: encoded) else {
            failure(job.requestID, code: "provider-failed"); return
        }
        reply(job.requestID, payload: ["kind": "result", "result": object])
    }

    /// Shared wire validation for native provider adapters. This proves schema and
    /// exact-text correspondence, not consent, account binding, or semantic quality.
    public static func validateResultJSON(_ json: String, original: String) throws -> String {
        guard json.utf8.count <= maximumBytes, let data = json.data(using: .utf8) else {
            throw BridgeValidation.invalid
        }
        let result = try JSONDecoder().decode(BridgeResult.self, from: data)
        guard result.matches(original) else { throw BridgeValidation.invalid }
        let encoded = try JSONEncoder().encode(result)
        guard encoded.count <= maximumBytes, let canonical = String(data: encoded, encoding: .utf8) else {
            throw BridgeValidation.invalid
        }
        return canonical
    }

    public func fail(_ job: Job) {
        guard let entry = lookup(job), entry.stage != .consent else { return }
        pending.removeValue(forKey: job.requestID)
        if !closed, entry.stage == .provider { failure(job.requestID, code: "provider-failed") }
    }

    // The embedding host MUST impose an independent deadline (recommended 30 seconds)
    // on both consent and provider work. Renderer timeouts are not host resource control.
    public func expire(_ job: Job) {
        guard !closed, let entry = lookup(job), entry.stage != .cancelled else { return }
        cancel(entry)
        failure(job.requestID, code: "unavailable")
    }

    // A cancelled job retains its capacity slot until the adapter confirms that consent
    // UI/provider work stopped. This prevents cancel/retry from creating unbounded work.
    public func acknowledgeCancellation(_ job: Job) {
        guard let entry = lookup(job), entry.stage == .cancelled else { return }
        pending.removeValue(forKey: job.requestID)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        let jobs = Array(pending.values)
        for entry in jobs { cancel(entry) }
        sessionID = nil
        usedIDs.removeAll()
    }

    private func lookup(_ job: Job) -> Pending? {
        guard let entry = pending[job.requestID], entry.job == job else { return nil }
        return entry
    }
    private func cancel(_ entry: Pending) {
        guard var current = lookup(entry.job), current.stage != .cancelled else { return }
        current.stage = .cancelled
        pending[current.job.requestID] = current
        dispatch(.cancellationRequested(current.job))
    }
    private func failure(_ id: String, code: String) { reply(id, payload: ["kind": "error", "code": code]) }
    private func reply(_ id: String, payload: [String: Any]) {
        guard !closed, let sessionID else { return }
        var object = payload
        object["bridgeVersion"] = 1
        object["sessionID"] = sessionID
        object["requestID"] = id
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= Self.maximumBytes, let json = String(data: data, encoding: .utf8) else {
            // Even valid result fields can exceed the envelope budget after JSON escaping.
            if payload["kind"] as? String != "error" { failure(id, code: "provider-failed") }
            return
        }
        emit(json)
    }
}

public enum BridgeValidation: Error { case invalid }
private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func exactKeys(_ decoder: Decoder, _ names: Set<String>) throws {
    let keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    guard Set(keys) == names else { throw BridgeValidation.invalid }
}
// JavaScript trim whitespace, not Swift's broader/narrower Unicode whitespace set.
private let wireWhitespace = CharacterSet(charactersIn: "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{0020}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
private func validText(_ value: String, maximum: Int, nonblank: Bool = false) -> Bool {
    value.utf16.count <= maximum && (!nonblank || !value.trimmingCharacters(in: wireWhitespace).isEmpty)
}
private func exactText(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }
private func containsExact(_ text: String, _ part: String) -> Bool {
    (text as NSString).range(of: part, options: .literal).location != NSNotFound
}
private struct Envelope: Decodable {
    enum Kind: String, Decodable { case hello, correct, cancel }
    let sessionID: String
    let requestID: String
    let kind: Kind
    let request: BridgeRequest?
    enum CodingKeys: String, CodingKey { case bridgeVersion, sessionID, requestID, kind, request }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .bridgeVersion) == 1 else { throw BridgeValidation.invalid }
        sessionID = try c.decode(String.self, forKey: .sessionID)
        requestID = try c.decode(String.self, forKey: .requestID)
        guard sessionID.utf8.count == 36, UUID(uuidString: sessionID) != nil,
              requestID.utf8.count == 36, UUID(uuidString: requestID) != nil else { throw BridgeValidation.invalid }
        kind = try c.decode(Kind.self, forKey: .kind)
        try exactKeys(decoder, kind == .correct ? ["bridgeVersion", "sessionID", "requestID", "kind", "request"] : ["bridgeVersion", "sessionID", "requestID", "kind"])
        request = kind == .correct ? try c.decode(BridgeRequest.self, forKey: .request) : nil
    }
}

public struct BridgeRequest: Decodable, Equatable {
    public let text: String
    public let policy: Policy
    public let source: Source?
    enum CodingKeys: String, CodingKey { case protocolVersion, text, policy, source }
    public init(from decoder: Decoder) throws {
        try exactKeys(decoder, ["protocolVersion", "text", "policy", "source"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .protocolVersion) == 1 else { throw BridgeValidation.invalid }
        text = try c.decode(String.self, forKey: .text)
        guard validText(text, maximum: 12_000, nonblank: true) else { throw BridgeValidation.invalid }
        policy = try c.decode(Policy.self, forKey: .policy)
        source = try c.decodeIfPresent(Source.self, forKey: .source)
    }
    public struct Policy: Decodable, Equatable {
        public let vocabulary: String
        public let maxNotes: Int
        public let alternatives: Bool
        public let focus: String
        public let explanationLanguage: String?
        enum CodingKeys: String, CodingKey { case vocabulary, maxNotes, alternatives, focus, explanationLanguage }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // A legacy policy has exactly four fields. Explicit null is not omission.
            let languagePresent = c.contains(.explanationLanguage)
            try exactKeys(decoder, languagePresent
                ? ["vocabulary", "maxNotes", "alternatives", "focus", "explanationLanguage"]
                : ["vocabulary", "maxNotes", "alternatives", "focus"])
            vocabulary = try c.decode(String.self, forKey: .vocabulary)
            maxNotes = try c.decode(Int.self, forKey: .maxNotes)
            alternatives = try c.decode(Bool.self, forKey: .alternatives)
            focus = try c.decode(String.self, forKey: .focus)
            explanationLanguage = languagePresent ? try c.decode(String.self, forKey: .explanationLanguage) : nil
            guard explanationLanguage == nil || ["ko", "en"].contains(explanationLanguage!),
                   ["familiar", "stretch", "wide"].contains(vocabulary), (0...2).contains(maxNotes),
                  ["general", "articles", "verb-forms", "expression"].contains(focus) else { throw BridgeValidation.invalid }
        }
    }
    public struct Source: Decodable, Equatable {
        public let title: String
        public let section: String
        public let excerpt: String
        enum CodingKeys: String, CodingKey { case title, section, excerpt }
        public init(from decoder: Decoder) throws {
            try exactKeys(decoder, ["title", "section", "excerpt"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let rawTitle = try c.decode(String.self, forKey: .title)
            let rawSection = try c.decode(String.self, forKey: .section)
            excerpt = try c.decode(String.self, forKey: .excerpt)
            guard validText(rawTitle, maximum: 160, nonblank: true), validText(rawSection, maximum: 160),
                  validText(excerpt, maximum: 4_000, nonblank: true) else { throw BridgeValidation.invalid }
            title = rawTitle.trimmingCharacters(in: wireWhitespace)
            section = rawSection.trimmingCharacters(in: wireWhitespace)
        }
    }
}

private struct BridgeResult: Codable {
    let protocolVersion: Int
    let original: String
    let corrected: String
    let notes: [Note]
    let provenance: String
    enum CodingKeys: String, CodingKey { case protocolVersion, original, corrected, notes, provenance }
    init(from decoder: Decoder) throws {
        try exactKeys(decoder, ["protocolVersion", "original", "corrected", "notes", "provenance"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        original = try c.decode(String.self, forKey: .original)
        corrected = try c.decode(String.self, forKey: .corrected)
        notes = try c.decode([Note].self, forKey: .notes)
        provenance = try c.decode(String.self, forKey: .provenance)
        guard protocolVersion == 1, provenance == "provider", validText(original, maximum: 12_000),
              validText(corrected, maximum: 24_000, nonblank: true), notes.count <= 20 else { throw BridgeValidation.invalid }
    }
    func matches(_ text: String) -> Bool {
        exactText(original, text) && notes.allSatisfy {
            containsExact(original, $0.before) && ($0.kind != "correction" || containsExact(corrected, $0.after))
        }
    }
    struct Note: Codable {
        let kind: String
        let category: String
        let before: String
        let after: String
        let reason: String
        enum CodingKeys: String, CodingKey { case kind, category, before, after, reason }
        init(from decoder: Decoder) throws {
            try exactKeys(decoder, ["kind", "category", "before", "after", "reason"])
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            category = try c.decode(String.self, forKey: .category)
            before = try c.decode(String.self, forKey: .before)
            after = try c.decode(String.self, forKey: .after)
            reason = try c.decode(String.self, forKey: .reason)
            guard ["correction", "alternative"].contains(kind), ["articles", "verb-forms", "expression"].contains(category),
                  validText(before, maximum: 1_000), !before.isEmpty,
                  validText(after, maximum: 1_000), !after.isEmpty, !exactText(before, after),
                  validText(reason, maximum: 2_000, nonblank: true) else { throw BridgeValidation.invalid }
        }
    }
}
