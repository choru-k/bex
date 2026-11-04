import XCTest
import Darwin
@testable import Bex

/// Authored synthetic filesystem cases, NOT compiled/run in cloud. They exercise
/// the exact validator but never construct a host/WebKit or touch the main bundle.
/// These are application-hosted tests; a future authorized run may launch Bex.
final class NativePackagedResourceValidatorTests: XCTestCase {
  private let script = "native-A_0-azAZ.js"
  private let style = "native-a_0-Azaz.css"
  private let scriptBytes = "export const fixture = true;\n"
  private let styleBytes = "body { color: black; }\n"

  private struct Fixture {
    let parent: URL
    let root: URL
    let web: URL
    let assets: URL
    let manifest: URL
    let html: URL
    let js: URL
    let css: URL
  }

  private func fixture(maximumNames: Bool = false) throws -> Fixture {
    let script = maximumNames ? "native-" + String(repeating: "a", count: 64) + ".js" : self.script
    let style = maximumNames ? "native-" + String(repeating: "Z", count: 64) + ".css" : self.style
    let manager = FileManager.default
    let parent = manager.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("bex-resource-admission-" + UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent("Resources", isDirectory: true)
    let web = root.appendingPathComponent("BexWebUI", isDirectory: true)
    let assets = web.appendingPathComponent("assets", isDirectory: true)
    try manager.createDirectory(at: assets, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try manager.removeItem(at: parent) }
    let f = Fixture(parent: parent, root: root, web: web, assets: assets,
      manifest: root.appendingPathComponent("native-resource-manifest.json"),
      html: web.appendingPathComponent("native.html"),
      js: assets.appendingPathComponent(script), css: assets.appendingPathComponent(style))
    try write(maximumNames ? Self.maximumHTML : Self.fixtureHTML, to: f.html)
    try write(maximumNames ? Self.maximumManifest : Self.fixtureManifest, to: f.manifest)
    try write(scriptBytes, to: f.js)
    try write(styleBytes, to: f.css)
    return f
  }

  private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func admit(_ f: Fixture) throws {
    try NativePackagedResourceValidator.validateFixture(resourceRootPath: f.root.path)
  }

  func testGoldenOfflinePackageAndBothBoundedAssetOrders() throws {
    let f = try fixture()
    XCTAssertNoThrow(try admit(f))
    try write(Self.reversedManifest, to: f.manifest)
    XCTAssertNoThrow(try admit(f))
  }

  func testMaximum64CharacterAssetNamesAnd75ByteCSSNameAdmit() throws {
    let f = try fixture(maximumNames: true)
    XCTAssertEqual(f.js.lastPathComponent.utf8.count, 74)
    XCTAssertEqual(f.css.lastPathComponent.utf8.count, 75)
    XCTAssertNoThrow(try admit(f))
  }

  func testOrdinaryAppResourcesAndReadOnlyModesDoNotExpandWebInventory() throws {
    let f = try fixture()
    try write("Unrelated app resource", to: f.root.appendingPathComponent("Info.txt"))
    for directory in [f.root, f.web, f.assets] {
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    for file in [f.manifest, f.html, f.js, f.css] {
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    }
    XCTAssertNoThrow(try admit(f))
  }

  func testMissingEveryRequiredFileOrDirectoryFails() throws {
    for select in ([{ $0.manifest }, { $0.html }, { $0.js }, { $0.css }, { $0.assets }, { $0.web }] as [(Fixture) -> URL]) {
      let f = try fixture()
      try FileManager.default.removeItem(at: select(f))
      XCTAssertThrowsError(try admit(f))
    }
  }

  func testExtraFilesDirectoriesAndAdditionalAssetFail() throws {
    for name in ["extra.txt", ".DS_Store", "assets/native-aaaaaaaa.js", "assets/native-aaaaaaaa.css", "assets/native-aaaaaaaa.js.map"] {
      let f = try fixture()
      try write("extra", to: f.web.appendingPathComponent(name))
      XCTAssertThrowsError(try admit(f), name)
    }
    for name in ["extra", "assets/extra"] {
      let f = try fixture()
      try FileManager.default.createDirectory(at: f.web.appendingPathComponent(name),
        withIntermediateDirectories: false)
      XCTAssertThrowsError(try admit(f), name)
    }
  }

  func testSymlinkAtRootAncestorDirectoriesOrFilesFails() throws {
    for select in ([{ $0.root }, { $0.web }, { $0.assets }, { $0.manifest }, { $0.html }, { $0.js }, { $0.css }] as [(Fixture) -> URL]) {
      let f = try fixture()
      let original = select(f), moved = f.parent.appendingPathComponent("moved")
      try FileManager.default.moveItem(at: original, to: moved)
      try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
      XCTAssertThrowsError(try admit(f))
    }
    let f = try fixture(), alias = f.parent.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.parent)
    XCTAssertThrowsError(try NativePackagedResourceValidator.validateFixture(
      resourceRootPath: alias.appendingPathComponent("Resources").path))
  }

  func testCaseAliasedResourceOrManifestNamesFail() throws {
    for select in ([{ $0.web }, { $0.manifest }] as [(Fixture) -> URL]) {
      let f = try fixture(), original = select(f)
      // Rename through a distinct name so this tests both case-sensitive and
      // case-insensitive filesystems without relying on rename case-only behavior.
      let temporary = f.root.appendingPathComponent("temporary-name")
      let uppercase = original.deletingLastPathComponent()
        .appendingPathComponent(original.lastPathComponent.uppercased())
      try FileManager.default.moveItem(at: original, to: temporary)
      try FileManager.default.moveItem(at: temporary, to: uppercase)
      XCTAssertThrowsError(try admit(f))
    }
  }

  func testHardLinkedManifestOrAssetFails() throws {
    for select in ([{ $0.manifest }, { $0.html }, { $0.js }, { $0.css }] as [(Fixture) -> URL]) {
      let f = try fixture()
      try FileManager.default.linkItem(at: select(f), to: f.parent.appendingPathComponent("hardlink"))
      XCTAssertThrowsError(try admit(f))
    }
  }

  func testFIFOsAndDirectoriesInFilePositionsFailWithoutStreamReads() throws {
    for select in ([{ $0.manifest }, { $0.html }, { $0.js }, { $0.css }] as [(Fixture) -> URL]) {
      let f = try fixture(), file = select(f)
      try FileManager.default.removeItem(at: file)
      XCTAssertEqual(mkfifo(file.path, 0o600), 0)
      XCTAssertThrowsError(try admit(f))
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
      XCTAssertThrowsError(try admit(f))
    }
  }

  func testUnsafeFileAndDirectoryModesFail() throws {
    for mode in [0o755, 0o664, 0o646, 0o4644, 0o2644, 0o1644] {
      let f = try fixture()
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.js.path)
      XCTAssertThrowsError(try admit(f), String(mode, radix: 8))
    }
    for mode in [0o777, 0o770, 0o1700] {
      for select in ([{ $0.root }, { $0.web }, { $0.assets }] as [(Fixture) -> URL]) {
        let f = try fixture()
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: select(f).path)
        XCTAssertThrowsError(try admit(f), String(mode, radix: 8))
      }
    }
  }

  func testOversizedSparseResourceAndManifestFail() throws {
    let cases: [((Fixture) -> URL, Int)] = [
      ({ $0.js }, 16 * 1024 * 1024 + 1), ({ $0.css }, 16 * 1024 * 1024 + 1),
      ({ $0.manifest }, 64 * 1024 + 1)
    ]
    for (select, count) in cases {
      let f = try fixture()
      let handle = try FileHandle(forWritingTo: select(f))
      try handle.truncate(atOffset: UInt64(count))
      try handle.close()
      XCTAssertThrowsError(try admit(f))
    }
  }

  func testInvalidFilenameSuffixLengthsAndCharactersFail() throws {
    for name in ["native-1234567.js", "native-" + String(repeating: "a", count: 65) + ".js",
                 "native-abcdefg%.js", "native-abcdefgé.js", "native-abcdefgh.JS", "other-abcdefgh.js"] {
      let f = try fixture()
      try FileManager.default.moveItem(at: f.js, to: f.assets.appendingPathComponent(name))
      XCTAssertThrowsError(try admit(f), name)
    }
  }

  func testAbsolutePathAliasesAreRejectedBeforeNormalization() throws {
    let f = try fixture()
    for path in ["relative", f.root.path + "/", f.parent.path + "/./Resources",
                 f.parent.path + "//Resources", f.root.path + "/../Resources",
                 f.root.path + "\\alias", f.root.path + "\0alias", f.root.path + ".", f.root.path + " "] {
      XCTAssertThrowsError(try NativePackagedResourceValidator.validateFixture(resourceRootPath: path))
    }
  }

  func testExactHTMLAndCSPFailOnAnyMutation() throws {
    let changes: [(String, String)] = [
      ("default-src 'none'", "default-src *"), ("script-src 'self'", "script-src 'self' 'unsafe-eval'"),
      ("./assets/", "https://example.invalid/"), ("<body>", "<body onload=\"bad()\">"),
      ("</body>", "<script>bad()</script></body>"), ("<head>", "<head><base href=\"/\">"),
      ("<div id=\"root\">", "<div style=\"color:red\" id=\"root\">")
    ]
    for (before, after) in changes {
      let f = try fixture()
      try write(Self.fixtureHTML.replacingOccurrences(of: before, with: after), to: f.html)
      XCTAssertThrowsError(try admit(f), before)
    }
    let f = try fixture()
    try write(Self.fixtureHTML + "\n", to: f.html)
    XCTAssertThrowsError(try admit(f))
  }

  func testContentHashChangesFailEvenAtSameByteCount() throws {
    let f = try fixture()
    try write(scriptBytes.replacingOccurrences(of: "true", with: "null"), to: f.js)
    XCTAssertThrowsError(try admit(f))
    try write(scriptBytes + "x", to: f.js)
    XCTAssertThrowsError(try admit(f))
    try write(scriptBytes, to: f.js)
    try write(styleBytes.replacingOccurrences(of: "black", with: "white"), to: f.css)
    XCTAssertThrowsError(try admit(f))
    try write(styleBytes + "x", to: f.css)
    XCTAssertThrowsError(try admit(f))
  }

  func testDuplicateUnknownAndCoercedManifestSchemaOrFormattingFail() throws {
    let badManifests = [
      Self.fixtureManifest.replacingOccurrences(of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1,\n  \"schemaVersion\": 1,"),
      Self.fixtureManifest.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": true"),
      Self.fixtureManifest.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1.0"),
      Self.fixtureManifest.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"),
      Self.fixtureManifest.replacingOccurrences(
        of: "\"schemaVersion\": 1,\n  \"profile\": \"bex-native-vite-single-entry-v1\"",
        with: "\"profile\": \"bex-native-vite-single-entry-v1\",\n  \"schemaVersion\": 1"),
      Self.fixtureManifest.replacingOccurrences(of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1, \"extra\": 0,"),
      Self.fixtureManifest.replacingOccurrences(of: "\"path\": \"native.html\",", with: "\"path\": \"native.html\", \"path\": \"native.html\","),
      Self.fixtureManifest.replacingOccurrences(of: "\"bytes\": 23", with: "\"bytes\": \"23\""),
      Self.fixtureManifest.replacingOccurrences(of: "assets/", with: "assets/../assets/"),
      Self.fixtureManifest.replacingOccurrences(of: "'none'", with: "*"),
      Self.fixtureManifest.replacingOccurrences(of: "bex-native-vite-single-entry-v1", with: "unknown"),
      Self.fixtureManifest.replacingOccurrences(of: "\n", with: "\r\n"),
      String(Self.fixtureManifest.dropLast()), "\u{FEFF}" + Self.fixtureManifest,
      Self.fixtureManifest + "{}\n"
    ]
    for manifest in badManifests {
      XCTAssertNotEqual(manifest, Self.fixtureManifest, "Each case must actually change the golden bytes")
      let f = try fixture()
      try write(manifest, to: f.manifest)
      XCTAssertThrowsError(try admit(f))
    }
  }

  // Node tests independently regenerate these literals with the unchanged auditor.
  private static let fixtureHTML = #"""
  <!doctype html>
  <html lang="ko">
    <head>
      <meta charset="UTF-8" />
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <meta name="color-scheme" content="light dark" />
      <title>Bex · Native Preview</title>
      <script type="module" crossorigin src="./assets/native-A_0-azAZ.js"></script>
      <link rel="stylesheet" crossorigin href="./assets/native-a_0-Azaz.css">
    </head>
    <body>
      <div id="root"></div>
    </body>
  </html>
  """# + "\n"

  private static let fixtureManifest = #"""
  {
    "schemaVersion": 1,
    "profile": "bex-native-vite-single-entry-v1",
    "csp": "default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'",
    "inventory": [
      {
        "path": "assets/native-a_0-Azaz.css",
        "bytes": 23,
        "sha256": "494f4abfd7ce18ad9e8dd56cf78eb438cb5806119c8d52e2da7bc00d8b456562"
      },
      {
        "path": "assets/native-A_0-azAZ.js",
        "bytes": 29,
        "sha256": "ddf066ee341c060cca67ed6faa462602690b490d98c6fecdf607c447754e14bb"
      },
      {
        "path": "native.html",
        "bytes": 809,
        "sha256": "18dd0260d319c4b88a1958cbfa881010b51ff28cd3287af594ec75ef272d61f6"
      }
    ],
    "inventorySha256": "000fedbee38a2e137b76266689d5a4301be37fda579eaf632f33e1a144684358",
    "limitations": "Static resource inventory and HTML/CSP configuration only. Does not prove JavaScript/CSS semantics, provenance, WebKit enforcement, or network isolation. No runtime, signing, installation or activation performed."
  }
  """# + "\n"

  private static let reversedManifest = #"""
  {
    "schemaVersion": 1,
    "profile": "bex-native-vite-single-entry-v1",
    "csp": "default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'",
    "inventory": [
      {
        "path": "assets/native-A_0-azAZ.js",
        "bytes": 29,
        "sha256": "ddf066ee341c060cca67ed6faa462602690b490d98c6fecdf607c447754e14bb"
      },
      {
        "path": "assets/native-a_0-Azaz.css",
        "bytes": 23,
        "sha256": "494f4abfd7ce18ad9e8dd56cf78eb438cb5806119c8d52e2da7bc00d8b456562"
      },
      {
        "path": "native.html",
        "bytes": 809,
        "sha256": "18dd0260d319c4b88a1958cbfa881010b51ff28cd3287af594ec75ef272d61f6"
      }
    ],
    "inventorySha256": "c4bd3385b07497ce51a64d90e2357862d4784715ca0347a89d67314f90f79b53",
    "limitations": "Static resource inventory and HTML/CSP configuration only. Does not prove JavaScript/CSS semantics, provenance, WebKit enforcement, or network isolation. No runtime, signing, installation or activation performed."
  }
  """# + "\n"

  private static let maximumHTML = #"""
  <!doctype html>
  <html lang="ko">
    <head>
      <meta charset="UTF-8" />
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'" />
      <meta name="viewport" content="width=device-width, initial-scale=1.0" />
      <meta name="color-scheme" content="light dark" />
      <title>Bex · Native Preview</title>
      <script type="module" crossorigin src="./assets/native-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.js"></script>
      <link rel="stylesheet" crossorigin href="./assets/native-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ.css">
    </head>
    <body>
      <div id="root"></div>
    </body>
  </html>
  """# + "\n"

  private static let maximumManifest = #"""
  {
    "schemaVersion": 1,
    "profile": "bex-native-vite-single-entry-v1",
    "csp": "default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'",
    "inventory": [
      {
        "path": "assets/native-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.js",
        "bytes": 29,
        "sha256": "ddf066ee341c060cca67ed6faa462602690b490d98c6fecdf607c447754e14bb"
      },
      {
        "path": "assets/native-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ.css",
        "bytes": 23,
        "sha256": "494f4abfd7ce18ad9e8dd56cf78eb438cb5806119c8d52e2da7bc00d8b456562"
      },
      {
        "path": "native.html",
        "bytes": 921,
        "sha256": "eba08f408390ea40d9c571da02789dc52e8bc98b40b07127402cd11f913e704a"
      }
    ],
    "inventorySha256": "882e63108e1188417b3047a214c46e9fba8e1f361b41234a0d2c77c96b4b55ce",
    "limitations": "Static resource inventory and HTML/CSP configuration only. Does not prove JavaScript/CSS semantics, provenance, WebKit enforcement, or network isolation. No runtime, signing, installation or activation performed."
  }
  """# + "\n"

}
