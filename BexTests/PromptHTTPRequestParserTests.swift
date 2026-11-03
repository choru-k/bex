import Foundation
import XCTest

@testable import Bex

/// Cloud-authored, NOT compiled/run in the cloud. Every input is synthetic and
/// exercises the production Foundation parser directly; no listener is constructed.
final class PromptHTTPRequestParserTests: XCTestCase {
  func testReviewAndAckAtEverySplitIncludingUTF8Body() {
    for path in ["/v1/review", "/v1/ack"] {
      let body = Data("{\"prompt\":\"안녕 👋\"}".utf8)
      let wire = request(path: path, body: body)
      for split in 1..<wire.count {
        var parser = PromptHTTPRequestParser(port: 4321)
        XCTAssertEqual(parser.append(wire.prefix(split)), .incomplete)
        XCTAssertEqual(parser.append(wire.dropFirst(split)), .complete(.init(path: path, body: body)))
        XCTAssertEqual(parser.retainedBytes, 0)
      }
    }
  }

  func testBadFramingCannotCreateNegativeRangeOrWaitForMoreData() {
    for length in ["-1", "+1", "1, 1", "1 0", "", "1x", "1.0"] {
      var parser = PromptHTTPRequestParser(port: 4321)
      XCTAssertEqual(parser.append(headers("Content-Length: \(length)\r\n")), .rejected(.malformed))
      XCTAssertEqual(parser.retainedBytes, 0)
    }
    for length in ["1048577", "18446744073709551616", String(repeating: "9", count: 500)] {
      var parser = PromptHTTPRequestParser(port: 4321)
      XCTAssertEqual(parser.append(headers("Content-Length: \(length)\r\n")), .rejected(.tooLarge))
    }
    for fields in [
      "", "Content-Length: 0\r\nContent-Length: 0\r\n",
      "Content-Length: 0\r\ncontent-length: 1\r\n",
      "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
      "Transfer-Encoding: identity\r\n", "Content-Length : 0\r\n",
      " Content-Length: 0\r\n", "Content-Length: 0\r\n Folded\r\n",
      "Content-Length: 0\r\nX: a\u{0}b\r\n",
      "Content-Length: 0\r\nExpect: 100-continue\r\n",
      "Content-Length: 0\r\nOrigin: http://example.test\r\n"
    ] {
      var parser = PromptHTTPRequestParser(port: 4321)
      XCTAssertEqual(parser.append(headers(fields)), .rejected(.malformed))
      XCTAssertEqual(parser.retainedBytes, 0)
    }
  }

  func testRequestLineAuthorityAndHeaderControlValidation() {
    let invalid = [
      "GET /v1/review HTTP/1.1", "POST  /v1/review HTTP/1.1",
      "POST /v1/review HTTP/2", "POST /v1/review HTTP/1.1 extra",
      "POST http://127.0.0.1:4321/v1/review HTTP/1.1",
      "POST //other.test/v1/review HTTP/1.1", "POST /v1/review#x HTTP/1.1",
      "POST /v1/review\\x HTTP/1.1"
    ]
    for line in invalid {
      var parser = PromptHTTPRequestParser(port: 4321)
      XCTAssertEqual(parser.append(Data("\(line)\r\nHost: 127.0.0.1:4321\r\nContent-Length: 0\r\n\r\n".utf8)),
        .rejected(.malformed))
    }
    for host in ["", "other.test:4321", "127.0.0.1:9999", "127.0.0.1:4321\r\nHost: 127.0.0.1:4321"] {
      var parser = PromptHTTPRequestParser(port: 4321)
      XCTAssertEqual(parser.append(Data("POST /v1/ack HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 0\r\n\r\n".utf8)),
        .rejected(.malformed))
    }
    for host in ["127.0.0.1:4321", "localhost:4321", "[::1]:4321"] {
      var parser = PromptHTTPRequestParser(port: 4321)
      XCTAssertEqual(parser.append(Data("POST /v1/ack HTTP/1.1\r\nHost: \(host)\r\nContent-Length: 0\r\n\r\n".utf8)),
        .complete(.init(path: "/v1/ack", body: Data())))
    }
    var oldHTTP = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(oldHTTP.append(Data("POST /v1/ack HTTP/1.0\r\nContent-Length: 0\r\n\r\n".utf8)),
      .complete(.init(path: "/v1/ack", body: Data())))
  }

  func testExactHeaderBodyCapsAndOverdeliveryReleaseRetainedBytes() {
    let base = "POST /v1/review HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nContent-Length: 0\r\nX: "
    let exact = Data((base + String(repeating: "a", count: 16_384 - base.utf8.count - 4) + "\r\n\r\n").utf8)
    var parser = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(parser.append(exact), .complete(.init(path: "/v1/review", body: Data())))
    var tooLong = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(tooLong.append(Data(repeating: 65, count: 16_384)), .rejected(.tooLarge))
    var overdelivery = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(overdelivery.append(Data(repeating: 65, count: 16_385)), .rejected(.tooLarge))
    XCTAssertEqual(overdelivery.retainedBytes, 0)
    let body = Data(repeating: 120, count: HookProtocolConstants.maximumMessageBytes)
    var maxBody = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(feed(request(body: body), into: &maxBody), .complete(.init(path: "/v1/review", body: body)))
    XCTAssertEqual(maxBody.retainedBytes, 0)
  }

  func testEOFErrorTrailingBytesAndTerminalParserNeverDispatchTwice() {
    var partial = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(partial.append(headers("Content-Length: 2\r\n") + Data("x".utf8), isComplete: true),
      .rejected(.malformed))
    var failed = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(failed.append(request(), failed: true), .rejected(.malformed))
    var extra = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(extra.append(request() + request()), .rejected(.malformed))
    var complete = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(complete.append(request()), .complete(.init(path: "/v1/review", body: Data())))
    XCTAssertEqual(complete.append(request()), .rejected(.malformed))
    var cleared = PromptHTTPRequestParser(port: 4321)
    XCTAssertEqual(cleared.append(Data("POST /v1".utf8)), .incomplete)
    cleared.discard()
    XCTAssertEqual(cleared.retainedBytes, 0)
    XCTAssertEqual(cleared.append(request()), .rejected(.malformed))
  }

  func testAuthenticationNeverAcceptsMissingOrWrongCredential() {
    let expected = String(repeating: "a", count: 64)
    XCTAssertTrue(PromptGateAuthentication.matches(expected, expected: expected))
    for supplied in ["", "a", String(repeating: "a", count: 65),
      "b" + String(repeating: "a", count: 63), String(repeating: "a", count: 63) + "b"] {
      XCTAssertFalse(PromptGateAuthentication.matches(supplied, expected: expected))
    }
    XCTAssertFalse(PromptGateAuthentication.matches("", expected: ""))
  }

  private func headers(_ fields: String) -> Data {
    Data("POST /v1/review HTTP/1.1\r\nHost: 127.0.0.1:4321\r\n\(fields)\r\n".utf8)
  }
  private func request(path: String = "/v1/review", body: Data = Data()) -> Data {
    Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:4321\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
  }
  private func feed(_ data: Data, into parser: inout PromptHTTPRequestParser) -> PromptHTTPRequestParser.Progress {
    var result = PromptHTTPRequestParser.Progress.incomplete
    for offset in stride(from: 0, to: data.count, by: 1_024) {
      result = parser.append(data.subdata(in: offset..<min(offset + 1_024, data.count)))
      XCTAssertLessThanOrEqual(parser.retainedBytes, HookProtocolConstants.maximumMessageBytes + 16_384)
      if result != .incomplete { break }
    }
    return result
  }
}
