import Foundation

/// The jobs Bex asks a model to do, split by how long each one is allowed to take.
///
/// This exists because one "selected model" cannot serve all of them honestly.
/// Non-negotiable 1 gives a Quick Check about two seconds and says background work may cost
/// anything — so a single setting forces the owner to pick a model that is either too slow
/// for the correction path or too weak for the analysis. Splitting the choice per job lets
/// each one be right.
///
/// `correction` is the base. Every other job falls back to it when it has no override of its
/// own, which is why the design mocks "Rewrites & Look Up" as "same as Correction" rather
/// than as a second copy of the same value.
enum ModelJob: String, CaseIterable, Identifiable, Sendable {
  /// Quick Check, Fix & Send, hook reviews — the latency-sacred path.
  case correction
  /// Questions asked about a card or a correction. A few seconds is fine here.
  case ask
  /// The hourly agent: pattern classification and the writer profile. Never interactive.
  case background
  /// More Formal / Friendlier / Shorter, and dictionary look-ups.
  case rewrites

  var id: String { rawValue }

  var title: String {
    switch self {
    case .correction: return "Correction"
    case .ask: return "Ask chat"
    case .background: return "Background agent"
    case .rewrites: return "Rewrites & Look Up"
    }
  }

  var detail: String {
    switch self {
    case .correction: return "Quick Check · Fix & Send · hooks — the sacred path"
    case .ask: return "Questions on cards and corrections — a few seconds is fine"
    case .background:
      return "Pattern grouping and your writer profile — never on the interactive path"
    case .rewrites: return "More Formal / Friendlier / Shorter · dictionary"
    }
  }

  /// The latency promise attached to this job, or `nil` when it has none.
  var budget: String? {
    switch self {
    case .correction: return "~2s budget"
    case .background: return "may cost anything"
    case .ask, .rewrites: return nil
    }
  }

  /// What an unset override means, in the picker.
  var inheritedLabel: String {
    self == .correction ? "provider default" : "same as Correction"
  }
}

/// Whether a model looks too heavy for the correction path.
///
/// Purely advisory — the owner may still pick it, and Bex says so rather than refusing.
//
// ponytail: substring matching on model names, not a measured latency table. It catches the
// tiers that are actually slow today and its failure mode is a missing warning, never a
// wrong correction. Ceiling: if this starts missing real cases, time the last N corrections
// per model and warn from the measurement instead of the name.
enum ModelLatencyWarning {
  private static let heavyMarkers = ["opus", "thinking", "reasoning", "-o1", "-o3", "pro"]

  static func warning(forCorrectionModel model: String) -> String? {
    let name = model.lowercased()
    guard heavyMarkers.contains(where: name.contains) else { return nil }
    return "\(model) is a heavyweight tier. A Quick Check has about two seconds to answer, "
      + "and a slow model here makes every correction wait."
  }
}
