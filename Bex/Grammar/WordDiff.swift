import Foundation

public struct DiffSegment: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case unchanged
    case inserted
    case removed
  }

  public let text: String
  public let kind: Kind

  public init(text: String, kind: Kind) {
    self.text = text
    self.kind = kind
  }
}

enum WordDiff {
  private struct Edit {
    let token: String
    let kind: DiffSegment.Kind
  }

  static func compute(original: String, corrected: String) -> [DiffSegment] {
    let source = tokenize(original)
    let destination = tokenize(corrected)
    guard !source.isEmpty || !destination.isEmpty else { return [] }

    let edits = shortestEditScript(source: source, destination: destination)
    var segments: [DiffSegment] = []
    segments.reserveCapacity(edits.count)
    for edit in edits {
      if let last = segments.last, last.kind == edit.kind {
        segments[segments.count - 1] = DiffSegment(
          text: last.text + edit.token,
          kind: edit.kind
        )
      } else {
        segments.append(DiffSegment(text: edit.token, kind: edit.kind))
      }
    }
    return segments
  }

  private static func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var currentIsWhitespace: Bool?

    for character in text {
      let isWhitespace = character.isWhitespace
      if currentIsWhitespace == nil || currentIsWhitespace == isWhitespace {
        current.append(character)
      } else {
        tokens.append(current)
        current = String(character)
      }
      currentIsWhitespace = isWhitespace
    }
    if !current.isEmpty {
      tokens.append(current)
    }
    return tokens
  }

  private static func shortestEditScript(
    source: [String],
    destination: [String]
  ) -> [Edit] {
    let sourceCount = source.count
    let destinationCount = destination.count
    let maximum = sourceCount + destinationCount
    var frontier: [Int: Int] = [1: 0]
    var trace: [[Int: Int]] = []

    for distance in 0...maximum {
      var current: [Int: Int] = [:]
      current.reserveCapacity(distance + 1)

      for diagonal in stride(from: -distance, through: distance, by: 2) {
        let x: Int
        if diagonal == -distance
          || (diagonal != distance
            && (frontier[diagonal - 1] ?? Int.min) < (frontier[diagonal + 1] ?? Int.min))
        {
          x = frontier[diagonal + 1] ?? 0
        } else {
          x = (frontier[diagonal - 1] ?? 0) + 1
        }

        var advancedX = x
        var advancedY = x - diagonal
        while advancedX < sourceCount,
          advancedY >= 0,
          advancedY < destinationCount,
          source[advancedX] == destination[advancedY]
        {
          advancedX += 1
          advancedY += 1
        }
        current[diagonal] = advancedX

        if advancedX >= sourceCount && advancedY >= destinationCount {
          trace.append(current)
          return backtrack(
            trace: trace,
            source: source,
            destination: destination
          )
        }
      }

      trace.append(current)
      frontier = current
    }
    return []
  }

  private static func backtrack(
    trace: [[Int: Int]],
    source: [String],
    destination: [String]
  ) -> [Edit] {
    var x = source.count
    var y = destination.count
    var reversed: [Edit] = []
    reversed.reserveCapacity(source.count + destination.count)

    if trace.count > 1 {
      for distance in stride(from: trace.count - 1, through: 1, by: -1) {
        let previous = trace[distance - 1]
        let diagonal = x - y
        let previousDiagonal: Int
        if diagonal == -distance
          || (diagonal != distance
            && (previous[diagonal - 1] ?? Int.min) < (previous[diagonal + 1] ?? Int.min))
        {
          previousDiagonal = diagonal + 1
        } else {
          previousDiagonal = diagonal - 1
        }

        let previousX = previous[previousDiagonal] ?? 0
        let previousY = previousX - previousDiagonal

        while x > previousX && y > previousY {
          x -= 1
          y -= 1
          reversed.append(Edit(token: source[x], kind: .unchanged))
        }

        if x == previousX {
          y -= 1
          reversed.append(Edit(token: destination[y], kind: .inserted))
        } else {
          x -= 1
          reversed.append(Edit(token: source[x], kind: .removed))
        }
      }
    }

    while x > 0 && y > 0 {
      x -= 1
      y -= 1
      reversed.append(Edit(token: source[x], kind: .unchanged))
    }
    while x > 0 {
      x -= 1
      reversed.append(Edit(token: source[x], kind: .removed))
    }
    while y > 0 {
      y -= 1
      reversed.append(Edit(token: destination[y], kind: .inserted))
    }

    return reversed.reversed()
  }
}
