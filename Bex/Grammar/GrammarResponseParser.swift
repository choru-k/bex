import Foundation

enum GrammarResponseParser {
  static func parse(_ raw: String) throws -> GrammarResult {
    guard let dictionary = jsonObject(in: raw),
      let corrected = dictionary["corrected"] as? String
    else {
      throw BexError.invalidResponse
    }
    let explanation = dictionary["explanation"] as? String
    return GrammarResult(
      corrected: corrected,
      explanation: explanation?.isEmpty == false
        ? explanation!
        : "No explanation provided."
    )
  }

  /// The first JSON object in a model response, tolerating the ways models wrap one:
  /// bare, inside ```json fences, or surrounded by prose. Shared by every JSON-shaped
  /// prompt in the app (`parse` above, `DictionaryLookup.parse`) so the unwrapping
  /// rules can't drift between them.
  static func jsonObject(in raw: String) -> [String: Any]? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let object = decode(trimmed) {
      return object
    }

    let stripped =
      trimmed
      .replacingOccurrences(
        of: #"(?i)^```json\s*"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"(?i)^```\s*"#,
        with: "",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"\s*```$"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if let object = decode(stripped) {
      return object
    }

    if let start = stripped.firstIndex(of: "{"),
      let end = stripped.lastIndex(of: "}"),
      start < end,
      let object = decode(String(stripped[start...end]))
    {
      return object
    }

    if let balanced = firstBalancedJSONObject(in: stripped) {
      return decode(balanced)
    }
    return nil
  }

  private static func decode(_ source: String) -> [String: Any]? {
    guard
      let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
    else {
      return nil
    }
    return object as? [String: Any]
  }

  private static func firstBalancedJSONObject(in input: String) -> String? {
    guard let start = input.firstIndex(of: "{") else { return nil }

    var depth = 0
    var inString = false
    var escaped = false
    var index = start

    while index < input.endIndex {
      let character = input[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else if character == "\"" {
        inString = true
      } else if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          return String(input[start...index])
        }
      }
      index = input.index(after: index)
    }
    return nil
  }
}
