import Foundation
import Security

/// Production identity only. Ad-hoc/debug bypasses would erase the new trust boundary.
enum AccessibilityAgentIdentity {
  enum Peer: Equatable { case app, helper }

  static func requirement(for peer: Peer) throws -> String {
    let identifier = peer == .app ? AccessibilityAgentContract.appIdentifier : AccessibilityAgentContract.helperIdentifier
    let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(AccessibilityAgentContract.teamIdentifier)\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      requirement != nil else { throw AccessibilityAgentFailure.unauthorized }
    return text
  }

  static func verifyOwnIdentity(as peer: Peer) throws {
    let text = try requirement(for: peer)
    var requirement: SecRequirement?
    var code: SecCode?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement, SecCodeCopySelf([], &code) == errSecSuccess, let code,
      SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    else { throw AccessibilityAgentFailure.unauthorized }
  }
}
