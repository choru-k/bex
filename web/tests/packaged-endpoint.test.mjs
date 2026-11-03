// Tests the injected Swift literal in Node. NOT WKWebView/security-origin evidence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const swift = fs.readFileSync(new URL('../../Bex/WebBridge/PackagedCorrectionHost.swift', import.meta.url), 'utf8');
const script = swift.match(/static let endpointScript = #"""\n([\s\S]*?)\n  """#/)[1];
function fixture({main = true} = {}) {
  const sent = [];
  const context = vm.createContext({TextEncoder});
  context.window = context;
  context.top = main ? context : {};
  context.webkit = {messageHandlers: {bexCorrection: {postMessage: json => sent.push(json)}}};
  vm.runInContext(script, context);
  return {context, sent, endpoint: context.__bexNativeCorrectionEndpoint,
    deliver: context.__bexDeliverNativeCorrection};
}
test('only exposes endpoint in main frame', () => {
  assert.equal(fixture({main:false}).endpoint, undefined);
});
test('endpoint accepts bounded UTF-8 strings only', () => {
  const f = fixture();
  f.endpoint.postMessage('x'.repeat(128000));
  assert.equal(f.sent[0].length, 128000);
  for (const value of [{method:'fetch'}, null, 1, 'x'.repeat(128001), '한'.repeat(42667)]) {
    assert.throws(() => f.endpoint.postMessage(value));
  }
  assert.equal(f.sent.length, 1);
});
test('response strings are data, callbacks are isolated, unsubscribe works', () => {
  const f = fixture(); const received = [];
  const unsubscribe = f.endpoint.subscribe(json => received.push(json));
  f.endpoint.subscribe(() => { throw new Error('listener failure'); });
  const next = []; f.endpoint.subscribe(json => next.push(json));
  const malicious = JSON.stringify({text:'\"; globalThis.executed = true; //</script>\u2028\u2029'});
  f.deliver(malicious);
  assert.deepEqual(received, [malicious]); assert.deepEqual(next, [malicious]);
  assert.equal(f.context.executed, undefined);
  unsubscribe(); unsubscribe(); f.deliver('second');
  assert.deepEqual(received, [malicious]); assert.equal(next.length, 2);
  f.deliver({}); f.deliver('x'.repeat(128001));
  assert.equal(next.length, 2);
});
test('endpoint and delivery global cannot be replaced', () => {
  const f = fixture();
  assert.equal(Object.isFrozen(f.endpoint), true);
  for (const key of ['__bexNativeCorrectionEndpoint','__bexDeliverNativeCorrection']) {
    const descriptor = Object.getOwnPropertyDescriptor(f.context,key);
    assert.equal(descriptor.writable,false); assert.equal(descriptor.configurable,false);
  }
  assert.throws(() => { f.endpoint.postMessage = () => {}; });
});
test('listener storage is bounded', () => {
  const f = fixture();
  for(let i=0;i<16;i++) f.endpoint.subscribe(() => {});
  assert.throws(() => f.endpoint.subscribe(() => {}));
});

// Source-regression checks only. They do not execute Swift or establish that
// MainActor, cancellation, WebKit, or the native mutation barrier work at runtime.
test('host captures settings only after reservation and registers before loading', () => {
  const make = swift.slice(swift.indexOf('  static func make('), swift.indexOf('  private init(window:'));
  assert.match(make, /make\(window: NSWindow, factory: ProviderClientFactory\)/);
  assert.doesNotMatch(make.slice(0, make.indexOf('-> PackagedCorrectionHost')), /destination:|effort:/);
  const reserve = make.indexOf('barrier.reserveAdmission()');
  const snapshot = make.indexOf('await factory.preferences.nativeCorrectionConfiguration()');
  const firstValidate = make.indexOf('barrier.validateAdmission(reservation)', snapshot);
  const compile = make.indexOf('await WKContentRuleListStore');
  const lastValidate = make.indexOf('barrier.validateAdmission(reservation)', compile);
  const register = make.indexOf('lifetime.register(reservation: reservation)');
  const load = make.indexOf('host.webView.loadFileURL');
  assert.ok(0 <= reserve && reserve < snapshot && snapshot < firstValidate);
  assert.ok(firstValidate < compile && compile < lastValidate && lastValidate < register && register < load);
  assert.doesNotMatch(make.slice(register, load), /\bawait\b/);
  assert.match(make.slice(load), /catch\s*\{[\s\S]*await host.closeAndWait\(\)/);
});

test('host lifetime retains registration through complete coordinator and transport drain', () => {
  const setup = swift.slice(swift.indexOf('lifetime = PackagedCorrectionHostLifetime('),
    swift.indexOf('  private func exactDocument('));
  assert.match(setup, /coordinator\.close\(\)/);
  assert.match(setup, /providerTransport\.close\(\)/);
  assert.match(setup, /presenter\.close\(\)/);
  assert.ok(setup.indexOf('await coordinator.closeAndWait()') < setup.indexOf('await providerTransport.closeAndWait()'));
  const lifetime = swift.slice(swift.indexOf('final class PackagedCorrectionHostLifetime'));
  assert.match(lifetime, /guard !isClosed, registration == nil/);
  const drain = lifetime.indexOf('await drain?()');
  const remove = lifetime.indexOf('barrier.removeHost(registration)');
  assert.ok(drain >= 0 && drain < remove);
  assert.equal((swift.match(/barrier\.removeHost\(/g) ?? []).length, 1);
});
