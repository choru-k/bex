/* Cloud-only React/JSDOM harness. Supply a separate TypeScript 5.x + jsdom harness; no app dependency changes.
 * BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/native-renderer.node.cjs
 * This exercises JS lifecycle, not WebKit, AppKit, consent UI, or real providers.
 */
const fs = require('node:fs');
const assert = require('node:assert/strict');
const path = require('node:path');
const harnessRequire = require('node:module').createRequire(path.resolve(process.env.BEX_NODE_HARNESS || '/tmp/bex-native-node-harness', 'package.json'));
const ts = harnessRequire('typescript');
for (const extension of ['.ts', '.tsx']) require.extensions[extension] = (module, file) => {
  module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
  }).outputText, file);
};
const { JSDOM } = harnessRequire('jsdom');
const dom = new JSDOM('<html><body></body></html>', { url: 'http://127.0.0.1:5179' });
for (const key of ['window', 'document', 'HTMLElement', 'Event', 'MutationObserver']) global[key] = dom.window[key];
Object.defineProperty(global, 'navigator', { value: dom.window.navigator, configurable: true });
global.IS_REACT_ACT_ENVIRONMENT = true;
const React = require('react');
const { act } = React;
const { createRoot } = require('react-dom/client');
const { NativeApp } = require(path.resolve(__dirname, '../src/NativeApp.tsx'));
let checks = 0;
function endpoint() {
  const listeners = new Set();
  const allListeners = [];
  const sent = [];
  return {
    sent, listeners,
    postMessage(json) { sent.push(JSON.parse(json)); },
    subscribe(listener) { listeners.add(listener); allListeners.push(listener); return () => listeners.delete(listener); },
    reply(request, value, late = false) {
      const json = JSON.stringify({ bridgeVersion: 1, sessionID: request.sessionID, requestID: request.requestID, ...value });
      for (const listener of late ? allListeners : listeners) listener(json);
    },
    hello(value = {}) { this.reply(sent.find(item => item.kind === 'hello'), { kind: 'capabilities', capabilities: { providerName: 'Test provider', perRequestConsent: true, operations: ['correct', 'cancel'], ...value } }); },
  };
}
async function mount(host) {
  window.__bexNativeCorrectionEndpoint = host;
  const target = document.createElement('div'); document.body.append(target);
  const root = createRoot(target);
  await act(async () => root.render(React.createElement(React.StrictMode, null, React.createElement(NativeApp))));
  return { target, root, async unmount() { await act(async () => root.unmount()); target.remove(); } };
}
async function click(target, label) {
  const button = [...target.querySelectorAll('button')].find(item => item.textContent.includes(label));
  assert.ok(button, label); await act(async () => button.click());
}
async function input(target, selector, value) {
  const field = target.querySelector(selector); assert.ok(field, selector);
  const prototype = field.tagName === 'TEXTAREA' ? dom.window.HTMLTextAreaElement.prototype : dom.window.HTMLInputElement.prototype;
  await act(async () => { Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, value); field.dispatchEvent(new Event('input', { bubbles: true })); });
}
const phase = target => target.querySelector('[data-native-phase]').dataset.nativePhase;
async function scenario(name, run) { await run(); checks++; console.log('PASS ' + name); }
(async () => {
  await scenario('initial-commit click is gated until effects are ready', async () => {
    const host = endpoint(); window.__bexNativeCorrectionEndpoint = host;
    const target = document.createElement('div'); document.body.append(target);
    let initial;
    const observer = new MutationObserver(() => {
      const button = target.querySelector('button');
      if (!button || initial) return;
      initial = { disabled: button.disabled, ready: target.querySelector('[data-native-ready]').dataset.nativeReady };
      button.click(); observer.disconnect();
    });
    observer.observe(target, { childList: true, subtree: true });
    const root = createRoot(target);
    global.IS_REACT_ACT_ENVIRONMENT = false;
    try {
      root.render(React.createElement(React.StrictMode, null, React.createElement(NativeApp)));
      const deadline = Date.now() + 5000;
      while (!initial || target.querySelector('[data-native-ready]')?.dataset.nativeReady !== 'true') {
        if (Date.now() > deadline) throw new Error('Native readiness timed out');
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      assert.deepEqual(initial, { disabled: true, ready: 'false' });
      assert.equal(host.sent.length, 0);
    } finally { global.IS_REACT_ACT_ENVIRONMENT = true; observer.disconnect(); }
    await act(async () => root.unmount()); target.remove();
  });
  await scenario('no endpoint fails closed without fixture editor', async () => {
    const view = await mount(undefined);
    assert.equal(phase(view.target), 'idle');
    await click(view.target, 'Connect native');
    assert.equal(phase(view.target), 'closed'); assert.equal(view.target.querySelector('#editor'), null);
    assert.equal([...view.target.querySelectorAll('button')].length, 0);
    await view.unmount();
  });
  await scenario('explicit single hello, accurate labels, correction cancel and disconnect', async () => {
    const host = endpoint(); const view = await mount(host);
    assert.equal(host.sent.length, 0); assert.equal(host.listeners.size, 0);
    assert.equal(view.target.querySelector('#editor'), null);
    const connect = view.target.querySelector('button');
    await act(async () => { connect.click(); connect.click(); });
    assert.equal(host.sent.length, 1);
    assert.deepEqual(Object.keys(host.sent[0]).sort(), ['bridgeVersion', 'kind', 'requestID', 'sessionID']);
    assert.equal(host.sent[0].kind, 'hello');
    await act(async () => host.hello());
    assert.equal(phase(view.target), 'connected'); assert.equal(host.sent.length, 1);
    assert.equal(view.target.querySelector('#editor').value, '');
    assert.ok(!view.target.textContent.includes('학습 설정만 이 기기에 기억'));
    const beforeURL = window.location.href;
    await act(async () => view.target.querySelector('.brand').click());
    assert.equal(window.location.href, beforeURL);
    assert.equal(document.activeElement.id, 'editor');
    assert.match(view.target.textContent, /Test provider/);
    for (const misleading of ['샘플 모드', 'AI 미연결', '샘플 결과', '전송 없이 검토', '로컬 전용', '외부로 전송하지 않습니다', '현재는 전송하지 않습니다']) assert.ok(!view.target.textContent.includes(misleading), misleading);
    await input(view.target, '#editor', 'The tests passes.');
    await click(view.target, '동의 후 교정 요청');
    const first = host.sent.find(item => item.kind === 'correct'); assert.equal(first.request.text, 'The tests passes.');
    await click(view.target, '취소');
    assert.ok(host.sent.some(item => item.kind === 'cancel' && item.requestID === first.requestID));
    await act(async () => host.reply(first, { kind: 'result', result: { protocolVersion: 1, original: first.request.text, corrected: 'The tests pass.', notes: [], provenance: 'provider' } }));
    assert.equal(view.target.querySelector('[data-testid=corrected]'), null);
    await click(view.target, '동의 후 교정 요청');
    const second = host.sent.filter(item => item.kind === 'correct')[1];
    await act(async () => host.reply(second, { kind: 'error', code: 'consent-denied' }));
    assert.match(view.target.textContent, /Native consent was not granted/);
    assert.equal(view.target.querySelector('[data-testid=corrected]'), null);
    await click(view.target, '동의 후 교정 요청');
    const third = host.sent.filter(item => item.kind === 'correct')[2];
    await click(view.target, '연결 종료');
    assert.equal(phase(view.target), 'closed'); assert.equal(host.listeners.size, 0);
    assert.equal(view.target.querySelector('#editor'), null);
    assert.ok(host.sent.some(item => item.kind === 'cancel' && item.requestID === third.requestID));
    await act(async () => host.reply(third, { kind: 'result', result: { protocolVersion: 1, original: third.request.text, corrected: 'The tests pass.', notes: [], provenance: 'provider' } }, true));
    assert.equal(view.target.querySelector('[data-testid=corrected]'), null);
    await view.unmount();
  });
  await scenario('source disclosure, provider result and unmount cancel active correction', async () => {
    const host = endpoint(); const view = await mount(host);
    await click(view.target, 'Connect native'); await act(async () => host.hello());
    await input(view.target, '#editor', 'The tests passes.');
    await act(async () => view.target.querySelector('.source-toggle input').click());
    await input(view.target, '#source-title', 'Synthetic source');
    await input(view.target, '#source-section', 'Unit 1');
    await input(view.target, '#source-excerpt', 'Synthetic excerpt for testing only.');
    assert.match(view.target.textContent, /자료 제목·단원·발췌문도 원문과 함께 호스트로 전달/);
    await click(view.target, '동의 후 교정 요청');
    const request = host.sent.find(item => item.kind === 'correct');
    assert.deepEqual(request.request.source, { title: 'Synthetic source', section: 'Unit 1', excerpt: 'Synthetic excerpt for testing only.' });
    await act(async () => host.reply(request, { kind: 'result', result: { protocolVersion: 1, original: request.request.text, corrected: 'The tests pass.', notes: [], provenance: 'provider' } }));
    assert.equal(view.target.querySelector('[data-testid=corrected]').textContent, 'The tests pass.');
    assert.match(view.target.querySelector('.tag').textContent, /Test provider 결과/);
    await click(view.target, '동의 후 교정 요청');
    const active = host.sent.filter(item => item.kind === 'correct').at(-1);
    await view.unmount();
    assert.equal(host.listeners.size, 0);
    assert.ok(host.sent.some(item => item.kind === 'cancel' && item.requestID === active.requestID));
  });
  await scenario('cancelled handshake is terminal and stale capability cannot mount editor', async () => {
    const host = endpoint(); const view = await mount(host);
    await click(view.target, 'Connect native'); await click(view.target, '연결 취소');
    await act(async () => host.reply(host.sent[0], { kind: 'capabilities', capabilities: { providerName: 'Late', perRequestConsent: true, operations: ['correct', 'cancel'] } }, true));
    assert.equal(phase(view.target), 'closed'); assert.equal(view.target.querySelector('#editor'), null);
    assert.equal(host.listeners.size, 0); assert.equal(host.sent.filter(item => item.kind === 'hello').length, 1);
    await view.unmount();
  });
  await scenario('invalid capability fails closed and cannot reconnect', async () => {
    const host = endpoint(); const view = await mount(host);
    await click(view.target, 'Connect native'); await act(async () => host.hello({ perRequestConsent: false }));
    assert.equal(phase(view.target), 'closed'); assert.equal(host.listeners.size, 0);
    assert.equal(view.target.querySelector('#editor'), null); assert.equal(view.target.querySelector('button'), null);
    await view.unmount();
  });
  await scenario('unmount cancels pending handshake and unsubscribes', async () => {
    const host = endpoint(); const view = await mount(host);
    await click(view.target, 'Connect native'); await view.unmount();
    assert.equal(host.listeners.size, 0); assert.equal(host.sent.at(-1).kind, 'cancel');
    host.reply(host.sent[0], { kind: 'capabilities', capabilities: { providerName: 'Late', perRequestConsent: true, operations: ['correct', 'cancel'] } }, true);
    assert.equal(view.target.querySelector('#editor'), null);
  });
  await scenario('handshake deadline is terminal without fallback', async () => {
    const host = endpoint(); const view = await mount(host); const originalTimer = global.setTimeout;
    let expire;
    global.setTimeout = (callback, delay, ...args) => {
      if (delay === 30_000) { expire = callback; return originalTimer(() => {}, 60_000); }
      return originalTimer(callback, delay, ...args);
    };
    try { await click(view.target, 'Connect native'); await act(async () => expire()); }
    finally { global.setTimeout = originalTimer; }
    assert.equal(phase(view.target), 'closed'); assert.equal(view.target.querySelector('#editor'), null); assert.equal(host.listeners.size, 0);
    await view.unmount();
  });
  console.log(`SUMMARY: ${checks} lifecycle scenarios passed (React/JSDOM, no browser/native runtime).`);
  dom.window.close();
})().catch(error => { console.error(error); process.exitCode = 1; dom.window.close(); });
