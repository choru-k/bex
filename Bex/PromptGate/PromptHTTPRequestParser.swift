import Foundation

/// Fixed-length, single-request HTTP used only by the local Prompt Gate helper.
/// Pure Foundation so hostile framing can be checked without opening a socket.
struct PromptHTTPRequestParser {
  static let maximumHeaderBytes = 16_384
  static let maximumReceiveBytes = 16_384

  struct Request: Equatable, Sendable {
    let path: String
    let body: Data
  }
  enum Failure: Error, Equatable { case malformed, tooLarge }
  enum Progress: Equatable {
    case incomplete
    case complete(Request)
    case rejected(Failure)
  }

  private let maximumBodyBytes: Int
  private let port: UInt16
  private var header = Data()
  private var body = Data()
  private var delimiterMatch = 0
  private var path: String?
  private var contentLength: Int?
  private var terminal = false
  var retainedBytes: Int { header.count + body.count }

  init(maximumBodyBytes: Int = HookProtocolConstants.maximumMessageBytes, port: UInt16) {
    self.maximumBodyBytes = max(0, maximumBodyBytes)
    self.port = port
  }

  mutating func append(_ data: Data, isComplete: Bool = false, failed: Bool = false) -> Progress {
    guard !terminal else { return .rejected(.malformed) }
    // A transport error wins over apparently complete bytes in the same callback.
    guard !failed else { return reject(.malformed) }
    guard data.count <= Self.maximumReceiveBytes else { return reject(.tooLarge) }
    for byte in data {
      if let length = contentLength {
        // No pipelining or bytes outside the one declared body are accepted.
        guard body.count < length else { return reject(.malformed) }
        body.append(byte)
      } else {
        guard header.count < Self.maximumHeaderBytes else { return reject(.tooLarge) }
        header.append(byte)
        switch (delimiterMatch, byte) {
        case (0, 13), (1, 13), (3, 13): delimiterMatch = 1
        case (1, 10): delimiterMatch = 2
        case (2, 13): delimiterMatch = 3
        case (3, 10):
          if let failure = parseHeader() { return reject(failure) }
          header = Data()
        default: delimiterMatch = 0
        }
        if contentLength == nil, header.count == Self.maximumHeaderBytes {
          return reject(.tooLarge)
        }
      }
    }
    if let length = contentLength, body.count == length, let path {
      terminal = true
      let request = Request(path: path, body: body)
      body = Data()
      return .complete(request)
    }
    if isComplete || data.isEmpty { return reject(.malformed) }
    return .incomplete
  }

  mutating func discard() {
    terminal = true
    header = Data()
    body = Data()
  }

  private mutating func reject(_ failure: Failure) -> Progress {
    discard()
    return .rejected(failure)
  }

  private mutating func parseHeader() -> Failure? {
    guard let text = String(data: header, encoding: .utf8) else { return .malformed }
    let lines = text.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "POST",
      parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
    else { return .malformed }
    let target = String(parts[1])
    guard target.hasPrefix("/"), !target.hasPrefix("//"),
      target.utf8.allSatisfy({ (33...126).contains($0) && $0 != 35 && $0 != 92 })
    else { return .malformed }

    var host: String?
    var length: Int?
    let token = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    for line in lines.dropFirst().dropLast(2) {
      guard let colon = line.firstIndex(of: ":") else { return .malformed }
      let name = line[..<colon]
      guard !name.isEmpty, name.utf8.allSatisfy({ token.contains($0) }) else { return .malformed }
      let rawValue = line[line.index(after: colon)...]
      guard rawValue.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return .malformed }
      let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
      switch name.lowercased() {
      case "content-length":
        guard length == nil, !value.isEmpty,
          value.utf8.allSatisfy({ (48...57).contains($0) })
        else { return .malformed }
        // Accumulate only inside the body limit, avoiding signed parsing and overflow.
        var parsed = 0
        for digit in value.utf8 {
          let digitValue = Int(digit - 48)
          guard digitValue <= maximumBodyBytes,
            parsed <= (maximumBodyBytes - digitValue) / 10
          else { return .tooLarge }
          parsed = parsed * 10 + digitValue
        }
        length = parsed
      case "host":
        guard host == nil else { return .malformed }
        host = value.lowercased()
      case "transfer-encoding", "expect", "origin":
        // No alternate framing, 100-continue negotiation, or browser-origin traffic.
        return .malformed
      default: break
      }
    }
    guard let length else { return .malformed }
    if parts[2] == "HTTP/1.1" || host != nil {
      guard let host, ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host)
      else { return .malformed }
    }
    path = target
    contentLength = length
    return nil
  }
}

/// JSON body credentials remain the v1 protocol's authentication boundary. Reject
/// an absent server credential, then compare the fixed-size bytes without early exit.
enum PromptGateAuthentication {
  static func matches(_ supplied: String, expected: String) -> Bool {
    let expectedBytes = Array(expected.utf8)
    guard expectedBytes.count == 64, supplied.utf8.count == expectedBytes.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(supplied.utf8, expectedBytes) { difference |= left ^ right }
    return difference == 0
  }
}
