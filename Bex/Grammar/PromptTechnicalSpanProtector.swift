import Foundation

struct PromptTechnicalSpanProtector: Sendable {
  struct ProtectedText: Sendable {
    let masked: String
    let sentinels: [String]
    /// What each sentinel replaced — "path", "url", "flag" and so on, parallel to
    /// `sentinels`. Display only: the consent sheet labels each masked span so the owner
    /// can see *what* is being held back at a glance instead of reading a placeholder.
    /// Nothing about masking or restoration reads this.
    let kinds: [String]
    private let originals: [String]

    fileprivate init(
      masked: String,
      sentinels: [String],
      kinds: [String],
      originals: [String]
    ) {
      self.masked = masked
      self.sentinels = sentinels
      self.kinds = kinds
      self.originals = originals
    }

    func restore(_ corrected: String) throws -> String {
      guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw BexError.unsafePromptCorrection
      }

      var located: [(range: NSRange, ordinal: Int)] = []
      let correctedString = corrected as NSString
      for (ordinal, sentinel) in sentinels.enumerated() {
        var searchRange = NSRange(location: 0, length: correctedString.length)
        var occurrences: [NSRange] = []
        while searchRange.length > 0 {
          let range = correctedString.range(of: sentinel, options: [], range: searchRange)
          guard range.location != NSNotFound else { break }
          occurrences.append(range)
          let nextLocation = NSMaxRange(range)
          searchRange = NSRange(location: nextLocation, length: correctedString.length - nextLocation)
        }
        guard occurrences.count == 1, let range = occurrences.first else {
          throw BexError.unsafePromptCorrection
        }
        located.append((range, ordinal))
      }

      let ordered = located.sorted { $0.range.location < $1.range.location }
      guard ordered.map(\.ordinal) == Array(sentinels.indices) else {
        throw BexError.unsafePromptCorrection
      }

      let withoutExpected = NSMutableString(string: corrected)
      for item in ordered.reversed() {
        withoutExpected.deleteCharacters(in: item.range)
      }
      guard !withoutExpected.contains("BEX_PROTECTED_") else {
        throw BexError.unsafePromptCorrection
      }

      let restored = NSMutableString(string: corrected)
      for item in ordered.reversed() {
        restored.replaceCharacters(in: item.range, with: originals[item.ordinal])
      }
      return restored as String
    }
  }

  static let userFacingProtectedSpanKinds = [
    "fenced and inline code",
    "templates",
    "tags",
    "URLs",
    "file paths",
    "command-line flags",
    "variables",
    "mentions",
  ]

  private static let templatePatterns = [
    #"\$\{.*?\}"#,
    #"\{\{.*?\}\}"#,
  ]
  private static let tagPattern = #"<[^\r\n<>]+>"#
  private static let pathPattern =
    #"(?<![\p{L}\p{N}_])(?:/|\./|\.\./|~/)[^\s/<>\"'`]+(?:/[^\s/<>\"'`]+)*"#
  private static let flagPattern =
    #"(?<![\p{L}\p{N}_-])(?:--[\p{L}\p{N}][\p{L}\p{N}_-]*(?:=[^\s]+)?|-[\p{L}\p{N}](?![\p{L}\p{N}_-]))"#
  private static let variablePattern = #"(?<![\p{L}\p{N}_])\$[A-Za-z_][A-Za-z0-9_]*"#
  private static let mentionPattern = #"(?<![\p{L}\p{N}_])@[\p{L}\p{N}_][\p{L}\p{N}_.-]*"#
  private static let fenceOpener = try! NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#)

  private let identifier: String

  init(identifier: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) {
    self.identifier = identifier
  }

  func protect(_ text: String) -> ProtectedText {
    let source = text as NSString
    var claimed: [(range: NSRange, kind: String)] = []

    func overlapsClaimed(_ range: NSRange) -> Bool {
      claimed.contains { NSIntersectionRange($0.range, range).length > 0 }
    }

    // The kind travels with the range from the pattern that matched it, purely so the
    // consent sheet can label the chip. First claim wins, exactly as before.
    func claim(_ range: NSRange, _ kind: String) {
      guard range.length > 0, !overlapsClaimed(range) else { return }
      claimed.append((range, kind))
    }

    for range in fencedBlockRanges(in: source) {
      claim(range, "code")
    }
    for range in inlineCodeRanges(in: source, excluding: claimed.map(\.range)) {
      claim(range, "code")
    }
    for pattern in Self.templatePatterns {
      for range in regexRanges(pattern, in: source, options: [.dotMatchesLineSeparators]) {
        claim(range, "template")
      }
    }
    for range in regexRanges(Self.tagPattern, in: source) {
      claim(range, "tag")
    }
    if let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
    ) {
      let whole = NSRange(location: 0, length: source.length)
      for match in detector.matches(in: text, options: [], range: whole) {
        claim(match.range, "url")
      }
    }
    for range in regexRanges(Self.pathPattern, in: source) {
      claim(range, "path")
    }
    for range in regexRanges(Self.flagPattern, in: source) {
      claim(range, "flag")
    }
    for range in regexRanges(Self.variablePattern, in: source) {
      claim(range, "variable")
    }
    for range in regexRanges(Self.mentionPattern, in: source) {
      claim(range, "mention")
    }

    let ordered = claimed.sorted { lhs, rhs in
      lhs.range.location == rhs.range.location
        ? lhs.range.length < rhs.range.length
        : lhs.range.location < rhs.range.location
    }
    let sentinels = ordered.indices.map { "[[[BEX_PROTECTED_\(identifier)_\($0)]]]" }
    let originals = ordered.map { source.substring(with: $0.range) }
    let masked = NSMutableString(string: text)
    for ordinal in ordered.indices.reversed() {
      masked.replaceCharacters(in: ordered[ordinal].range, with: sentinels[ordinal])
    }
    return ProtectedText(
      masked: masked as String,
      sentinels: sentinels,
      kinds: ordered.map(\.kind),
      originals: originals
    )
  }

  private func regexRanges(
    _ pattern: String,
    in source: NSString,
    options: NSRegularExpression.Options = []
  ) -> [NSRange] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
      return []
    }
    let range = NSRange(location: 0, length: source.length)
    return expression.matches(in: source as String, options: [], range: range).map(\.range)
  }

  private func fencedBlockRanges(in source: NSString) -> [NSRange] {
    var ranges: [NSRange] = []
    var cursor = 0
    while cursor < source.length {
      let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
      let contentRange = lineContentRange(lineRange, in: source)
      let opener = Self.fenceOpener.firstMatch(
        in: source as String,
        options: [],
        range: contentRange
      )
      guard let opener else {
        cursor = NSMaxRange(lineRange)
        continue
      }
      let run = opener.range(at: 1)
      let marker = source.substring(with: NSRange(location: run.location, length: 1))
      let closePattern = "^ {0,3}" + NSRegularExpression.escapedPattern(for: marker)
        + "{" + String(run.length) + ",}[ \\t]*$"
      let closer = try! NSRegularExpression(pattern: closePattern)
      var searchCursor = NSMaxRange(lineRange)
      var end = source.length
      while searchCursor < source.length {
        let candidateLine = source.lineRange(for: NSRange(location: searchCursor, length: 0))
        let candidateContent = lineContentRange(candidateLine, in: source)
        if closer.firstMatch(
          in: source as String,
          options: [],
          range: candidateContent
        ) != nil {
          end = NSMaxRange(candidateContent)
          break
        }
        searchCursor = NSMaxRange(candidateLine)
      }
      ranges.append(NSRange(location: lineRange.location, length: end - lineRange.location))
      cursor = end
      if cursor < source.length, source.character(at: cursor) == 13 {
        cursor += 1
      }
      if cursor < source.length, source.character(at: cursor) == 10 {
        cursor += 1
      }
    }
    return ranges
  }

  private func inlineCodeRanges(in source: NSString, excluding claimed: [NSRange]) -> [NSRange] {
    var ranges: [NSRange] = []
    var cursor = 0
    while cursor < source.length {
      guard source.character(at: cursor) == 96 else {
        cursor += 1
        continue
      }
      let openerStart = cursor
      while cursor < source.length, source.character(at: cursor) == 96 {
        cursor += 1
      }
      let openerLength = cursor - openerStart
      let openerRange = NSRange(location: openerStart, length: openerLength)
      if claimed.contains(where: { NSIntersectionRange($0, openerRange).length > 0 }) {
        continue
      }

      var candidate = cursor
      var found: NSRange?
      while candidate < source.length {
        let character = source.character(at: candidate)
        if character == 10 || character == 13 { break }
        guard character == 96 else {
          candidate += 1
          continue
        }
        let closeStart = candidate
        while candidate < source.length, source.character(at: candidate) == 96 {
          candidate += 1
        }
        if candidate - closeStart == openerLength {
          found = NSRange(location: openerStart, length: candidate - openerStart)
          break
        }
      }
      if let found,
        !claimed.contains(where: { NSIntersectionRange($0, found).length > 0 })
      {
        ranges.append(found)
        cursor = NSMaxRange(found)
      }
    }
    return ranges
  }

  private func lineContentRange(_ lineRange: NSRange, in source: NSString) -> NSRange {
    var end = NSMaxRange(lineRange)
    while end > lineRange.location {
      let character = source.character(at: end - 1)
      guard character == 10 || character == 13 else { break }
      end -= 1
    }
    return NSRange(location: lineRange.location, length: end - lineRange.location)
  }
}
