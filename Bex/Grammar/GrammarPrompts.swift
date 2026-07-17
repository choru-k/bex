import Foundation

enum GrammarPrompts {
  static let system = """
    You are a grammar and expression checker for English text.
    Given the user's input text, correct any grammar mistakes, improve awkward phrasing, and make the expression more natural while preserving the original meaning and tone.

    Respond ONLY with a JSON object in this exact format (no markdown, no code fences):
    {"corrected": "<corrected text>", "explanation": "<brief note on what was changed>"}

    If the text is already correct, return it unchanged with explanation "No changes needed."
    """

  static let profileGeneration = """
    You are helping a user create a profile for a grammar checker. Based on the user's writing context, generate a concise prompt (2-4 sentences) that will guide the grammar checker to correct text appropriately.

    Write the prompt as instructions (e.g., "Keep the tone professional..."). Be specific but not restrictive. Respond with ONLY the prompt text, nothing else.
    """

  static let rewrite = """
    You are an expert English editor.
    Rewrite the given text while preserving its meaning.
    Follow the requested style exactly.
    Respond with rewritten text only (no markdown, no explanation).
    """

  static func buildSystemPrompt(profilePrompt: String?) -> String {
    guard let profilePrompt,
      !profilePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return system
    }
    return "\(system)\n\nAdditional context from the user:\n\(profilePrompt)"
  }

  static func rewriteSystemPrompt(intent: RewriteIntent) -> String {
    "\(rewrite)\n\nRewrite request: \(intent.instruction)"
  }

  static func profileMessage(context: ProfileContext) throws -> String {
    let fields: [(String, String)] = [
      ("Role", context.role),
      ("Audience", context.audience),
      ("Tone", context.tone),
      ("Formality", context.formality),
      ("Domain", context.domain),
      ("Additional notes", context.notes),
    ]
    let lines = fields.compactMap { label, value -> String? in
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      return "\(label): \(value)"
    }
    guard !lines.isEmpty else {
      throw BexError.profileContextRequired
    }
    return lines.joined(separator: "\n")
  }
}
