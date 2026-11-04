// Source-regression evidence ONLY. This does not compile Swift, execute the owner,
// construct AppKit/WebKit, validate isolation or authorize native activation.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read = path => fs.readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const owner = read('Bex/WebBridge/PackagedCorrectionWindowOwner.swift');
const session = read('Bex/WebBridge/PackagedCorrectionNativeWindowSession.swift');
const services = read('Bex/Application/AppServices.swift');
const windows = read('Bex/Application/WindowCoordinator.swift');
const delegate = read('Bex/Application/AppDelegate.swift');
const project = read('Bex.xcodeproj/project.pbxproj');

function body(source, start, end) {
  const left = source.indexOf(start), right = source.indexOf(end, left + start.length);
  assert.ok(left >= 0 && right > left, `Expected boundaries: ${start}, ${end}`);
  return source.slice(left, right);
}

test('app stores exactly one owner and its initialization only captures existing stores', () => {
  assert.equal((services.match(/let packagedCorrectionWindows:/g) ?? []).length, 1);
  assert.equal((services.match(/packagedCorrectionWindows = PackagedCorrectionWindowOwner\(/g) ?? []).length, 1);
  const factory = body(session, '  convenience init(', '\n}\n');
  assert.match(factory, /self\.init \{ onClose in\s*PackagedCorrectionNativeWindowSession/);
  assert.match(owner, /init\(makeSession: @escaping SessionFactory\) \{ self\.makeSession = makeSession \}/);
  assert.doesNotMatch(factory, /Task\s*\{|await |\.requestOpen\(|NSWindow\(|URLSessionTransport\(/);
});

test('only composition open hook is a literal disabled branch with no runtime switch', () => {
  assert.match(windows, /#if false\s+func showPackagedCorrection\(\) \{\s+services\.packagedCorrectionWindows\.requestOpen\(\)\s+\}\s+#endif/);
  for (const source of [delegate, services, session]) {
    assert.doesNotMatch(source, /\.requestOpen\(/);
  }
  assert.doesNotMatch(owner + session, /ProcessInfo|UserDefaults|NotificationCenter|CommandLine|URL\(string:/);
  assert.doesNotMatch(project, /BEX_PACKAGED/);
  // Debug, Release and the dedicated UITesting app configuration all default OFF.
  assert.equal((project.match(/BEX_EMBED_NATIVE_WEB_RESOURCES = NO;/g) ?? []).length, 3);
  assert.doesNotMatch(project, /BEX_EMBED_NATIVE_WEB_RESOURCES = YES;/);
});

test('concrete session delegates trust and account admission to the existing host', () => {
  assert.match(session, /PackagedCorrectionHost\.make\(window: window, factory: factory\)/);
  assert.doesNotMatch(session, /loadFileURL|loadHTMLString|WKWebView\(|registerHost|reserveAdmission|nativeCorrectionConfiguration\(/);
  assert.match(session, /var isClosed: Bool \{ closed \|\| host\?\.isClosed == true \}/);
  const prepare = body(session, '  func prepare()', '  func present()');
  assert.match(prepare, /guard !closed, !candidate\.isClosed, !Task\.isCancelled/);
  assert.ok(prepare.indexOf('host = candidate') < prepare.indexOf('guard !closed, !candidate.isClosed'));
  assert.match(prepare, /candidate\.close\(\)\s+await candidate\.closeAndWait\(\)/);
  const close = body(session, '  func close()', '  func closeAndWait()');
  assert.ok(close.indexOf('host?.close()') < close.indexOf('window.close()'));
});

test('owner starts replacement only after exact session full drain', () => {
  const transitions = body(owner, '  private func reconcile()', '  deinit {');
  assert.match(transitions, /defer \{ worker = nil \}/);
  assert.doesNotMatch(owner, /await reconcile\(\)\s+worker = nil/);
  const drain = transitions.indexOf('await active.session.closeAndWait()');
  const release = transitions.indexOf('current = nil', drain);
  const construct = transitions.indexOf('let session = makeSession', release);
  assert.ok(drain >= 0 && drain < release && release < construct);
  assert.equal((owner.match(/= makeSession \{/g) ?? []).length, 1);
  assert.match(transitions, /let result = await prepare\.result/);
  assert.match(transitions, /if desiredOpen == active\.id \{ desiredOpen = nil \}/);
  assert.match(owner, /guard current\?\.id == id, desiredOpen == id else \{ return \}/);
  assert.doesNotMatch(owner, /worker\?\.cancel\(|worker\.cancel\(|Task\.sleep\(/);
});

test('termination is synchronous when dormant and joins one retained full drain when active', () => {
  const allTermination = body(delegate, '  func applicationShouldTerminate(', '  func applicationWillTerminate(');
  // Independent helper injection has its own dormant shutdown branch and source tests.
  const legacyStart = allTermination.indexOf('    guard let owner = services?.packagedCorrectionWindows');
  assert.ok(legacyStart >= 0);
  const terminate = allTermination.slice(legacyStart);
  const shutdown = terminate.indexOf('owner.shutdown()');
  const dormant = terminate.indexOf('guard owner.hasOutstandingWork else { return .terminateNow }');
  const task = terminate.indexOf('packagedTerminationTask = Task');
  const drain = terminate.indexOf('await owner.shutdownAndWait()');
  const reply = terminate.indexOf('sender.reply(toApplicationShouldTerminate: true)');
  assert.ok(shutdown >= 0 && shutdown < dormant && dormant < task && task < drain && drain < reply);
  assert.match(terminate, /if packagedTerminationTask == nil/);
  assert.match(terminate, /return \.terminateLater/);
  const stop = body(owner, '  func shutdown()', '  func shutdownAndWait()');
  assert.ok(stop.indexOf('stopped = true') < stop.indexOf('close()'));
  assert.match(owner, /func requestOpen\(\) \{\s+guard !stopped else \{ return \}/);
});
