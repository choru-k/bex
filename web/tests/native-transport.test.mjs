import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { NativeCorrectionTransport, MAX_BRIDGE_BYTES } from '../src/bridge/nativeTransport.ts';
import { makeRequest, DEFAULT_POLICY } from '../src/core/model.ts';

const request = () => makeRequest('The tests passes.', DEFAULT_POLICY);
const result = () => ({ protocolVersion: 1, original: 'The tests passes.', corrected: 'The tests pass.', notes: [], provenance: 'provider' });
const capabilities = () => ({ providerName: 'Native provider', perRequestConsent: true, operations: ['correct', 'cancel'], explanationLanguages: ['ko', 'en'] });
const signal = () => new AbortController().signal;
// Shared with the standalone Swift host tests. Passing here executes the renderer,
// not Swift: native compilation and XCTest remain a separate acceptance gate.
const vectors = JSON.parse(readFileSync(new URL('../../tests/fixtures/native-bridge-v1.json', import.meta.url), 'utf8'));
assert.equal(vectors.version, 1);
for (const vector of vectors.cases) {
  test(`shared native wire vector: ${vector.name}`, async t => {
    const h = harness(t); await h.connect();
    const pending = h.transport.check(vector.request, signal());
    assert.deepEqual(h.messages.at(-1).request, vector.request);
    h.reply(h.messages.at(-1), { kind: 'result', result: vector.result });
    if (vector.acceptResult) assert.deepEqual(await pending, vector.result);
    else await assert.rejects(pending, /Invalid native/);
  });
}
function harness(t, timeout = 1000) {
  const messages = [], listeners = new Set();
  const endpoint = { postMessage(json) { messages.push(JSON.parse(json)); },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); } };
  const transport = new NativeCorrectionTransport(endpoint, timeout);
  t.after(() => transport.close());
  const reply = (sent, content) => {
    const json = JSON.stringify({ bridgeVersion: 1, sessionID: sent.sessionID, requestID: sent.requestID, ...content });
    for (const listener of listeners) listener(json);
  };
  const connect = async () => {
    const pending = transport.connect(signal()); reply(messages.at(-1), { kind: 'capabilities', capabilities: capabilities() }); return pending;
  };
  return { transport, endpoint, messages, listeners, reply, connect };
}

test('construction sends no data; explicit handshake contains no writing or credentials', async t => {
  const h = harness(t); assert.equal(h.messages.length, 0);
  await assert.rejects(h.transport.check(request(), signal()), /not connected/);
  assert.equal(h.messages.length, 0);
  const c = await h.connect(); assert.equal(c.providerName, 'Native provider');
  assert.deepEqual(Object.keys(h.messages[0]).sort(), ['bridgeVersion', 'kind', 'requestID', 'sessionID']);
  c.providerName = 'mutated'; assert.equal((await h.transport.connect(signal())).providerName, 'Native provider');
});

test('correction round-trip snapshots validated input and requires provider provenance', async t => {
  const h = harness(t); await h.connect();
  const req = request(); const pending = h.transport.check(req, signal());
  req.policy.maxNotes = 2;
  const message = h.messages.at(-1); assert.equal(message.request.policy.maxNotes, 1);
  assert.deepEqual(Object.keys(message).sort(), ['bridgeVersion', 'kind', 'request', 'requestID', 'sessionID']);
  h.reply(message, { kind: 'result', result: result() }); assert.deepEqual(await pending, result());
});

for (const change of [{ perRequestConsent: false }, { operations: ['correct'] }, { providerName: '' }, { apiKey: 'must reject' }]) {
  test(`reject invalid host capability shape ${JSON.stringify(change)}`, async t => {
    const h = harness(t); const pending = h.transport.connect(signal());
    h.reply(h.messages.at(-1), { kind: 'capabilities', capabilities: { ...capabilities(), ...change } });
    await assert.rejects(pending, /Invalid native/);
    await assert.rejects(h.transport.check(request(), signal()), /not connected/);
  });
}

test('unrelated, stale and cross-session responses cannot settle a request', async t => {
  const h = harness(t); await h.connect(); const pending = h.transport.check(request(), signal());
  const message = h.messages.at(-1); let settled = false; void pending.then(() => { settled = true; });
  h.reply(message, { kind: 'result', requestID: 'unknown', result: result() });
  h.reply(message, { kind: 'result', sessionID: 'other-session', result: result() });
  await Promise.resolve(); assert.equal(settled, false);
  h.reply(message, { kind: 'result', result: result() }); assert.equal((await pending).corrected, 'The tests pass.');
  h.reply(message, { kind: 'result', result: { ...result(), corrected: 'late' } });
});

for (const response of [
  { kind: 'result', result: { ...result(), provenance: 'fixture' } },
  { kind: 'result', result: { ...result(), original: 'stale' } },
  { kind: 'result', result: null },
  { kind: 'result', bridgeVersion: 2, result: result() },
  { kind: 'result', result: result(), arbitrary: 'extra' },
  { kind: 'capabilities', capabilities: capabilities() },
]) {
  test(`invalid correlated response fails closed: ${JSON.stringify(response)}`, async t => {
    const h = harness(t); await h.connect(); const pending = h.transport.check(request(), signal());
    h.reply(h.messages.at(-1), response); await assert.rejects(pending, /Invalid native/);
  });
}

test('pre-aborted operations do not send messages', async t => {
  const h = harness(t); const controller = new AbortController(); controller.abort();
  await assert.rejects(h.transport.connect(controller.signal), { name: 'AbortError' });
  assert.equal(h.messages.length, 0); await h.connect(); const count = h.messages.length;
  await assert.rejects(h.transport.check(request(), controller.signal), { name: 'AbortError' });
  assert.equal(h.messages.length, count);
});

test('abort sends only correlated cancel, ignores late reply and permits a fresh request', async t => {
  const h = harness(t); await h.connect(); const controller = new AbortController();
  const pending = h.transport.check(request(), controller.signal); const sent = h.messages.at(-1);
  const rejected = assert.rejects(pending, { name: 'AbortError' }); controller.abort(); await rejected;
  assert.equal(h.messages.at(-1).kind, 'cancel'); assert.equal(h.messages.at(-1).requestID, sent.requestID);
  assert.equal(h.messages.at(-1).request, undefined); h.reply(sent, { kind: 'result', result: result() });
  const next = h.transport.check(request(), signal()); assert.notEqual(h.messages.at(-1).requestID, sent.requestID);
  h.reply(h.messages.at(-1), { kind: 'result', result: result() }); await next;
});

test('deadline releases pending requests even for garbage or oversized messages', async t => {
  const h = harness(t, 15); const pending = h.transport.connect(signal());
  for (const listener of h.listeners) { listener('not json'); listener('x'.repeat(MAX_BRIDGE_BYTES + 1)); }
  await assert.rejects(pending, /timed out/); assert.equal(h.messages.at(-1).kind, 'cancel');
  await h.connect();
});

test('errors are fixed messages, never arbitrary provider output', async t => {
  const h = harness(t); await h.connect();
  for (const code of ['consent-denied', 'unavailable', 'provider-failed', 'secret-error-text']) {
    const pending = h.transport.check(request(), signal()); h.reply(h.messages.at(-1), { kind: 'error', code });
    await assert.rejects(pending, error => !error.message.includes('secret-error-text'));
  }
});

test('outbound malformed or oversized request fails without calling endpoint', async t => {
  const h = harness(t); await h.connect();
  for (const req of [{ ...request(), protocolVersion: 2 }, { ...request(), apiKey: 'no' }, { ...request(), text: 'x'.repeat(12001) }]) {
    const count = h.messages.length; await assert.rejects(h.transport.check(req, signal())); assert.equal(h.messages.length, count);
  }
});

test('synchronous host reply is handled and posting failure is recoverable', async t => {
  const h = harness(t);
  h.endpoint.postMessage = json => { const sent = JSON.parse(json); h.reply(sent, { kind: 'capabilities', capabilities: capabilities() }); };
  await h.transport.connect(signal());
  h.endpoint.postMessage = () => { throw new Error('secret host implementation'); };
  await assert.rejects(h.transport.check(request(), signal()), { message: 'Native bridge is unavailable.' });
});

test('pending limit bounds work; close cancels, unsubscribes and rejects future work', async t => {
  const h = harness(t); await h.connect();
  const pending = Array.from({ length: 4 }, () => h.transport.check(request(), signal()));
  await assert.rejects(h.transport.check(request(), signal()), /Too many/);
  const rejected = pending.map(p => assert.rejects(p, /closed/)); h.transport.close(); await Promise.all(rejected);
  assert.equal(h.listeners.size, 0); assert.equal(h.messages.filter(m => m.kind === 'cancel').length, 4);
  h.transport.close(); await assert.rejects(h.transport.connect(signal()), /closed/);
  await assert.rejects(h.transport.check(request(), signal()), /closed/);
});

test('synchronous hello cannot admit duplicate handshake before capability publication', async t => {
  const h = harness(t);
  h.endpoint.postMessage = json => { const sent = JSON.parse(json); h.messages.push(sent); h.reply(sent, { kind: 'capabilities', capabilities: capabilities() }); };
  const first = h.transport.connect(signal());
  const second = h.transport.connect(signal());
  await assert.rejects(second, /already pending/); await first;
  assert.equal(h.messages.length, 1);
});

test('abort after immediate hello response prevents capability activation', async t => {
  const h = harness(t); const controller = new AbortController();
  h.endpoint.postMessage = json => { h.reply(JSON.parse(json), { kind: 'capabilities', capabilities: capabilities() }); controller.abort(); };
  await assert.rejects(h.transport.connect(controller.signal), { name: 'AbortError' });
  await assert.rejects(h.transport.check(request(), signal()), /not connected/);
});

test('malformed correlated result cancels host work and never surfaces provider text', async t => {
  const h = harness(t); await h.connect(); const pending = h.transport.check(request(), signal()); const sent = h.messages.at(-1);
  h.reply(sent, { kind: 'result', result: 'sensitive provider text' });
  await assert.rejects(pending, { message: 'Invalid native provider response.' });
  assert.equal(h.messages.at(-1).kind, 'cancel'); assert.equal(h.messages.at(-1).requestID, sent.requestID);
});

test('four concurrent corrections resolve only their own request even out of order', async t => {
  const h = harness(t); await h.connect();
  const requests = ['One', 'Two', 'Three', 'Four'].map(name => makeRequest(`${name} test.`, DEFAULT_POLICY));
  const pending = requests.map(req => h.transport.check(req, signal()));
  const sent = h.messages.filter(message => message.kind === 'correct');
  for (const index of [3, 1, 0, 2]) h.reply(sent[index], { kind: 'result', result: {
    ...result(), original: requests[index].text, corrected: `${requests[index].text} Corrected.`,
  } });
  const results = await Promise.all(pending);
  assert.deepEqual(results.map(result => result.original), requests.map(request => request.text));
});

test('UTF-8 byte limit rejects multibyte payload even below character limit', async t => {
  const h = harness(t, 15); const pending = h.transport.connect(signal()); const sent = h.messages.at(-1);
  h.reply(sent, { kind: 'capabilities', capabilities: capabilities(), padding: 'é'.repeat(65_000) });
  // If byte checking failed, the extra key would reject immediately as malformed.
  await assert.rejects(pending, /timed out/);
});

test('failed handshake can retry without retaining capabilities', async t => {
  const h = harness(t); const first = h.transport.connect(signal());
  h.reply(h.messages.at(-1), { kind: 'error', code: 'unavailable' });
  await assert.rejects(first, /could not complete/);
  assert.equal((await h.connect()).providerName, 'Native provider');
});

test('throwing cancel delivery does not replace the original abort or leak pending work', async t => {
  const h = harness(t); await h.connect(); const controller = new AbortController();
  const pending = h.transport.check(request(), controller.signal);
  h.endpoint.postMessage = () => { throw new Error('private implementation error'); };
  const rejected = assert.rejects(pending, { name: 'AbortError' }); controller.abort(); await rejected;
  h.endpoint.postMessage = json => { const sent = JSON.parse(json); h.reply(sent, { kind: 'result', result: result() }); };
  assert.equal((await h.transport.check(request(), signal())).corrected, 'The tests pass.');
});

test('posting failure releases capacity and supports another successful request', async t => {
  const h = harness(t); await h.connect();
  h.endpoint.postMessage = () => { throw new Error('endpoint temporarily unavailable'); };
  await assert.rejects(h.transport.check(request(), signal()), /unavailable/);
  h.endpoint.postMessage = json => { h.reply(JSON.parse(json), { kind: 'result', result: result() }); };
  assert.deepEqual(await h.transport.check(request(), signal()), result());
});

test('legacy host capabilities retain four-field requests and refuse an explicit language before dispatch', async t => {
  const h = harness(t); const pending = h.transport.connect(signal());
  const { explanationLanguages: _new, ...legacy } = capabilities();
  h.reply(h.messages.at(-1), { kind: 'capabilities', capabilities: legacy }); await pending;
  assert.deepEqual(h.transport.explanationLanguages, []);
  const before = h.messages.length;
  await assert.rejects(h.transport.check(makeRequest('The tests passes.', { ...DEFAULT_POLICY, explanationLanguage: 'en' }), signal()), /does not support/);
  assert.equal(h.messages.length, before);
  const correction = h.transport.check(request(), signal());
  assert.deepEqual(Object.keys(h.messages.at(-1).request.policy).sort(), ['alternatives', 'focus', 'maxNotes', 'vocabulary']);
  h.reply(h.messages.at(-1), { kind: 'result', result: result() }); await correction;
});
for (const languageList of [null, [], ['fr'], ['en', 'en'], ['ko', 'en', 'fr'], ['ko', 1], 'en']) {
  test(`invalid explanation capabilities fail closed: ${JSON.stringify(languageList)}`, async t => {
    const h = harness(t); const pending = h.transport.connect(signal());
    h.reply(h.messages.at(-1), { kind: 'capabilities', capabilities: { ...capabilities(), explanationLanguages: languageList } });
    await assert.rejects(pending, /Invalid native/);
  });
}
test('language capabilities are copied and only advertised choices can be dispatched', async t => {
  const h = harness(t); const pending = h.transport.connect(signal());
  h.reply(h.messages.at(-1), { kind: 'capabilities', capabilities: { ...capabilities(), explanationLanguages: ['ko'] } });
  const connected = await pending; connected.explanationLanguages.push('en');
  h.transport.explanationLanguages.push('en');
  assert.deepEqual((await h.transport.connect(signal())).explanationLanguages, ['ko']);
  const before = h.messages.length;
  await assert.rejects(h.transport.check(makeRequest('The tests passes.', { ...DEFAULT_POLICY, explanationLanguage: 'en' }), signal()), /does not support/);
  assert.equal(h.messages.length, before);
});
