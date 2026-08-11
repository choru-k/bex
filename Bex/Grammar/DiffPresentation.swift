import AppKit
import SwiftUI

struct DiffText: View {
  let segments: [DiffSegment]
  let changesOnly: Bool

  var body: some View {
    if visibleSegments.isEmpty {
      Text("No differences")
        .foregroundStyle(.secondary)
    } else {
      Text(attributedText)
    }
  }

  private var visibleSegments: [DiffSegment] {
    changesOnly ? segments.filter { $0.kind != .unchanged } : segments
  }

  private var attributedText: AttributedString {
    var result = AttributedString()
    for segment in visibleSegments {
      var part = AttributedString(segment.text)
      switch segment.kind {
      case .unchanged:
        break
      case .inserted:
        part.foregroundColor = .green
        part.backgroundColor = Color.green.opacity(0.14)
        part.inlinePresentationIntent = .stronglyEmphasized
      case .removed:
        part.foregroundColor = .red
        part.backgroundColor = Color.red.opacity(0.12)
        part.strikethroughStyle = .single
      }
      result.append(part)
    }
    return result
  }
}

struct DiffChange: Equatable, Sendable {
  let oldText: String
  let newText: String

  static func make(from segments: [DiffSegment]) -> [DiffChange] {
    var changes: [DiffChange] = []
    var oldText = ""
    var newText = ""

    func flush() {
      guard !oldText.isEmpty || !newText.isEmpty else { return }
      changes.append(DiffChange(oldText: oldText, newText: newText))
      oldText.removeAll(keepingCapacity: true)
      newText.removeAll(keepingCapacity: true)
    }

    for segment in segments {
      switch segment.kind {
      case .unchanged:
        flush()
      case .removed:
        oldText.append(segment.text)
      case .inserted:
        newText.append(segment.text)
      }
    }
    flush()
    return changes
  }
}

/// Every change on one wrapping line: `i I · has have · teh the`, struck-through old
/// beside bold new, then a count and the rules involved.
///
/// This replaces a stacked Before/After panel that gave each edit its own labelled pair of
/// cells. That layout was fine at one change and a wall at three, and it was competing for
/// attention with the expression alternatives — which are the part of the sheet that
/// actually asks for a decision. A typo fix does not need a heading; it needs to be
/// glanceable enough to confirm and move past.
///
/// An `AttributedString` because macOS 13 has no wrapping stack, and this has to wrap
/// rather than clip or scroll sideways.
struct DiffRedline: View {
  let changes: [DiffChange]
  /// The grammar rules involved, e.g. "Subject–verb agreement, Spelling". May be empty.
  var categorySummary: String = ""

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(redline)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      Text(summary)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var summary: String {
    let count = "\(changes.count) change\(changes.count == 1 ? "" : "s")"
    return categorySummary.isEmpty ? count : "\(count) · \(categorySummary)"
  }

  private var redline: AttributedString {
    var result = AttributedString()
    for (index, change) in changes.enumerated() {
      if index > 0 {
        var separator = AttributedString(" · ")
        separator.foregroundColor = .secondary
        result += separator
      }
      var old = AttributedString(displayText(for: change.oldText))
      old.foregroundColor = .red
      old.strikethroughStyle = .single
      result += old
      result += AttributedString(" ")
      var new = AttributedString(displayText(for: change.newText))
      new.foregroundColor = .green
      new.inlinePresentationIntent = .stronglyEmphasized
      result += new
    }
    return result
  }

  /// Whitespace-only edits have no visible text to show, so they borrow the same prose
  /// description VoiceOver gets ("a space", "a line break") rather than rendering as a gap.
  private func displayText(for text: String) -> String {
    if text.isEmpty { return "nothing" }
    return text.allSatisfy(\.isWhitespace)
      ? AccessibleDiffSummary.describeChange(text)
      : text
  }
}

struct DiffSummaryAccessibilityElement: NSViewRepresentable {
  let changeCount: Int
  let summary: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    configure(view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    configure(view)
  }

  private func configure(_ view: NSView) {
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.group)
    view.setAccessibilityLabel("\(changeCount) changes")
    view.setAccessibilityValue(summary)
    view.setAccessibilityIdentifier("prompt-gate-diff-summary")
  }
}


struct AccessibleDiffSummary: Sendable {
  private static let contextCharacterLimit = 24

  static func make(from segments: [DiffSegment]) -> String {
    let changedIndices = segments.indices.filter { segments[$0].kind != .unchanged }
    guard !changedIndices.isEmpty else { return "No differences" }

    return changedIndices.map { index in
      let action = segments[index].kind == .removed ? "Removed" : "Inserted"
      let change = describeChange(segments[index].text)
      let before = context(before: index, in: segments)
      let after = context(after: index, in: segments)

      switch (before, after) {
      case let (.some(before), .some(after)):
        return "\(action) \(change) between “\(before)” and “\(after)”"
      case let (.some(before), .none):
        return "\(action) \(change) after “\(before)”"
      case let (.none, .some(after)):
        return "\(action) \(change) before “\(after)”"
      case (.none, .none):
        return "\(action) \(change)"
      }
    }
    .joined(separator: "; ")
  }

  private static func context(
    before index: Int,
    in segments: [DiffSegment]
  ) -> String? {
    guard index > segments.startIndex else { return nil }

    for candidate in segments[..<index].indices.reversed()
    where segments[candidate].kind == .unchanged {
      let normalized = normalizeContext(segments[candidate].text)
      guard !normalized.isEmpty else { continue }
      if normalized.count <= contextCharacterLimit {
        return normalized
      }
      return "…" + normalized.suffix(contextCharacterLimit)
    }
    return nil
  }

  private static func context(
    after index: Int,
    in segments: [DiffSegment]
  ) -> String? {
    let nextIndex = segments.index(after: index)
    guard nextIndex < segments.endIndex else { return nil }

    for candidate in segments[nextIndex...].indices
    where segments[candidate].kind == .unchanged {
      let normalized = normalizeContext(segments[candidate].text)
      guard !normalized.isEmpty else { continue }
      if normalized.count <= contextCharacterLimit {
        return normalized
      }
      return normalized.prefix(contextCharacterLimit) + "…"
    }
    return nil
  }

  private static func normalizeContext(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  static func describeChange(_ text: String) -> String {
    var parts: [String] = []
    var textRun = ""
    var whitespaceKind: WhitespaceKind?
    var whitespaceCount = 0

    func appendTextRun() {
      guard !textRun.isEmpty else { return }
      parts.append("“\(textRun)”")
      textRun.removeAll(keepingCapacity: true)
    }

    func appendWhitespaceRun() {
      guard let whitespaceKind, whitespaceCount > 0 else { return }
      parts.append(whitespaceKind.description(count: whitespaceCount))
    }

    for character in text {
      if let kind = WhitespaceKind(character) {
        appendTextRun()
        if whitespaceKind == kind {
          whitespaceCount += 1
        } else {
          appendWhitespaceRun()
          whitespaceKind = kind
          whitespaceCount = 1
        }
      } else {
        appendWhitespaceRun()
        whitespaceKind = nil
        whitespaceCount = 0
        textRun.append(character)
      }
    }
    appendTextRun()
    appendWhitespaceRun()

    return parts.isEmpty ? "empty text" : parts.joined(separator: ", then ")
  }

  private enum WhitespaceKind: Equatable {
    case space
    case tab
    case lineBreak
    case whitespace

    init?(_ character: Character) {
      switch character {
      case " ": self = .space
      case "\t": self = .tab
      case "\n", "\r", "\r\n": self = .lineBreak
      default:
        guard character.isWhitespace else { return nil }
        self = .whitespace
      }
    }

    func description(count: Int) -> String {
      let noun = switch self {
      case .space: "space"
      case .tab: "tab"
      case .lineBreak: "line break"
      case .whitespace: "whitespace character"
      }
      return count == 1 ? "one \(noun)" : "\(count) \(noun)s"
    }
  }
}
