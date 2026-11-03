/* Personalization React/JSDOM lifecycle coverage; not browser or native runtime proof.
 * BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/personalization.node.cjs
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
require.extensions['.css'] = () => {};
const { JSDOM } = harnessRequire('jsdom');
const dom = new JSDOM('<html><body></body></html>', { url: 'http://127.0.0.1:5179' });
for (const key of ['window', 'document', 'HTMLElement', 'Event', 'MutationObserver']) global[key] = dom.window[key];
Object.defineProperty(global, 'navigator', { value: dom.window.navigator, configurable: true });
global.IS_REACT_ACT_ENVIRONMENT = true;
const React = require('react'); const { act } = React; const { createRoot } = require('react-dom/client');
const { App } = require(path.resolve(__dirname, '../src/App.tsx'));
const { PersonalizationControls, policyForTransport } = require(path.resolve(__dirname, '../src/learning/PersonalizationControls.tsx'));
const { NativeApp } = require(path.resolve(__dirname, '../src/NativeApp.tsx'));
const { FixtureTransport } = require(path.resolve(__dirname, '../src/core/fixtures.ts'));
const { DEFAULT_POLICY } = require(path.resolve(__dirname, '../src/core/model.ts'));
const original = 'Wouldn’t this makes it harder to maintain?';
const corrected = 'Wouldn’t this make it harder to maintain?';
let checks = 0;
async function mount(component = App, props = {}) {
  const target = document.createElement('div'); document.body.append(target); const root = createRoot(target);
  const render = () => root.render(React.createElement(React.StrictMode, null, React.createElement(component, props)));
  await act(async () => render());
  return { target, async update(next) { Object.assign(props, next); await act(async () => render()); },
    async unmount() { await act(async () => root.unmount()); target.remove(); } };
}
function button(view, label) { return [...view.target.querySelectorAll('button')].find(item => (item.getAttribute('aria-label') || item.textContent) === label); }
async function click(view, label) {
  const item = button(view, label); assert.ok(item, label); assert.equal(item.disabled, false, label + ' enabled');
  await act(async () => item.click());
}
async function input(view, selector, value) {
  const field = view.target.querySelector(selector); assert.ok(field, selector);
  const prototype = field.tagName === 'TEXTAREA' ? dom.window.HTMLTextAreaElement.prototype : dom.window.HTMLInputElement.prototype;
  await act(async () => { Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, value); field.dispatchEvent(new Event('input', { bubbles: true })); });
}
async function select(view, selector, value) {
  const field = view.target.querySelector(selector); assert.ok(field, selector);
  await act(async () => { field.value = value; field.dispatchEvent(new Event('change', { bubbles: true })); });
}
async function toggle(view, selector) { const field = view.target.querySelector(selector); assert.ok(field); await act(async () => field.click()); }
const waitFixture = () => act(async () => { await new Promise(resolve => setTimeout(resolve, 270)); });
const result = view => view.target.querySelector('[data-testid="corrected"]');
async function scenario(name, run) { await run(); checks++; console.log('PASS ' + name); }
async function checkSample(view) { await click(view, '샘플 피드백 보기↗'); await waitFixture(); }
function endpoint(languages) {
  const listeners = new Set(); const sent = [];
  return { sent, postMessage(json) { sent.push(JSON.parse(json)); },
    subscribe(listener) { listeners.add(listener); return () => listeners.delete(listener); },
    reply(message, value) { for (const listener of listeners) listener(JSON.stringify({ bridgeVersion: 1, sessionID: message.sessionID, requestID: message.requestID, ...value })); },
    hello() { this.reply(sent.find(item => item.kind === 'hello'), { kind: 'capabilities', capabilities: { providerName: 'Synthetic provider', perRequestConsent: true, operations: ['correct','cancel'], ...(languages === undefined ? {} : { explanationLanguages: languages }) } }); } };
}
(async () => {
  await scenario('fixture controls produce visible vocabulary variants and selected explanation language', async () => {
    const view = await mount(); await select(view, '#notes', '2');
    await select(view, '#vocabulary', 'wide'); await select(view, '#explanation-language', 'en'); await checkSample(view);
    assert.equal(result(view).textContent, corrected); assert.match(view.target.textContent, /more demanding to maintain/);
    assert.match(view.target.textContent, /Use the base verb after would/);
    await select(view, '#vocabulary', 'familiar'); await select(view, '#explanation-language', 'ko');
    assert.equal(result(view), null); await checkSample(view);
    assert.match(view.target.textContent, /more work to maintain/); assert.match(view.target.textContent, /조동사 would 뒤에는/); await view.unmount();
  });
  await scenario('necessary-only control removes optional alternatives without weakening the correction', async () => {
    const view = await mount(); await select(view, '#notes', '2'); await select(view, '#restraint', 'necessary-only'); await checkSample(view);
    assert.equal(result(view).textContent, corrected); assert.equal(view.target.querySelector('.note-kind.alternative'), null);
    assert.equal(view.target.querySelectorAll('.feedback-note').length, 1);
    await select(view, '#scenario', 'correct'); await checkSample(view);
    assert.equal(result(view).textContent, 'Could we keep the implementation simple?'); assert.equal(view.target.querySelectorAll('.feedback-note').length, 0); await view.unmount();
  });
  await scenario('language and restraint changes cancel pending results instead of relabelling old explanations', async () => {
    const view = await mount(); await click(view, '샘플 피드백 보기↗'); await select(view, '#explanation-language', 'en'); await waitFixture();
    assert.equal(result(view), null); await click(view, '샘플 피드백 보기↗'); await select(view, '#restraint', 'necessary-only'); await waitFixture();
    assert.equal(result(view), null); assert.equal(view.target.querySelector('#editor').value, original); await view.unmount();
  });
  await scenario('only opt-in saves personalization and reset returns to capability-aware defaults', async () => {
    dom.window.localStorage.clear(); const view = await mount(); await select(view, '#explanation-language', 'en');
    assert.equal(dom.window.localStorage.length, 0);
    const remember = [...view.target.querySelectorAll('label')].find(item => item.textContent === '학습 설정만 이 기기에 기억').querySelector('input');
    await act(async () => remember.click());
    assert.equal(JSON.parse(dom.window.localStorage.getItem('bex.web-lab.policy.v1')).explanationLanguage, 'en');
    await click(view, '이 실험실 초기화'); assert.equal(view.target.querySelector('#explanation-language').value, 'ko');
    assert.equal(dom.window.localStorage.getItem('bex.web-lab.policy.v1'), null); await view.unmount();
  });
  await scenario('legacy native handshake shows provider-default and dispatches only old four-field policy', async () => {
    dom.window.localStorage.setItem('bex.web-lab.policy.v1', JSON.stringify({ ...DEFAULT_POLICY, explanationLanguage: 'en' }));
    const host = endpoint(); window.__bexNativeCorrectionEndpoint = host;
    const view = await mount(NativeApp, {}); await click(view, 'Connect native'); await act(async () => host.hello());
    const language = view.target.querySelector('#explanation-language'); assert.equal(language.disabled, true); assert.equal(language.value, 'provider-default');
    assert.match(language.textContent, /제공자 기본 언어/); assert.equal(host.sent.length, 1);
    await input(view, '#editor', 'The tests passes.'); await click(view, '동의 후 교정 요청↗');
    const request = host.sent.find(item => item.kind === 'correct').request;
    assert.equal('explanationLanguage' in request.policy, false); assert.equal(request.text, 'The tests passes.'); await view.unmount();
    dom.window.localStorage.clear();
  });
  await scenario('capable native host receives explicit language only after user correction request', async () => {
    const host = endpoint(['ko','en']); window.__bexNativeCorrectionEndpoint = host;
    const view = await mount(NativeApp, {}); await click(view, 'Connect native'); await act(async () => host.hello());
    assert.equal(view.target.querySelector('#explanation-language').disabled, false); assert.equal(view.target.querySelector('#explanation-language').value, 'ko');
    await select(view, '#explanation-language', 'en'); await select(view, '#restraint', 'necessary-only');
    assert.equal(host.sent.length, 1, 'changing settings must not submit text');
    await input(view, '#editor', 'The tests passes.'); await click(view, '동의 후 교정 요청↗');
    const request = host.sent.find(item => item.kind === 'correct').request;
    assert.equal(request.policy.explanationLanguage, 'en'); assert.equal(request.policy.alternatives, false); await view.unmount();
  });
  await scenario('one-language capability exposes only that choice and no silent saved-language upgrade', async () => {
    const host = endpoint(['en']); window.__bexNativeCorrectionEndpoint = host;
    const view = await mount(NativeApp, {}); await click(view, 'Connect native'); await act(async () => host.hello());
    const language = view.target.querySelector('#explanation-language'); assert.equal(language.options.length, 1); assert.equal(language.value, 'en');
    assert.equal(host.sent.length, 1); await view.unmount();
  });
  await scenario('capability-aware policy initialization does not mutate preferences or serialize unsupported language', async () => {
    const saved = { ...DEFAULT_POLICY, explanationLanguage: 'en' }; const before = structuredClone(saved);
    assert.equal(policyForTransport(saved, { kind: 'native' }).explanationLanguage, undefined);
    assert.equal(policyForTransport(saved, { kind: 'native', explanationLanguages: ['ko'] }).explanationLanguage, 'ko');
    assert.equal(policyForTransport(DEFAULT_POLICY, new FixtureTransport()).explanationLanguage, 'ko');
    assert.deepEqual(saved, before);
  });
  console.log(`${checks} personalization React scenarios passed (JSDOM; no browser/native runtime).`);
})().catch(error => { console.error(error); process.exitCode = 1; });
