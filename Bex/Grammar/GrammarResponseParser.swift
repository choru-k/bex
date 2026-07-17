import Foundation

enum GrammarResponseParser {
  static func parse(_ raw: String) throws -> GrammarResult {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let result = parseObject(trimmed) {
      return result
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

    if let result = parseObject(stripped) {
      return result
    }

    if let start = stripped.firstIndex(of: "{"),
      let end = stripped.lastIndex(of: "}"),
      start < end,
      let result = parseObject(String(stripped[start...end]))
    {
      return result
    }

    if let balanced = firstBalancedJSONObject(in: stripped),
      let result = parseObject(balanced)
    {
      return result
    }

    throw BexError.invalidResponse
  }

  private static func parseObject(_ source: String) -> GrammarResult? {
    guard
      let data = source.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any],
      let corrected = dictionary["corrected"] as? String
    else {
      return nil
    }

    let explanation = dictionary["explanation"] as? String
    return GrammarResult(
      corrected: corrected,
      explanation: explanation?.isEmpty == false
        ? explanation!
        : "No explanation provided."
    )
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
