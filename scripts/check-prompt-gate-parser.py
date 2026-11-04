#!/usr/bin/env python3
"""Execute the actual Foundation parser with an available Swift toolchain, no sockets.

No compiler is downloaded/installed. Exit 77 means NOT RUN (Swift unavailable).
The cloud Node oracle is independent and is not a substitute for this runner.
"""
import pathlib
import re
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
swift = shutil.which("swift")
if swift is None:
    print("NOT RUN: swift is not installed; no production Swift parser execution claimed.")
    raise SystemExit(77)

protocol_source = (ROOT / "BexHookShared/HookProtocol.swift").read_text()
limit = re.search(r"static let maximumMessageBytes = ([0-9_]+)", protocol_source)
assert limit is not None
production_parser = (ROOT / "Bex/PromptGate/PromptHTTPRequestParser.swift").read_text()
harness = r'''
struct Fixture: Decodable { let name: String; let wire: String; let expected: String }
func resultName(_ progress: PromptHTTPRequestParser.Progress) -> String {
  switch progress {
  case .incomplete: return "incomplete"
  case .complete: return "complete"
  case .rejected(.malformed): return "malformed"
  case .rejected(.tooLarge): return "tooLarge"
  }
}
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
var splitChecks = 0
for fixture in fixtures {
  let wire = Data(base64Encoded: fixture.wire)!
  var parser = PromptHTTPRequestParser(port: 4321)
  var result = PromptHTTPRequestParser.Progress.incomplete
  for offset in stride(from: 0, to: wire.count, by: PromptHTTPRequestParser.maximumReceiveBytes) {
    let end = min(wire.count, offset + PromptHTTPRequestParser.maximumReceiveBytes)
    result = parser.append(wire.subdata(in: offset..<end))
    if result != .incomplete { break }
  }
  precondition(resultName(result) == fixture.expected, "Fixture failed: \(fixture.name)")
  if fixture.expected == "complete" {
    let splits = wire.count <= 1_024 ? Array(1..<wire.count)
      : Array(Set([1, 2, wire.count - 1] + Array(stride(from: 1_024, to: wire.count, by: 1_024)))).sorted()
    for split in splits {
      var splitParser = PromptHTTPRequestParser(port: 4321)
      precondition(splitParser.append(wire.prefix(split)) == .incomplete)
      precondition(resultName(splitParser.append(wire.dropFirst(split))) == "complete")
      precondition(splitParser.retainedBytes == 0)
      splitChecks += 1
    }
  }
}
print("Production Foundation parser: \(fixtures.count) fixture vectors; \(splitChecks) valid split checks passed.")
'''
with tempfile.TemporaryDirectory(prefix="bex-prompt-parser-") as temporary:
    source = pathlib.Path(temporary) / "main.swift"
    source.write_text("enum HookProtocolConstants { static let maximumMessageBytes = "
                      + limit.group(1) + " }\n" + production_parser + "\n" + harness)
    raise SystemExit(subprocess.call([swift, str(source),
        str(ROOT / "tests/fixtures/prompt-gate/framing.json")]))
