/* React/JSDOM lifecycle coverage. Not browser, accessibility-tree or WKWebView proof.
 * BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/host-flow.node.cjs
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
const { HostFlowLab } = require(path.resolve(__dirname, '../src/host/HostFlowLab.tsx'));
const { DEFAULT_POLICY } = require(path.resolve(__dirname, '../src/core/model.ts'));
const original = 'Wouldn’t this makes it harder to maintain?';
const corrected = 'Wouldn’t this make it harder to maintain?';
let checks = 0;
async function mount(component = HostFlowLab, props = { policy: { ...DEFAULT_POLICY } }) {
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
const transcript = view => view.target.querySelector('[data-testid="host-transcript"]').textContent;
const review = view => view.target.querySelector('[data-testid="host-review-corrected"]');
const feedback = view => view.target.querySelector('[data-testid="host-feedback-card"]');
const waitResult = () => act(async () => { await new Promise(resolve => setTimeout(resolve, 760)); });
async function scenario(name, run) { await run(); checks++; console.log('PASS ' + name); }
(async () => {
  await scenario('StrictMode sends exact original first, continues typing and never overwrites transcript', async () => {
    const view = await mount(); await click(view, '원문 모의 전송');
    assert.match(transcript(view), /Wouldn’t this makes/); assert.equal(view.target.querySelector('#host-draft').value, '');
    assert.match(feedback(view).textContent, /피드백 준비 중/);
    await input(view, '#host-draft', 'next draft'); await waitResult();
    assert.match(feedback(view).textContent, /Wouldn’t this make it/); assert.ok(!transcript(view).includes(corrected));
    assert.equal(view.target.querySelector('#host-draft').value, 'next draft'); await view.unmount();
  });
  await scenario('free text sends successfully even when fixture coaching rejects it', async () => {
    const view = await mount(); await input(view, '#host-draft', 'Unseen free text.'); await click(view, '원문 모의 전송');
    await waitResult(); assert.match(transcript(view), /Unseen free text/); assert.match(feedback(view).textContent, /영향이 없습니다/); await view.unmount();
  });
  await scenario('review sends nothing until explicit confirmation and stale click cannot duplicate', async () => {
    const view = await mount(); await click(view, '보내기 전 검토'); await waitResult();
    assert.equal(review(view).textContent, corrected); assert.match(transcript(view), /아직 전송한/);
    const confirm = button(view, 'Fix & Send · 모의 전송 확인');
    await act(async () => { confirm.click(); confirm.click(); });
    assert.equal(view.target.querySelectorAll('[data-testid="host-transcript"] li').length, 1);
    assert.ok(transcript(view).includes(corrected)); assert.equal(feedback(view), null); await view.unmount();
  });
  await scenario('editing after preview removes send approval and preserves the new draft', async () => {
    const view = await mount(); await click(view, '보내기 전 검토'); await waitResult();
    await input(view, '#host-draft', 'changed'); assert.equal(review(view), null);
    assert.match(transcript(view), /아직 전송한/); assert.equal(view.target.querySelector('#host-draft').value, 'changed'); await view.unmount();
  });
  await scenario('app switch drops review, source identity survives subsequent app changes', async () => {
    const view = await mount(); await click(view, '보내기 전 검토'); await waitResult();
    await select(view, '#host-app', 'claude'); assert.equal(review(view), null);
    await click(view, '원문 모의 전송'); await select(view, '#host-app', 'other'); await waitResult();
    assert.match(feedback(view).textContent, /Claude/); assert.match(transcript(view), /Claude/); await view.unmount();
  });
  await scenario('cancel pending review and close preview both preserve unsent original', async () => {
    const view = await mount(); await click(view, '보내기 전 검토'); await click(view, '검토 취소');
    await waitResult(); assert.equal(review(view), null); assert.match(transcript(view), /아직 전송한/);
    await click(view, '보내기 전 검토'); await waitResult(); await click(view, '검토 닫기');
    assert.equal(review(view), null); assert.equal(view.target.querySelector('#host-draft').value, original); await view.unmount();
  });
  await scenario('ordinary send while review waits proceeds and cancels old approval', async () => {
    const view = await mount(); await click(view, '보내기 전 검토'); await click(view, '원문 모의 전송');
    await waitResult(); assert.equal(review(view), null); assert.ok(transcript(view).includes(original));
    assert.equal(view.target.querySelectorAll('[data-testid="host-transcript"] li').length, 1); await view.unmount();
  });
  await scenario('learning policy change invalidates ready review without touching conversation', async () => {
    const view = await mount(); await click(view, '보내기 전 검토'); await waitResult();
    await view.update({ policy: { ...DEFAULT_POLICY, maxNotes: 0 } }); assert.equal(review(view), null);
    assert.match(transcript(view), /아직 전송한/); await view.unmount();
  });
  await scenario('unmount clears private session state and no source text enters browser storage', async () => {
    dom.window.localStorage.clear(); dom.window.sessionStorage.clear();
    const view = await mount(); await click(view, '원문 모의 전송'); await view.unmount();
    await waitResult(); const next = await mount(); assert.match(transcript(next), /아직 전송한/); assert.equal(feedback(next), null);
    assert.equal(dom.window.localStorage.length, 0); assert.equal(dom.window.sessionStorage.length, 0); await next.unmount();
  });
  await scenario('browser App actually mounts both flow and study library; reset clears host transcript', async () => {
    const view = await mount(App, {}); assert.ok(view.target.querySelector('[data-testid="host-flow-lab"]'));
    assert.ok(button(view, '자료 추가')); await click(view, '원문 모의 전송'); await click(view, '이 실험실 초기화');
    assert.match(transcript(view), /아직 전송한/); assert.equal(feedback(view), null); await view.unmount();
  });
  await scenario('native App never mounts simulated host and never reads study or policy storage', async () => {
    const storagePrototype = dom.window.Storage.prototype; const originalGet = storagePrototype.getItem;
    let reads = 0; storagePrototype.getItem = function(...args) { reads++; return originalGet.apply(this, args); };
    try {
      const view = await mount(App, { transport: { kind: 'native', check() { throw new Error('No implicit provider calls'); } } });
      assert.equal(view.target.querySelector('[data-testid="host-flow-lab"]'), null); assert.ok(button(view, '자료 추가'));
      assert.equal(button(view, '기기 자료 불러오기'), undefined); assert.equal(reads, 0); await view.unmount();
    } finally { storagePrototype.getItem = originalGet; }
  });
  await scenario('App study selection populates request; manual source replacement and reset clear selected unit', async () => {
    const view = await mount(App, {}); await click(view, '자료 추가'); await input(view, '#study-title', 'Synthetic book'); await click(view, '수정 적용');
    await click(view, '단원 추가'); await input(view, '#study-section-label', 'Unit 1'); await input(view, '#study-section-excerpt', 'Synthetic excerpt'); await click(view, '수정 적용');
    await toggle(view, '[type=radio]'); assert.equal(view.target.querySelector('#source-title').value, 'Synthetic book');
    assert.match(view.target.querySelector('.developer-panel pre').textContent, /Synthetic excerpt/);
    await input(view, '#source-title', 'Manual source'); assert.equal(view.target.querySelector('[type=radio]').checked, false);
    await toggle(view, '[type=radio]'); await click(view, '이 실험실 초기화'); assert.equal(view.target.querySelector('[type=radio]').checked, false);
    assert.ok(!view.target.querySelector('.developer-panel pre').textContent.includes('Synthetic excerpt')); await view.unmount();
  });
  await scenario('App unselecting study source cancels a pending correction before late fixture result', async () => {
    const view = await mount(App, {}); await click(view, '자료 추가'); await input(view, '#study-title', 'Synthetic book'); await click(view, '수정 적용');
    await click(view, '단원 추가'); await input(view, '#study-section-label', 'Unit 1'); await input(view, '#study-section-excerpt', 'Synthetic excerpt'); await click(view, '수정 적용');
    await toggle(view, '[type=radio]'); await click(view, '샘플 피드백 보기↗'); await click(view, '참고 해제'); await waitResult();
    assert.equal(view.target.querySelector('[data-testid="corrected"]'), null); await view.unmount();
  });
  console.log(`${checks} React lifecycle scenarios passed (JSDOM, not browser/device verification).`);
})().catch(error => { console.error(error); process.exitCode = 1; });
