import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// Cross-platform packaging checks only. Runtime/signature/lifecycle tests live in
// BexTests/HookHelperLifecycleTests.swift and require macOS, not this source checker.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const plist = read('Config/HelperInfo.plist');
const protocol = read('BexHookShared/HookProtocol.swift');

test('sealed helper contract matches the app compatibility requirements', () => {
  const current = protocol.match(/static let current = HookHelperContract\(([\s\S]*?)\n  \)/)?.[1];
  assert.ok(current, 'explicit current helper contract required');
  for (const field of ['contractVersion', 'runtimeRevision']) {
    const xml = Number(plist.match(new RegExp(`<key>${field}</key>\\s*<integer>(\\d+)</integer>`))?.[1]);
    const swift = Number(current.match(new RegExp(`${field}: (\\d+)`))?.[1]);
    assert.ok(Number.isSafeInteger(xml) && xml > 0, `${field} must be a positive integer`);
    assert.equal(xml, swift, field);
  }
  for (const [field, constant] of [['protocolVersion', 'version'], ['maximumMessageBytes', 'maximumMessageBytes']]) {
    const xml = Number(plist.match(new RegExp(`<key>${field}</key>\\s*<integer>(\\d+)</integer>`))?.[1]);
    const swift = Number(protocol.match(new RegExp(`static let ${constant} = ([\\d_]+)`))?.[1].replaceAll('_', ''));
    assert.equal(xml, swift, field);
    assert.ok(current.includes(`${field}: HookProtocolConstants.${constant}`));
  }
  const name = protocol.match(/static let helperName = "([^"]+)"/)?.[1];
  assert.equal(plist.match(/<key>helper<\/key>\s*<string>([^<]+)<\/string>/)?.[1], name);
  assert.equal(plist.match(/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/)?.[1], name);
  const xmlCapabilities = [...plist.match(/<key>capabilities<\/key>\s*<array>([\s\S]*?)<\/array>/)[1].matchAll(/<string>([^<]+)<\/string>/g)].map(match => match[1]);
  const swiftCapabilities = [...current.match(/capabilities: \[([^\]]+)\]/)[1].matchAll(/"([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(xmlCapabilities.sort(), swiftCapabilities.sort());
  assert.equal(new Set(xmlCapabilities).size, xmlCapabilities.length);
});

test('all three helper configurations embed the signed plist without changing the host app plist', () => {
  const project = read('Bex.xcodeproj/project.pbxproj');
  const helperConfigurations = [...project.matchAll(/buildSettings = \{([\s\S]*?)\n\t\t\t\};/g)]
    .map(match => match[1]).filter(settings => settings.includes('PRODUCT_NAME = "bex-hook";'));
  assert.equal(helperConfigurations.length, 3);
  for (const settings of helperConfigurations) {
    assert.ok(settings.includes('CREATE_INFOPLIST_SECTION_IN_BINARY = YES;'));
    assert.ok(settings.includes('INFOPLIST_FILE = Config/HelperInfo.plist;'));
    assert.ok(settings.includes('GENERATE_INFOPLIST_FILE = NO;'));
  }
  assert.equal((project.match(/INFOPLIST_FILE = Config\/Info.plist;/g) ?? []).length, 2);
});

test('diagnostic self-check uses the same explicit runtime contract', () => {
  const main = read('BexHook/BexHookMain.swift');
  const selfCheck = main.slice(main.indexOf('private static func writeSelfCheck()'), main.indexOf('private static func writeHeartbeat('));
  assert.ok(selfCheck.includes('encoder.encode(HookHelperContract.current)'));
});
