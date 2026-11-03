import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { auditNativeResources, nativeHTML, NATIVE_CSP } from '../bex-audit-native-resources.mjs';
import { packageNativeResources, verifyNativeResourcePackage } from '../bex-package-native-resources.mjs';

// These are cross-language TEMPLATE and SOURCE checks, not Swift execution.
const swift = fs.readFileSync(new URL('../../Bex/WebBridge/NativePackagedResourceValidator.swift', import.meta.url), 'utf8');
const host = fs.readFileSync(new URL('../../Bex/WebBridge/PackagedCorrectionHost.swift', import.meta.url), 'utf8');
const xctest = fs.readFileSync(new URL('../../BexTests/NativePackagedResourceValidatorTests.swift', import.meta.url), 'utf8');
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
function constant(name) {
  const literal = swift.match(new RegExp(`static let ${name} = ("[^\\n]+")`));
  assert.ok(literal, `Missing ${name} literal`);
  return JSON.parse(literal[1]);
}
function rawLiteral(text, after, values = {}) {
  const section = text.slice(text.indexOf(after));
  assert.ok(section.length && text.includes(after), `Missing ${after}`);
  const match = section.match(/#"""\n([\s\S]*?)\n([ ]*)"""# \+ "\\n"/);
  assert.ok(match, `Missing raw template after ${after}`);
  const indentation = match[2];
  const template = match[1].split('\n').map(line => {
    assert.ok(line.startsWith(indentation));
    return line.slice(indentation.length);
  }).join('\n');
  return template.replace(/\\#\((\w+)\)/g, (_, key) => {
    assert.ok(Object.hasOwn(values, key), `Unknown interpolation ${key}`);
    return values[key];
  }) + '\n';
}
function entryLiteral(property, entry) {
  const match = swift.match(new RegExp(`var ${property}: String \\{[\\s\\S]*?\\n\\s*("(?:\\\\.|[^"\\n])*")`));
  assert.ok(match);
  return JSON.parse(match[1].replace(/\\\((\w+)\)/g, (_, key) => {
    assert.ok(Object.hasOwn(entry, key));
    return entry[key];
  }));
}
function manifestFromSwiftTemplate(inventory) {
  const compact = '[' + inventory.map(entry => entryLiteral('compactJSON', entry)).join(',') + ']';
  assert.equal(compact, JSON.stringify(inventory));
  return rawLiteral(swift, 'private static func canonicalManifest', {
    profile: constant('profile'), csp: constant('csp'), limitations: constant('limitations'),
    inventory: inventory.map(entry => entryLiteral('prettyJSON', entry)).join(',\n'),
    inventorySha256: sha256(compact),
  });
}
function fixture(t, script = 'native-A_0-azAZ.js', style = 'native-a_0-Azaz.css') {
  const parent = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'bex-native-admission-')));
  t.after(() => fs.rmSync(parent, { recursive: true, force: true }));
  const staging = path.join(parent, 'dist-native');
  fs.mkdirSync(path.join(staging, 'assets'), { recursive: true, mode: 0o700 });
  fs.writeFileSync(path.join(staging, 'native.html'), nativeHTML(script, style), { mode: 0o600 });
  fs.writeFileSync(path.join(staging, 'assets', script), 'export const fixture = true;\n', { mode: 0o600 });
  fs.writeFileSync(path.join(staging, 'assets', style), 'body { color: black; }\n', { mode: 0o600 });
  return { parent, staging, script, style, audit: auditNativeResources(staging) };
}

test('Swift exact HTML/CSP literal matches the unchanged Node profile, including UTF-8 and newline', () => {
  assert.equal(constant('csp'), NATIVE_CSP);
  for (const suffix of ['abcdefgh', 'A_0-azAZ', '_-012AZa', 'a'.repeat(64)]) {
    const script = `native-${suffix}.js`, style = `native-${suffix}.css`;
    assert.equal(rawLiteral(swift, 'private static func nativeHTML', { csp: NATIVE_CSP, script, style }), nativeHTML(script, style));
  }
});

test('Swift compact inventory and full canonical manifest templates match auditor bytes', t => {
  for (const [script, style] of [
    ['native-A_0-azAZ.js', 'native-a_0-Azaz.css'],
    ['native-________.js', 'native---------.css'],
    ['native-ZZZZZZZZ.js', 'native-00000000.css'],
    [`native-${'a'.repeat(64)}.js`, `native-${'Z'.repeat(64)}.css`],
  ]) {
    const { audit } = fixture(t, script, style);
    assert.equal(manifestFromSwiftTemplate(audit.inventory), JSON.stringify(audit, null, 2) + '\n');
    assert.equal(constant('profile'), audit.profile);
    assert.equal(constant('limitations'), audit.limitations);
  }
});

test('authored Swift golden fixtures are real offline packager outputs, not independently invented schemas', t => {
  const { parent, staging, audit, script, style } = fixture(t);
  const output = path.join(parent, 'review-package');
  packageNativeResources(staging, output);
  assert.deepEqual(verifyNativeResourcePackage(output), audit);
  assert.equal(rawLiteral(xctest, 'private static let fixtureHTML'), nativeHTML(script, style));
  const canonical = rawLiteral(xctest, 'private static let fixtureManifest');
  assert.equal(canonical, fs.readFileSync(path.join(output, 'native-resource-manifest.json'), 'utf8'));
  const reversed = rawLiteral(xctest, 'private static let reversedManifest');
  const inventory = [audit.inventory[1], audit.inventory[0], audit.inventory[2]];
  assert.equal(reversed, manifestFromSwiftTemplate(inventory));
  assert.notEqual(reversed, canonical);
  assert.deepEqual(JSON.parse(reversed), { ...audit, inventory, inventorySha256: sha256(JSON.stringify(inventory)) });
});

test('Swift maximum filename fixtures preserve the 64-character suffix and 75-byte CSS bounds', t => {
  const { audit, script, style } = fixture(t, `native-${'a'.repeat(64)}.js`, `native-${'Z'.repeat(64)}.css`);
  assert.equal(script.length, 74);
  assert.equal(style.length, 75);
  assert.equal(rawLiteral(xctest, 'private static let maximumHTML'), nativeHTML(script, style));
  assert.equal(rawLiteral(xctest, 'private static let maximumManifest'), JSON.stringify(audit, null, 2) + '\n');
});

test('inactive host obtains Bundle.main admission before WebKit construction, compilation and load', () => {
  const admission = host.indexOf('try NativePackagedResourceValidator.validateMainBundle()');
  const compilation = host.indexOf('compileContentRuleList(');
  const configuration = host.indexOf('let config = WKWebViewConfiguration()');
  const construction = host.indexOf('let host = try PackagedCorrectionHost(');
  const load = host.indexOf('host.webView.loadFileURL(document, allowingReadAccessTo: root)');
  assert.ok(admission > 0 && admission < compilation && compilation < configuration && configuration < construction && construction < load);
  assert.match(host, /let root = admitted\.resourceURL\s+let document = admitted\.documentURL/);
  assert.equal((host.match(/loadFileURL\(/g) || []).length, 1);
  assert.doesNotMatch(host, /Bundle\.main\.resourceURL|resolvingSymlinksInPath|missing or symlinked/);
  assert.match(swift, /static func validateMainBundle\(\) throws -> Admission/);
  assert.match(swift, /Bundle\.main\.resourceURL/);
  assert.match(swift, /fileprivate init\(resourceURL: URL\)/);
  assert.match(swift, /private static func validateResourceRoot\(_ path: String\)/);
  assert.match(swift, /#if DEBUG[\s\S]*?static func validateFixture\(resourceRootPath: String\) throws \{[\s\S]*?#endif/);
  assert.equal((swift.match(/return Admission\(/g) || []).length, 1);
  assert.doesNotMatch(swift, /Bundle\(path:|Bundle\(url:|URLSession|WKWebView|JSONDecoder\(|JSONSerialization\./);
});

test('source bounds enumeration, file reads and exact canonical schema without JSON coercion', () => {
  assert.match(swift, /maximumResourceBytes = 16 \* 1024 \* 1024/);
  assert.match(swift, /maximumManifestBytes = 64 \* 1024/);
  assert.match(swift, /names\(in: resources, maximum: 2\) == Set\(\["native.html", "assets"\]\)/);
  assert.match(swift, /names\(in: assets, maximum: 2\)/);
  assert.match(swift, /result\.count < maximum/);
  assert.match(swift, /bytes\.count >= 7 \+ 8 \+ suffix\.utf8\.count/);
  assert.match(swift, /bytes\.count <= 7 \+ 64 \+ suffix\.utf8\.count/);
  assert.match(swift, /Darwin\.fcntl\(fd, F_GETPATH/);
  assert.match(swift, /requireCanonicalChild\(fd, name: name, at: parent\)/);
  assert.match(swift, /O_RDONLY \| O_DIRECTORY \| O_NOFOLLOW \| O_CLOEXEC/);
  assert.match(swift, /O_RDONLY \| O_NOFOLLOW \| O_NONBLOCK \| O_CLOEXEC/);
  assert.match(swift, /named\.st_mode & S_IFMT == S_IFREG/);
  assert.match(swift, /before\.st_nlink == 1/);
  assert.match(swift, /before\.st_size <= off_t\(limit\)/);
  assert.match(swift, /Data\(count: expected \+ 1\)/);
  assert.match(swift, /while total < buffer\.count/);
  assert.match(swift, /sameSnapshot\(named, before\)/);
  assert.match(swift, /sameSnapshot\(before, after\), sameSnapshot\(after, current\)/);
  assert.match(swift, /SHA256\.hash\(data: bytes\)/);
  assert.match(swift, /html == expectedHTML/);
  assert.match(swift, /manifest == canonicalManifest\(\[scriptEntry, styleEntry, htmlEntry\]\) \|\|\s*manifest == canonicalManifest\(\[styleEntry, scriptEntry, htmlEntry\]\)/);
  assert.doesNotMatch(swift, /contentsOfDirectory|enumerator\(|Data\(contentsOf:|readToEnd\(|readDataToEndOfFile|JSONDecoder|localeCompare|Locale\(/);
});

test('every directly authored manifest mutation changes the golden bytes', () => {
  const manifest = rawLiteral(xctest, 'private static let fixtureManifest');
  const mutations = [...xctest.matchAll(/Self\.fixtureManifest\.replacingOccurrences\(\s*of: ("(?:\\.|[^"])*"),\s*with: ("(?:\\.|[^"])*")\)/g)];
  assert.ok(mutations.length >= 12);
  for (const [, before, after] of mutations) {
    const original = JSON.parse(before), replacement = JSON.parse(after);
    assert.ok(manifest.includes(original), `No-op Swift fixture mutation: ${original}`);
    assert.notEqual(manifest.replaceAll(original, replacement), manifest);
  }
});

test('synthetic Swift cases cover rejection families but remain explicitly unrun evidence', () => {
  const methods = [...xctest.matchAll(/func (test\w+)\(/g)].map(match => match[1]);
  assert.equal(methods.length, 16);
  for (const family of ['Golden', 'Missing', 'Extra', 'Symlink', 'HardLinked', 'FIFOs', 'Unsafe', 'Oversized', 'Filename', 'Aliases', 'HTML', 'Hash', 'Duplicate']) {
    assert.ok(methods.some(name => name.includes(family)), family);
  }
  assert.match(xctest, /NOT compiled\/run in cloud/);
  assert.match(swift, /trusted, signed,[\s\S]*?immutable application bundle/);
  assert.match(swift, /post-check race/);
});
