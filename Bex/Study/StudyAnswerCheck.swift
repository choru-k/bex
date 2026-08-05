import Foundation

/// Pure grading for typed-answer drill cards (see `StudyAnswerMode.typed`). No `Date()`,
/// no I/O — just string comparison, so it's trivially unit-testable and safe to call
/// from both the view model and its tests with identical results.
enum StudyAnswerCheck {
  /// Leading/trailing characters stripped by `normalize`, straight and curly quote/
  /// punctuation forms alike. Internal punctuation is deliberately left untouched —
  /// see the doc comment on `matches` for why that distinction matters.
  private static let trimmablePunctuation = CharacterSet(charactersIn: ".?!,;:\"'“”‘’")

  /// Canonicalizes `text` for comparison, in this exact order:
  /// 1. trim leading/trailing whitespace;
  /// 2. collapse every internal run of whitespace to a single space;
  /// 3. lowercase;
  /// 4. strip leading and trailing punctuation (straight and curly quotes included).
  ///
  /// Order matters: whitespace has to collapse (step 2) before punctuation stripping
  /// (step 4) so a trailing `" ."` still ends up stripped, and stripping happens last so
  /// it operates on the already-collapsed, already-lowercased string rather than
  /// re-exposing whitespace at the edges.
  static func normalize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let lowered = collapsed.lowercased()
    var scalars = Substring(lowered)
    while let first = scalars.unicodeScalars.first, trimmablePunctuation.contains(first) {
      scalars = scalars.dropFirst()
    }
    while let last = scalars.unicodeScalars.last, trimmablePunctuation.contains(last) {
      scalars = scalars.dropLast()
    }
    return String(scalars)
  }

  /// Whether `typed` counts as the same answer as `correct` after normalizing both
  /// sides. Only leading/trailing whitespace and punctuation are forgiven — internal
  /// punctuation and internal whitespace are NOT touched. A real card in the owner's
  /// deck is `"loop 1-2 , 3 times"` → `"loop 1-2, 3 times"`: the entire correction is
  /// removing the space before the comma. If this collapsed internal whitespace or
  /// stripped internal punctuation, that card would become ungradeable — a wrong answer
  /// would compare equal to the correct one.
  static func matches(typed: String, correct: String) -> Bool {
    normalize(typed) == normalize(correct)
  }
}
