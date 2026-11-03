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
