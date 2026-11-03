import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { runInNewContext } from 'node:vm';

const native = readFileSync(new URL('../native/main.swift', import.meta.url), 'utf8');
function script(name) {
  const source = native.match(new RegExp(`private let ${name} = #"""\\n([\\s\\S]*?)\\n"""#`))?.[1];
  assert.ok(source, `Native script ${name} exists`);
  return source;
}
const probeSource = script('smokeProbeScript');
const errorCaptureSource = script('smokeErrorCaptureScript');

// These unit tests check the exact native probe's decisions, not browser rendering.
function harness(overrides = {}) {
  const state = { root: true, ready: true, request: 'idle', button: true, disabled: false,
    corrected: '', alert: '', clicks: 0, ...overrides };
  const listeners = new Map();
  const listenerOptions = new Map();
  const window = { addEventListener: (name, listener, options) => {
    listeners.set(name, listener); listenerOptions.set(name, options);
  } };
  const document = {
    readyState: 'complete',
    querySelector(selector) {
      if (selector === '.shell') return state.root ? { getAttribute: name =>
        name === 'data-lab-ready' ? String(state.ready) : state.request } : null;
      if (selector === 'button.primary') return state.button ? {
        disabled: state.disabled, click: () => { state.clicks++; },
      } : null;
      if (selector === '[data-testid=corrected]') return { textContent: state.corrected };
      if (selector === '[role=alert]') return { textContent: state.alert };
      throw new Error(`Unexpected selector: ${selector}`);
    },
  };
  const context = { window, document };
  runInNewContext(errorCaptureSource, context);
  return { state, window, listeners, listenerOptions, probe: (click = true) =>
    JSON.parse(runInNewContext(`JSON.stringify((${probeSource})(${click}))`, context)) };
}

test('native probe waits for the app effect marker, not just a visible button', () => {
  for (const overrides of [{ root: false }, { ready: false }]) {
    const h = harness(overrides);
    assert.equal(h.probe().phase, 'waiting-ready');
    assert.equal(h.state.clicks, 0);
  }
});

test('native probe distinguishes click dispatch from request acceptance and never retries it', () => {
  const h = harness();
  const dispatched = h.probe();
  assert.equal(dispatched.phase, 'click-dispatched');
  assert.equal(dispatched.clicked, true);
  assert.equal(dispatched.state, 'idle');
  assert.equal(h.probe(false).phase, 'idle');
  assert.equal(h.state.clicks, 1);
});

test('native probe reports a pending request without clicking', () => {
  const h = harness({ request: 'pending' });
  assert.equal(h.probe().phase, 'pending');
  assert.equal(h.state.clicks, 0);
});

test('native probe does not click disabled or absent buttons', () => {
  for (const overrides of [{ disabled: true }, { button: false }]) {
    const h = harness(overrides);
    assert.equal(h.probe().phase, 'waiting-button');
    assert.equal(h.state.clicks, 0);
  }
});

test('native probe reports application errors, including after a click', () => {
  const h = harness();
  h.probe();
  h.state.alert = 'Controlled failure';
  h.state.request = 'error';
  assert.equal(h.probe(false).phase, 'error');
  assert.equal(h.probe(false).alert, 'Controlled failure');
  assert.equal(h.state.clicks, 1);
});

test('native probe returns the actual result for the native exact-text assertion', () => {
  const h = harness({ corrected: 'Wrong result', request: 'result' });
  const snapshot = h.probe();
  assert.equal(snapshot.phase, 'result');
  assert.equal(snapshot.corrected, 'Wrong result');
  assert.equal(snapshot.clicked, false);
  assert.equal(h.state.clicks, 0);
});

test('page error capture includes exceptions and rejections with bounded output', () => {
  const h = harness();
  // Resource element errors do not bubble, so the window listener must capture.
  assert.equal(h.listenerOptions.get('error'), true);
  h.listeners.get('error')({ message: 'Script failed' });
  h.listeners.get('unhandledrejection')({ reason: new Error('Promise failed') });
  for (let i = 0; i < 10; i++) h.listeners.get('error')({ message: 'x'.repeat(2_000) });
  const snapshot = h.probe();
  assert.equal(snapshot.phase, 'error');
  assert.deepEqual(snapshot.errors.slice(0, 2), ['Script failed', 'Promise failed']);
  assert.equal(snapshot.errors.length, 5);
  assert.ok(snapshot.errors.every(error => error.length <= 500));
  assert.equal(h.state.clicks, 0);
});

test('a page error wins over a result rather than producing a false pass', () => {
  const h = harness({ corrected: 'Wouldn’t this make it harder to maintain?' });
  h.listeners.get('error')({ message: 'Script failed' });
  assert.equal(h.probe().phase, 'error');
});

test('diagnostics do not read editor or source content and bound alert/result text', () => {
  const h = harness({ alert: 'a'.repeat(2_000), corrected: 'b'.repeat(2_000) });
  const snapshot = h.probe();
  assert.equal(snapshot.alert.length, 500);
  assert.equal(snapshot.corrected.length, 200);
  assert.deepEqual(Object.keys(snapshot), ['phase', 'clicked', 'ready', 'state', 'corrected',
    'alert', 'errors', 'documentState', 'buttonPresent', 'buttonDisabled']);
});
