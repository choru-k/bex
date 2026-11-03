/* Cloud-only React/JSDOM UI lifecycle. Extraction itself is independently tested with actual parsers. */
const fs = require('node:fs'); const path = require('node:path'); const assert = require('node:assert/strict');
const Module = require('node:module'); const harness = Module.createRequire(path.resolve(process.env.BEX_NODE_HARNESS || '/tmp/bex-native-node-harness', 'package.json'));
const ts = harness('typescript');
for (const extension of ['.ts', '.tsx']) require.extensions[extension] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
}).outputText, file);
require.extensions['.css'] = () => {};
const { JSDOM } = harness('jsdom'); const dom = new JSDOM('<html><body></body></html>', { url: 'http://127.0.0.1' });
for (const key of ['window', 'document', 'HTMLElement', 'Event']) global[key] = dom.window[key];
Object.defineProperty(global, 'navigator', { value: dom.window.navigator, configurable: true }); global.IS_REACT_ACT_ENVIRONMENT = true;
const React = require('react'); const { act } = React; const { createRoot } = require('react-dom/client');
const pending = []; const originalLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request === './documents/importDocument.ts') return { importStudyDocument(file, signal) { return new Promise((resolve, reject) => pending.push({ file, signal, resolve, reject })); } };
  return originalLoad.call(this, request, parent, isMain);
};
const { StudyDocumentImport } = require('../src/study/StudyDocumentImport.tsx');
const { StudyMaterialsPanel } = require('../src/study/StudyMaterialsPanel.tsx'); Module._load = originalLoad;
const { indexStudyDocument } = require('../src/study/documents/documentModel.ts');
const synthetic = text => indexStudyDocument({ format: 'pdf', suggestedTitle: 'Synthetic book', warnings: [], units: [{ label: 'PDF 파일 페이지 1', text }] });
async function mount(props = {}) {
  const target = document.createElement('div'); document.body.append(target); const root = createRoot(target); const changes = [];
  await act(async () => root.render(React.createElement(React.StrictMode, null, React.createElement(StudyMaterialsPanel, { DocumentImport: StudyDocumentImport, onSourceChange: next => changes.push(next), ...props }))));
  return { target, changes, async unmount() { await act(async () => root.unmount()); target.remove(); } };
}
async function click(view, label) { const button = [...view.target.querySelectorAll('button')].find(item => (item.getAttribute('aria-label') || item.textContent) === label); assert.ok(button, label); assert.equal(button.disabled, false); await act(async () => button.click()); }
async function input(view, selector, value) {
  const field = view.target.querySelector(selector); assert.ok(field);
  await act(async () => { Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value').set.call(field, value); field.dispatchEvent(new Event('input', { bubbles: true })); });
}
async function choose(view, name) { const file = view.target.querySelector('[type=file]'); Object.defineProperty(file, 'files', { value: [{ name }], configurable: true }); await act(async () => file.dispatchEvent(new Event('change', { bubbles: true }))); return pending.at(-1); }
async function loaded(view, text = 'Synthetic vocabulary practice.') { const request = await choose(view, 'synthetic.pdf'); await act(async () => request.resolve(synthetic(text))); return request; }
let count = 0; async function scenario(name, run) { await run(); count++; console.log('PASS ' + name); }
(async () => {
  await scenario('native does not mount import controls or call parser', async () => { const before = pending.length; const view = await mount({ mode: 'native' }); assert.equal(view.target.querySelector('[type=file]'), null); assert.equal(pending.length, before); await view.unmount(); });
  await scenario('file choice alone never selects, persists, or submits a source; explicit passage add remains inactive', async () => {
    const view = await mount(); await loaded(view); assert.equal(view.changes.length, 0); assert.equal(localStorageCount(), 0);
    await input(view, '#study-document-query', 'vocabulary'); await click(view, '문서 안에서 찾기');
    await click(view, '이 발췌문을 자료에 추가'); assert.equal(view.changes.length, 0); assert.equal(view.target.querySelectorAll('[type=radio]').length, 1);
    await click(view, '이 발췌문을 자료에 추가'); assert.equal(view.target.querySelectorAll('[type=radio]').length, 1, 'repeated add is idempotent');
    await act(async () => view.target.querySelector('[type=radio]').click()); assert.equal(view.changes.at(-1).excerpt, 'Synthetic vocabulary practice.');
    assert.equal(localStorageCount(), 0); await view.unmount();
  });
  await scenario('cancel retains one admission slot until ignored-abort extraction settles; new files cannot accumulate', async () => {
    const view = await mount(); const first = await choose(view, 'first.pdf'); const countBefore = pending.length;
    await click(view, '문서 읽기 취소'); assert.equal(first.signal.aborted, true);
    assert.equal(view.target.querySelector('[type=file]').disabled, true);
    await choose(view, 'second.epub'); await choose(view, 'third.pdf'); assert.equal(pending.length, countBefore);
    await act(async () => first.resolve(synthetic('Stale private content.'))); assert.equal(view.target.querySelector('#import-document-title'), null);
    assert.equal(view.target.querySelector('[type=file]').disabled, false);
    const second = await choose(view, 'second.epub'); await act(async () => second.resolve(synthetic('Current private content.')));
    await input(view, '#study-document-query', 'current'); await click(view, '문서 안에서 찾기');
    assert.ok(view.target.textContent.includes('Current private content.')); assert.equal(view.target.textContent.includes('Stale private content.'), false); await view.unmount();
  });
  await scenario('cancel and unmount abort actual extraction signals and discard late completion', async () => {
    const view = await mount(); const first = await choose(view, 'first.pdf'); await click(view, '문서 읽기 취소'); assert.equal(first.signal.aborted, true);
    await act(async () => first.resolve(synthetic('Stale.'))); assert.equal(view.target.querySelector('#import-document-title'), null);
    const second = await choose(view, 'second.pdf'); await view.unmount(); assert.equal(second.signal.aborted, true); await act(async () => second.resolve(synthetic('Late.')));
  });
  await scenario('new query clears stale matches; no-match query invents no result; close drops document but retains saved passage', async () => {
    const view = await mount(); await loaded(view); await input(view, '#study-document-query', 'vocabulary'); await click(view, '문서 안에서 찾기'); await click(view, '이 발췌문을 자료에 추가');
    await input(view, '#study-document-query', 'unmatched'); assert.equal(view.target.querySelector('.study-import .study-excerpt'), null); await click(view, '문서 안에서 찾기'); assert.match(view.target.textContent, /일치하는 발췌문이 없습니다/);
    await click(view, '불러온 문서 닫기'); assert.equal(view.target.querySelector('#import-document-title'), null); assert.equal(view.target.querySelectorAll('[type=radio]').length, 1); await view.unmount();
  });
  await scenario('parser errors do not preserve old results and malicious extracted content stays text', async () => {
    const view = await mount(); await loaded(view, '<img src="https://invalid.example"> vocabulary <script>evil()</script>'); await input(view, '#study-document-query', 'vocabulary'); await click(view, '문서 안에서 찾기');
    assert.equal(view.target.querySelector('img'), null); assert.equal(view.target.querySelector('script'), null); assert.equal(window.evil, undefined);
    const next = await choose(view, 'broken.pdf'); await act(async () => next.reject(new Error('문서를 읽지 못했습니다.')));
    assert.equal(view.target.querySelector('.study-import .study-excerpt'), null); assert.match(view.target.querySelector('[role=alert]').textContent, /읽지 못/); await view.unmount();
  });
  console.log(`${count} study-document UI lifecycle scenarios passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
function localStorageCount() { return dom.window.localStorage.length; }
