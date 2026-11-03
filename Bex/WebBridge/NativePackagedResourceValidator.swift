import Foundation
import CryptoKit
import Darwin

/// Inactive host admission, not an authenticity verifier. A trusted, signed,
/// immutable application bundle is a prerequisite. WebKit reopens paths after
/// this check; hostile mutation / mount changes and that post-check race are not
/// prevented here. No JS/CSS semantics or WebKit enforcement is established.
enum NativePackagedResourceValidator {
  struct Admission {
    let resourceURL: URL
    let documentURL: URL
    fileprivate init(resourceURL: URL) {
      self.resourceURL = resourceURL
      self.documentURL = resourceURL.appendingPathComponent("native.html")
    }
  }

  enum Rejection: Error {
    case missingResources, invalidPath, unsafeDirectory, invalidInventory
    case unsafeFile, oversizedFile, readFailed, changedDuringRead, profileMismatch
  }

  static let maximumResourceBytes = 16 * 1024 * 1024
  static let maximumManifestBytes = 64 * 1024
  static let profile = "bex-native-vite-single-entry-v1"
  static let csp = "default-src 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; connect-src 'none'; img-src 'none'; font-src 'none'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
  static let limitations = "Static resource inventory and HTML/CSP configuration only. Does not prove JavaScript/CSS semantics, provenance, WebKit enforcement, or network isolation. No runtime, signing, installation or activation performed."

  /// The only production entry point. Neither a caller-selected bundle nor a URL
  /// can mint an admission for the host. Validation completes before WebKit exists.
  static func validateMainBundle() throws -> Admission {
    guard let resources = Bundle.main.resourceURL, resources.isFileURL else {
      throw Rejection.missingResources
    }
    try validateResourceRoot(resources.path)
    return Admission(resourceURL: resources.appendingPathComponent("BexWebUI", isDirectory: true))
  }

  #if DEBUG
  /// Synthetic filesystem tests only. Does not return an Admission or host URL.
  static func validateFixture(resourceRootPath: String) throws {
    try validateResourceRoot(resourceRootPath)
  }
  #endif

  private struct Entry {
    let path: String
    let bytes: Int
    let sha256: String
    var compactJSON: String {
      // All strings are constants, constrained ASCII filenames or lowercase hex.
      "{\"path\":\"\(path)\",\"bytes\":\(bytes),\"sha256\":\"\(sha256)\"}"
    }
    var prettyJSON: String {
      "    {\n      \"path\": \"\(path)\",\n      \"bytes\": \(bytes),\n      \"sha256\": \"\(sha256)\"\n    }"
    }
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private static func nativeHTML(script: String, style: String) -> Data {
    Data((#"""
    <!doctype html>
    <html lang="ko">
      <head>
        <meta charset="UTF-8" />
        <meta http-equiv="Content-Security-Policy" content="\#(csp)" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <meta name="color-scheme" content="light dark" />
        <title>Bex · Native Preview</title>
        <script type="module" crossorigin src="./assets/\#(script)"></script>
        <link rel="stylesheet" crossorigin href="./assets/\#(style)">
      </head>
      <body>
        <div id="root"></div>
      </body>
    </html>
    """# + "\n").utf8)
  }

  private static func canonicalManifest(_ entries: [Entry]) -> Data {
    let compact = "[" + entries.map(\.compactJSON).joined(separator: ",") + "]"
    let inventory = entries.map(\.prettyJSON).joined(separator: ",\n")
    let inventorySha256 = digest(Data(compact.utf8))
    return Data((#"""
    {
      "schemaVersion": 1,
      "profile": "\#(profile)",
      "csp": "\#(csp)",
      "inventory": [
    \#(inventory)
      ],
      "inventorySha256": "\#(inventorySha256)",
      "limitations": "\#(limitations)"
    }
    """# + "\n").utf8)
  }

  private static func validateResourceRoot(_ path: String) throws {
    let bundle = try openAbsoluteDirectory(path)
    defer { Darwin.close(bundle) }
    let bundleBefore = try directoryStat(bundle)
    let resources = try openDirectory("BexWebUI", at: bundle)
    defer { Darwin.close(resources) }
    let resourcesBefore = try directoryStat(resources)
    guard try names(in: resources, maximum: 2) == Set(["native.html", "assets"]) else {
      throw Rejection.invalidInventory
    }
    let assets = try openDirectory("assets", at: resources)
    defer { Darwin.close(assets) }
    let assetsBefore = try directoryStat(assets)
    let assetNames = try names(in: assets, maximum: 2)
    let scripts = assetNames.filter { validAssetName($0, suffix: ".js") }
    let styles = assetNames.filter { validAssetName($0, suffix: ".css") }
    guard assetNames.count == 2, scripts.count == 1, styles.count == 1,
      let script = scripts.first, let style = styles.first else { throw Rejection.invalidInventory }

    let expectedHTML = nativeHTML(script: script, style: style)
    let html = try readRegular("native.html", at: resources, limit: expectedHTML.count)
    guard html == expectedHTML else { throw Rejection.profileMismatch }
    func entry(_ name: String) throws -> Entry {
      let bytes = try readRegular(name, at: assets, limit: maximumResourceBytes)
      return Entry(path: "assets/" + name, bytes: bytes.count, sha256: digest(bytes))
    }
    let scriptEntry = try entry(script), styleEntry = try entry(style)
    let htmlEntry = Entry(path: "native.html", bytes: html.count, sha256: digest(html))
    let manifest = try readRegular("native-resource-manifest.json", at: bundle,
      limit: maximumManifestBytes)
    // Node's auditor uses en-locale collation, whose platform/ICU version must not
    // become an admission dependency. Accept exactly the two possible asset orders,
    // each with its own correct inventory digest and HTML last. No JSON decoder:
    // duplicate/unknown keys, type coercion and noncanonical bytes cannot pass.
    guard manifest == canonicalManifest([scriptEntry, styleEntry, htmlEntry]) ||
      manifest == canonicalManifest([styleEntry, scriptEntry, htmlEntry]) else {
      throw Rejection.profileMismatch
    }
    try requireUnchangedDirectory(assets, before: assetsBefore, name: "assets", at: resources)
    try requireUnchangedDirectory(resources, before: resourcesBefore, name: "BexWebUI", at: bundle)
    let bundleAfter = try directoryStat(bundle)
    var current = stat()
    guard lstat(path, &current) == 0, sameSnapshot(bundleBefore, bundleAfter),
      sameSnapshot(bundleAfter, current) else { throw Rejection.changedDuringRead }
  }

  private static func validAssetName(_ name: String, suffix: String) -> Bool {
    let bytes = Array(name.utf8)
    guard name.hasPrefix("native-"), name.hasSuffix(suffix),
      bytes.count >= 7 + 8 + suffix.utf8.count,
      bytes.count <= 7 + 64 + suffix.utf8.count else { return false }
    return bytes[7..<(bytes.count - suffix.utf8.count)].allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) ||
        (48...57).contains($0) || $0 == 95 || $0 == 45
    }
  }

  /// Walk pinned directory FDs from /, never follow an ancestor or leaf symlink.
  /// This does not pin the later paths WebKit uses or verify bundle signing.
  private static func openAbsoluteDirectory(_ path: String) throws -> Int32 {
    guard path.hasPrefix("/"), path.utf8.count < Int(MAXPATHLEN),
      !path.contains("\0"), !path.contains("\\") else { throw Rejection.invalidPath }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({
      !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ")
    }) else { throw Rejection.invalidPath }
    var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Rejection.unsafeDirectory }
    do {
      for component in components {
        let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw Rejection.unsafeDirectory }
        Darwin.close(fd)
        fd = next
      }
      _ = try directoryStat(fd)
      guard try descriptorPath(fd).utf8.elementsEqual(path.utf8) else { throw Rejection.invalidPath }
      return fd
    } catch {
      Darwin.close(fd)
      throw error
    }
  }

  private static func directoryStat(_ fd: Int32) throws -> stat {
    var value = stat()
    guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
      value.st_mode & 0o7022 == 0 else { throw Rejection.unsafeDirectory }
    return value
  }

  private static func openDirectory(_ name: String, at parent: Int32) throws -> Int32 {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Rejection.unsafeDirectory }
    do {
      _ = try directoryStat(fd)
      try requireCanonicalChild(fd, name: name, at: parent)
      return fd
    } catch { Darwin.close(fd); throw error }
  }

  // F_GETPATH supplies the actual spelling without enumerating the unbounded app
  // resource root. A case-insensitive filesystem must not alias the fixed names.
  private static func descriptorPath(_ fd: Int32) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let result = buffer.withUnsafeMutableBufferPointer {
      Darwin.fcntl(fd, F_GETPATH, $0.baseAddress!)
    }
    guard result == 0, buffer.contains(0), let path = buffer.withUnsafeBufferPointer({
      String(validatingUTF8: $0.baseAddress!)
    }) else { throw Rejection.invalidPath }
    return path
  }

  private static func requireCanonicalChild(_ fd: Int32, name: String, at parent: Int32) throws {
    let expected = try descriptorPath(parent) + "/" + name
    guard try descriptorPath(fd).utf8.elementsEqual(expected.utf8) else { throw Rejection.invalidPath }
  }

  /// Stops on a third entry; never recursively walks or accumulates an arbitrary tree.
  private static func names(in fd: Int32, maximum: Int) throws -> Set<String> {
    let copy = dup(fd)
    guard copy >= 0 else { throw Rejection.readFailed }
    guard let stream = fdopendir(copy) else { Darwin.close(copy); throw Rejection.readFailed }
    defer { closedir(stream) }
    var result = Set<String>()
    while true {
      errno = 0
      guard let item = readdir(stream) else {
        guard errno == 0 else { throw Rejection.readFailed }
        return result
      }
      let nameCapacity = MemoryLayout.size(ofValue: item.pointee.d_name)
      let name: String? = withUnsafePointer(to: &item.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
          String(validatingUTF8: $0)
        }
      }
      guard let name else { throw Rejection.invalidInventory }
      if name == "." || name == ".." { continue }
      guard name.utf8.count <= 75, result.count < maximum, result.insert(name).inserted else {
        throw Rejection.invalidInventory
      }
    }
  }

  private static func sameSnapshot(_ a: stat, _ b: stat) -> Bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode &&
      a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
      a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
      a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
  }

  private static func requireUnchangedDirectory(_ fd: Int32, before: stat,
                                                name: String, at parent: Int32) throws {
    let after = try directoryStat(fd)
    var current = stat()
    guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      sameSnapshot(before, after), sameSnapshot(after, current) else {
      throw Rejection.changedDuringRead
    }
  }

  private static func readRegular(_ name: String, at parent: Int32, limit: Int) throws -> Data {
    // Reject static special files before opening as well as checking the opened FD.
    var named = stat()
    guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
      named.st_mode & 0o7133 == 0 else { throw Rejection.unsafeFile }
    let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw Rejection.unsafeFile }
    defer { Darwin.close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_nlink == 1, before.st_mode & 0o7133 == 0,
      sameSnapshot(named, before) else { throw Rejection.unsafeFile }
    guard before.st_size >= 0, before.st_size <= off_t(limit) else { throw Rejection.oversizedFile }
    try requireCanonicalChild(fd, name: name, at: parent)
    let expected = Int(before.st_size)
    // One extra byte detects growth; the allocation and total read are bounded.
    var bytes = Data(count: expected + 1)
    let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
      var total = 0
      while total < buffer.count {
        let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: total), buffer.count - total)
        if count < 0 {
          if errno == EINTR { continue }
          throw Rejection.readFailed
        }
        if count == 0 { break }
        total += count
      }
      return total
    }
    var after = stat(), current = stat()
    guard fstat(fd, &after) == 0, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      count == expected, sameSnapshot(before, after), sameSnapshot(after, current) else {
      throw Rejection.changedDuringRead
    }
    bytes.removeLast()
    return bytes
  }
}
