import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HostFlow, SimulatedHost, parseSentObservation, MAX_FEEDBACK_ITEMS, MAX_PENDING_COACHING } from '../src/host/hostFlow.ts';
import { DEFAULT_POLICY } from '../src/core/model.ts';
import { FixtureTransport, SCENARIOS } from '../src/core/fixtures.ts';

const original = SCENARIOS[0].text;
const corrected = 'Wouldn’t this make it harder to maintain?';
const result = text => ({ protocolVersion: 1, original: text, corrected: text === original ? corrected : text, notes: [], provenance: 'fixture' });
const tick = async () => { await new Promise(resolve => setImmediate(resolve)); };
function controlled() {
  const calls = [];
  return { calls, transport: { kind: 'fixture', check(request, signal) {
    return new Promise((resolve, reject) => calls.push({ request, signal, resolve, reject }));
  } } };
}
function event(id = 'm1', text = original, appId = 'chatgpt') {
  return { version: 1, type: 'user-message-sent', sessionId: 'session-1', appId, conversationId: 'conversation-1', messageId: id, text };
}
function setup(t, transport, timeoutMs = 1000) {
  const flow = new HostFlow(transport, () => {}, timeoutMs);
  t.after(() => flow.dispose()); return flow;
}
async function readyReview(flow, host, control) {
  flow.beginReview(host); await tick(); control.calls.at(-1).resolve(result(host.snapshot().text)); await tick();
  assert.equal(flow.snapshot().review.status, 'ready'); return flow.snapshot().review.id;
}

test('observations are strict, bounded, versioned and copied without changing exact text', () => {
  const input = event('m1', '  original\n'); const parsed = parseSentObservation(input);
  assert.deepEqual(parsed, input); assert.notEqual(parsed, input);
  for (const invalid of [null, [], {}, { ...input, version: 2 }, { ...input, type: 'draft' },
    { ...input, role: 'assistant' }, { ...input, appId: '' }, { ...input, conversationId: 'bad target' },
    { ...input, messageId: 'x'.repeat(129) }, { ...input, text: '' }, { ...input, text: 'x'.repeat(12001) }]) {
    assert.throws(() => parseSentObservation(invalid));
  }
});
test('live native transport cannot be accidentally enabled through the simulation', () => {
  assert.throws(() => new HostFlow({ kind: 'native', check() { throw new Error('must not run'); } }), /simulation-only/);
});
test('original send commits exact text synchronously before any coaching work', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', '  original\n');
  const observation = host.sendOriginal();
  assert.equal(host.transcript()[0].text, '  original\n');
  flow.observeSent(observation);
  assert.equal(control.calls.length, 0);
  assert.equal(flow.snapshot().feedback[0].state, 'pending');
  host.edit('next message'); await tick();
  assert.equal(host.snapshot().text, 'next message');
  control.calls[0].resolve(result(observation.text)); await tick();
  assert.equal(host.transcript()[0].text, '  original\n');
  assert.equal(host.transcript().length, 1); assert.equal(host.snapshot().text, 'next message');
});
test('unknown freely typed text still sends; fixture refusal only changes feedback', async t => {
  const flow = setup(t, new FixtureTransport(0)); const host = new SimulatedHost('claude', 'This is not a fixture.');
  flow.observeSent(host.sendOriginal()); await new Promise(resolve => setTimeout(resolve, 15));
  assert.equal(flow.snapshot().feedback[0].state, 'unavailable');
  assert.equal(host.transcript()[0].text, 'This is not a fixture.');
});
test('synchronous failures, malformed results and observer failures do not undo original sends', async t => {
  const flow = new HostFlow({ kind: 'fixture', check() { throw new Error('failure'); } }, () => { throw new Error('render failed'); });
  t.after(() => flow.dispose()); const host = new SimulatedHost('other', original);
  flow.observeSent(host.sendOriginal()); await tick();
  assert.equal(host.transcript().length, 1); assert.equal(flow.snapshot().feedback[0].state, 'unavailable');
  assert.doesNotThrow(() => flow.observeSent({ bad: true }));
});
test('backpressure skips coaching rather than suppressing send and inbox stays bounded', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost();
  for (let i = 0; i < 50; i++) { host.edit(`message ${i}`); flow.observeSent(host.sendOriginal()); }
  await tick();
  assert.equal(host.transcript().length, MAX_FEEDBACK_ITEMS);
  assert.equal(host.transcript().at(-1).text, 'message 49');
  assert.equal(flow.snapshot().feedback.length, MAX_FEEDBACK_ITEMS);
  assert.ok(flow.snapshot().feedback.filter(item => item.state === 'pending').length <= MAX_PENDING_COACHING);
  assert.ok(control.calls.length <= MAX_PENDING_COACHING);
  assert.ok(flow.snapshot().feedback.some(item => item.state === 'skipped'));
});
test('duplicate message observations never create duplicate coaching or host sends', async t => {
  const control = controlled(); const flow = setup(t, control.transport);
  flow.observeSent(event()); flow.observeSent(event()); await tick();
  assert.equal(control.calls.length, 1); assert.equal(flow.snapshot().feedback.length, 1);
});
test('out-of-order cross-app responses remain bound to their original message and policy', async t => {
  const control = controlled(); const flow = setup(t, control.transport);
  flow.observeSent(event('one', original, 'chatgpt'));
  flow.configure({ ...DEFAULT_POLICY, maxNotes: 2 });
  flow.observeSent(event('one', 'Second message', 'claude')); await tick();
  control.calls[1].resolve(result('Second message')); await tick();
  control.calls[0].resolve(result(original)); await tick();
  const items = flow.snapshot().feedback;
  assert.deepEqual(items.map(item => [item.observation.appId, item.result.original, item.policy.maxNotes]), [['chatgpt', original, 1], ['claude', 'Second message', 2]]);
  assert.equal(control.calls[0].request.source, null);
});
test('timeout aborts coaching and late transport completion cannot revive it', async t => {
  const control = controlled(); const flow = setup(t, control.transport, 10);
  flow.observeSent(event()); await tick(); await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal(control.calls[0].signal.aborted, true);
  assert.equal(flow.snapshot().feedback[0].state, 'unavailable');
  control.calls[0].resolve(result(original)); await tick();
  assert.equal(flow.snapshot().feedback[0].result, undefined);
});
test('mismatched original from provider is rejected', async t => {
  const control = controlled(); const flow = setup(t, control.transport);
  flow.observeSent(event()); await tick(); control.calls[0].resolve(result('other')); await tick();
  assert.equal(flow.snapshot().feedback[0].state, 'unavailable');
});
test('a review result alone sends nothing and explicit confirmation sends exactly once', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('claude', original);
  const id = await readyReview(flow, host, control);
  assert.equal(host.transcript().length, 0); assert.equal(host.snapshot().text, original);
  assert.equal(flow.confirmFixAndSend(host, 'unshown-review').status, 'not-sent');
  assert.equal(flow.confirmFixAndSend(host, id).status, 'sent');
  assert.equal(host.transcript()[0].text, corrected);
  assert.equal(host.transcript()[0].appId, 'claude');
  assert.equal(host.transcript()[0].origin, 'fix-and-send');
  assert.equal(flow.confirmFixAndSend(host, id).status, 'not-sent');
  assert.equal(host.transcript().length, 1); assert.equal(flow.snapshot().feedback.length, 0);
});
test('editing, changing target or changing conversation after preview blocks corrected send', async t => {
  for (const change of [host => host.edit('new draft'), host => host.switchTarget('other'), host => host.switchTarget('chatgpt', 'other-conversation')]) {
    const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
    const id = await readyReview(flow, host, control); change(host);
    assert.equal(flow.confirmFixAndSend(host, id).status, 'not-sent'); assert.equal(host.transcript().length, 0);
  }
});
test('edit then restore same text still invalidates the reviewed revision', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  const id = await readyReview(flow, host, control); host.edit('changed'); host.edit(original);
  assert.equal(flow.confirmFixAndSend(host, id).status, 'not-sent'); assert.equal(host.transcript().length, 0);
});
test('atomic host comparison catches changes after the flow preflight snapshot', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  const id = await readyReview(flow, host, control);
  const racingHost = { snapshot: () => host.snapshot(), compareAndSend(expected, text, operationId) {
    host.switchTarget('claude'); return host.compareAndSend(expected, text, operationId);
  } };
  assert.equal(flow.confirmFixAndSend(racingHost, id).status, 'not-sent'); assert.equal(host.transcript().length, 0);
});
test('changes during review prevent an old result becoming sendable', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); await tick(); host.switchTarget('claude');
  control.calls[0].resolve(result(original)); await tick();
  assert.equal(flow.snapshot().review.status, 'blocked'); assert.equal(host.transcript().length, 0);
});
test('cancel, replacement and changed learning settings suppress obsolete review completions', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); await tick(); flow.cancelReview();
  control.calls[0].resolve(result(original)); await tick(); assert.equal(flow.snapshot().review.status, 'idle');
  flow.beginReview(host); await tick(); flow.beginReview(host); await tick();
  assert.equal(control.calls.length, 2); assert.equal(flow.snapshot().review.status, 'unavailable');
  control.calls[1].resolve(result(original)); await tick(); assert.equal(flow.snapshot().review.status, 'unavailable');
  flow.beginReview(host); await tick();
  flow.configure({ ...DEFAULT_POLICY, maxNotes: 0 });
  control.calls[2].resolve(result(original)); await tick();
  assert.equal(flow.snapshot().review.status, 'idle'); assert.equal(host.transcript().length, 0);
});
test('failure and timeout in review never fall back to sending the original', async t => {
  const control = controlled(); const flow = setup(t, control.transport, 10); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); await tick(); await new Promise(resolve => setTimeout(resolve, 25));
  assert.equal(flow.snapshot().review.status, 'unavailable'); assert.equal(host.transcript().length, 0);
  control.calls[0].resolve(result(original)); await tick(); assert.equal(flow.snapshot().review.status, 'unavailable');
  flow.beginReview(host); await tick(); control.calls[1].reject(new Error('offline')); await tick();
  assert.equal(flow.snapshot().review.status, 'unavailable'); assert.equal(host.transcript().length, 0);
});
test('original send while review is pending cannot later send the correction', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); await tick(); const observed = host.sendOriginal(); flow.observeSent(observed);
  control.calls[0].resolve(result(original)); await tick();
  assert.equal(flow.snapshot().review.status, 'blocked'); assert.equal(host.transcript().length, 1);
  assert.equal(host.transcript()[0].text, original);
});
test('cleared draft or unreadable host before commit is a known no-send, not an uncertain attempt', async t => {
  for (const snapshot of [() => ({ sessionId: 'simulation', appId: 'chatgpt', conversationId: 'conversation-1', revision: 1, text: '' }), () => { throw new Error('permission unavailable'); }]) {
    const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
    const id = await readyReview(flow, host, control);
    assert.equal(flow.confirmFixAndSend({ snapshot, compareAndSend() { assert.fail('must not attempt'); } }, id).status, 'not-sent');
    assert.equal(flow.snapshot().review.status, 'blocked');
  }
});
test('changed authenticated host session invalidates a ready review even for identical text', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  const id = await readyReview(flow, host, control);
  const changedHost = { snapshot: () => ({ ...host.snapshot(), sessionId: 'new-session' }), compareAndSend() { assert.fail('must not attempt'); } };
  assert.equal(flow.confirmFixAndSend(changedHost, id).status, 'not-sent');
});
test('known host rejection leaves the original unsent and requires a fresh review before trying again', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  const id = await readyReview(flow, host, control); let attempts = 0;
  const rejectingHost = { snapshot: () => host.snapshot(), compareAndSend() { attempts++; return { status: 'not-sent' }; } };
  assert.equal(flow.confirmFixAndSend(rejectingHost, id).status, 'not-sent');
  assert.equal(flow.confirmFixAndSend(rejectingHost, id).status, 'not-sent');
  assert.equal(attempts, 1); assert.equal(host.transcript().length, 0); assert.equal(host.snapshot().text, original);
  const freshId = await readyReview(flow, host, control); assert.notEqual(id, freshId);
});
test('uncertain host outcome consumes confirmation and prevents all review retries', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  const id = await readyReview(flow, host, control); let attempts = 0;
  const uncertainHost = { snapshot: () => host.snapshot(), compareAndSend() { attempts++; throw new Error('unknown transport outcome'); } };
  assert.equal(flow.confirmFixAndSend(uncertainHost, id).status, 'unknown');
  flow.cancelReview(); flow.configure({ ...DEFAULT_POLICY, maxNotes: 0 }); flow.beginReview(uncertainHost);
  assert.equal(flow.confirmFixAndSend(uncertainHost, id).status, 'not-sent');
  assert.equal(flow.snapshot().review.status, 'unknown'); assert.equal(attempts, 1);
});
test('malformed host acknowledgement is unknown, never treated as successful delivery', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  const id = await readyReview(flow, host, control);
  assert.equal(flow.confirmFixAndSend({ snapshot: () => host.snapshot(), compareAndSend: () => undefined }, id).status, 'unknown');
});
test('review operation identifiers cannot collide after controller remount', async t => {
  const control = controlled(); const host = new SimulatedHost('chatgpt', original);
  const first = setup(t, control.transport); const firstId = await readyReview(first, host, control); first.cancelReview();
  const second = setup(t, control.transport); const secondId = await readyReview(second, host, control);
  assert.notEqual(firstId, secondId);
});
test('invalid drafts fail safe without invoking model or host commit', async t => {
  const control = controlled(); const flow = setup(t, control.transport);
  flow.beginReview({ snapshot: () => ({ ...new SimulatedHost().snapshot(), text: original, revision: -1 }), compareAndSend() { assert.fail(); } });
  await tick(); assert.equal(flow.snapshot().review.status, 'blocked'); assert.equal(control.calls.length, 0);
});
test('dispose requests cancellation, forgets visible session text and ignores late results', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  flow.observeSent(event()); flow.beginReview(host); await tick(); flow.dispose();
  for (const call of control.calls) { assert.equal(call.signal.aborted, true); call.resolve(result(original)); }
  await tick(); flow.observeSent(event('later')); flow.beginReview(host);
  assert.deepEqual(flow.snapshot(), { feedback: [], review: { status: 'idle' } });
});
test('external mutation of snapshots or observations cannot change queued work', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const raw = event();
  flow.observeSent(raw); raw.text = 'mutated'; flow.snapshot().feedback[0].observation.text = 'changed'; await tick();
  assert.equal(control.calls[0].request.text, original);
});

test('ignored-abort coaching retains capacity after timeout until actual settlement', async t => {
  const control = controlled(); const flow = setup(t, control.transport, 10);
  for (let i = 0; i < MAX_PENDING_COACHING; i++) flow.observeSent(event(`initial-${i}`));
  await tick(); assert.equal(control.calls.length, MAX_PENDING_COACHING);
  await new Promise(resolve => setTimeout(resolve, 25));
  assert.ok(control.calls.every(call => call.signal.aborted));
  for (let wave = 0; wave < 5; wave++) {
    for (let i = 0; i < 10; i++) flow.observeSent(event(`timeout-${wave}-${i}`));
    await tick(); assert.equal(control.calls.length, MAX_PENDING_COACHING);
  }
  assert.ok(flow.snapshot().feedback.every(item => item.state === 'skipped'));
  control.calls[0].resolve(result(original)); await tick();
  flow.observeSent(event('after-real-settlement')); await tick();
  assert.equal(control.calls.length, MAX_PENDING_COACHING + 1);
  flow.observeSent(event('capacity-full-again')); await tick();
  assert.equal(control.calls.length, MAX_PENDING_COACHING + 1);
  assert.equal(flow.snapshot().feedback.at(-1).state, 'skipped');
  assert.equal(flow.snapshot().feedback.some(item => item.result), false);
});
test('ignored-abort coaching retains capacity after eviction and releases exactly one rejected slot', async t => {
  const control = controlled(); const flow = setup(t, control.transport);
  for (let i = 0; i < MAX_PENDING_COACHING; i++) flow.observeSent(event(`initial-${i}`));
  await tick();
  for (let i = 0; i < MAX_FEEDBACK_ITEMS * 3; i++) { flow.observeSent(event(`evicted-${i}`)); await tick(); }
  assert.equal(control.calls.length, MAX_PENDING_COACHING);
  assert.ok(control.calls.every(call => call.signal.aborted));
  assert.equal(flow.snapshot().feedback.length, MAX_FEEDBACK_ITEMS);
  control.calls[0].reject(new Error('finally stopped')); await tick();
  flow.observeSent(event('one-free-slot')); flow.observeSent(event('no-free-slot')); await tick();
  assert.equal(control.calls.length, MAX_PENDING_COACHING + 1);
  assert.equal(flow.snapshot().feedback.at(-2).state, 'pending');
  assert.equal(flow.snapshot().feedback.at(-1).state, 'skipped');
});
test('ignored-abort cancelled review blocks repeated replacements until actual settlement', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); await tick(); flow.cancelReview();
  for (let i = 0; i < 20; i++) {
    flow.beginReview(host); flow.cancelReview(); await tick();
    assert.equal(control.calls.length, 1);
  }
  assert.equal(control.calls[0].signal.aborted, true);
  control.calls[0].resolve(result(original)); await tick();
  assert.equal(flow.snapshot().review.status, 'idle');
  flow.beginReview(host); await tick(); assert.equal(control.calls.length, 2);
  assert.equal(flow.snapshot().review.status, 'pending');
  assert.equal(host.transcript().length, 0);
});
test('ignored-abort timed-out review blocks all new reviews while original sends still work', async t => {
  const control = controlled(); const flow = setup(t, control.transport, 10); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); await tick(); await new Promise(resolve => setTimeout(resolve, 25));
  for (let i = 0; i < 20; i++) { flow.beginReview(host); await tick(); }
  assert.equal(control.calls.length, 1); assert.equal(flow.snapshot().review.status, 'unavailable');
  const sent = host.sendOriginal(); flow.observeSent(sent); await tick();
  assert.equal(host.transcript()[0].text, original); assert.equal(control.calls.length, 2);
  assert.equal(control.calls[1].signal.aborted, false);
  control.calls[0].reject(new Error('finally stopped')); await tick();
  host.edit(original); flow.beginReview(host); await tick(); assert.equal(control.calls.length, 3);
  assert.equal(flow.snapshot().review.status, 'pending'); assert.equal(host.transcript().length, 1);
});
test('pre-dispatch cancellation settles its reserved slot without calling a transport', async t => {
  const control = controlled(); const flow = setup(t, control.transport); const host = new SimulatedHost('chatgpt', original);
  flow.beginReview(host); flow.cancelReview(); flow.beginReview(host); await tick();
  assert.equal(control.calls.length, 0); assert.equal(flow.snapshot().review.status, 'unavailable');
  flow.beginReview(host); await tick(); assert.equal(control.calls.length, 1);
});
