/* Cloud-only React/JSDOM lifecycle coverage, not browser/WKWebView visual verification.
 * BEX_NODE_HARNESS=/tmp/bex-native-node-harness node tests/study-materials.node.cjs
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
const React = require('react');
const { act } = React;
const { createRoot } = require('react-dom/client');
const { StudyMaterialsPanel } = require(path.resolve(__dirname, '../src/study/StudyMaterialsPanel.tsx'));
const { STUDY_STORAGE_KEY, addStudyMaterial, addStudySection, emptyStudyLibrary } = require(path.resolve(__dirname, '../src/core/studyMaterials.ts'));
const synthetic = () => addStudySection(addStudyMaterial(emptyStudyLibrary(), 'book-1', 'Synthetic book · Author'), 'book-1', { id: 'unit-1', label: 'Unit 1', excerpt: 'Synthetic excerpt.' });
let checks = 0;
function memoryStorage(initial) {
  const data = new Map(initial ? [[STUDY_STORAGE_KEY, JSON.stringify(initial)]] : []);
  const calls = [];
  return { data, calls, getItem(key) { calls.push(['get', key]); return data.get(key) ?? null; },
    setItem(key, value) { calls.push(['set', key]); data.set(key, value); }, removeItem(key) { calls.push(['remove', key]); data.delete(key); } };
}
async function mount(extra = {}) {
  const target = document.createElement('div'); document.body.append(target); const changes = [];
  const props = { storage: memoryStorage(), onSourceChange: source => changes.push(source), ...extra };
  const root = createRoot(target);
  const render = () => root.render(React.createElement(React.StrictMode, null, React.createElement(StudyMaterialsPanel, props)));
  await act(async () => render());
  return { target, root, props, changes, async render(next) { Object.assign(props, next); await act(async () => render()); },
    async unmount() { await act(async () => root.unmount()); target.remove(); } };
}
async function click(view, label) {
  const button = [...view.target.querySelectorAll('button')].find(item => (item.getAttribute('aria-label') || item.textContent) === label);
  assert.ok(button, label); assert.equal(button.disabled, false, label + ' enabled');
  await act(async () => button.click());
}
async function input(view, selector, value) {
  const field = view.target.querySelector(selector); assert.ok(field, selector);
  const prototype = field.tagName === 'TEXTAREA' ? dom.window.HTMLTextAreaElement.prototype : dom.window.HTMLInputElement.prototype;
  await act(async () => { Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, value); field.dispatchEvent(new Event('input', { bubbles: true })); });
}
async function toggle(view, selector) {
  const field = view.target.querySelector(selector); assert.ok(field, selector); await act(async () => field.click());
}
async function addBook(view, title = 'Synthetic book · Author') {
  await click(view, '자료 추가'); await input(view, '#study-title', title); await click(view, '수정 적용');
}
async function addSection(view, label = 'Unit 1', excerpt = 'Synthetic excerpt.') {
  await click(view, '단원 추가'); await input(view, '#study-section-label', label); await input(view, '#study-section-excerpt', excerpt); await click(view, '수정 적용');
}
async function select(view, index = 0) {
  const field = view.target.querySelectorAll('[type=radio]')[index]; assert.ok(field); await act(async () => field.click());
}
const active = view => view.target.querySelector('[aria-label="활성 학습 단원"]').textContent;
async function scenario(name, run) { await run(); checks++; console.log('PASS ' + name); }
(async () => {
  await scenario('mount and all manual add/edit operations are storage-free and selection-free by default', async () => {
    const view = await mount(); assert.deepEqual(view.props.storage.calls, []); assert.deepEqual(view.changes, []);
    await addBook(view); await addSection(view); assert.deepEqual(view.props.storage.calls, []); assert.deepEqual(view.changes, []);
    assert.match(active(view), /활성 단원 없음/); assert.match(view.target.textContent, /PDF·EPUB/);
    await view.unmount(); assert.deepEqual(view.props.storage.calls, []);
  });
  await scenario('selection emits exactly one attributed section and changing active content replaces the snapshot', async () => {
    const view = await mount(); await addBook(view); await addSection(view); await addSection(view, 'Unit 2', 'Second excerpt.');
    await select(view); assert.deepEqual(view.changes, [{ title: 'Synthetic book · Author', section: 'Unit 1', excerpt: 'Synthetic excerpt.' }]);
    await click(view, 'Unit 1 수정'); await input(view, '#study-section-excerpt', 'Revised excerpt.');
    assert.equal(view.changes.length, 1, 'draft edits do not change request source');
    assert.equal(view.target.querySelector('#study-material-picker').disabled, true);
    await click(view, '수정 적용'); assert.equal(view.changes.at(-1).excerpt, 'Revised excerpt.');
    await click(view, '자료 제목 수정'); await input(view, '#study-title', 'Revised title · Author'); await click(view, '수정 적용');
    assert.equal(view.changes.at(-1).title, 'Revised title · Author');
    await select(view, 1); assert.equal(view.changes.at(-1).section, 'Unit 2');
    await click(view, '참고 해제'); assert.equal(view.changes.at(-1), null); assert.match(active(view), /없음/);
    await view.unmount();
  });
  await scenario('editing another section does not invalidate the unchanged active source', async () => {
    const view = await mount(); await addBook(view); await addSection(view); await addSection(view, 'Unit 2', 'Other.'); await select(view);
    await click(view, 'Unit 2 수정'); await input(view, '#study-section-excerpt', 'Changed other.'); await click(view, '수정 적용');
    assert.equal(view.changes.length, 1); await view.unmount();
  });
  await scenario('delete confirmation supports cancellation, clears active source, and never chooses another', async () => {
    const view = await mount(); await addBook(view); await addSection(view); await select(view);
    await click(view, 'Unit 1 삭제'); await click(view, '삭제 취소'); assert.equal(view.changes.length, 1);
    assert.equal(view.target.querySelectorAll('[type=radio]').length, 1);
    await click(view, 'Unit 1 삭제'); await click(view, '삭제 확인'); assert.equal(view.changes.at(-1), null);
    await addSection(view); await select(view); await click(view, '자료 삭제'); await click(view, '삭제 확인');
    assert.equal(view.changes.at(-1), null); assert.equal(view.target.querySelector('#study-material-picker'), null);
    await view.unmount();
  });
  await scenario('cancel keeps saved section unchanged and repeated apply does not create duplicates', async () => {
    const view = await mount(); await addBook(view); await addSection(view); await select(view);
    await click(view, 'Unit 1 수정'); await input(view, '#study-section-excerpt', 'Discard me.'); await click(view, '편집 취소');
    assert.equal(view.changes.at(-1).excerpt, 'Synthetic excerpt.');
    await click(view, '단원 추가'); await input(view, '#study-section-label', 'Unit 2'); await input(view, '#study-section-excerpt', 'Second.');
    const apply = [...view.target.querySelectorAll('button')].find(button => button.textContent === '수정 적용');
    await act(async () => { apply.click(); apply.click(); });
    assert.equal(view.target.querySelectorAll('[type=radio]').length, 2); await view.unmount();
  });
  await scenario('invalid edits stay open, preserve the original, and display a bounded error', async () => {
    const view = await mount(); await addBook(view); await addSection(view); await select(view);
    await click(view, 'Unit 1 수정'); await input(view, '#study-section-excerpt', '  '); await click(view, '수정 적용');
    assert.ok(view.target.querySelector('#study-section-excerpt')); assert.ok(view.target.querySelector('[role=alert]'));
    assert.equal(view.changes.length, 1); assert.equal(view.changes.at(-1).excerpt, 'Synthetic excerpt.'); await view.unmount();
  });
  await scenario('storage opt-in persists only material data and unchecking removes only its key', async () => {
    const view = await mount(); view.props.storage.data.set('other-key', 'preserved');
    await addBook(view); await addSection(view); await select(view);
    await toggle(view, '[type=checkbox]');
    const saved = JSON.parse(view.props.storage.data.get(STUDY_STORAGE_KEY));
    assert.deepEqual(Object.keys(saved), ['version', 'materials']); assert.equal(saved.materials[0].sections[0].excerpt, 'Synthetic excerpt.');
    await click(view, 'Unit 1 수정'); await input(view, '#study-section-excerpt', 'Saved revision.'); await click(view, '수정 적용');
    assert.equal(JSON.parse(view.props.storage.data.get(STUDY_STORAGE_KEY)).materials[0].sections[0].excerpt, 'Saved revision.');
    await toggle(view, '[type=checkbox]'); assert.equal(view.props.storage.data.has(STUDY_STORAGE_KEY), false);
    assert.equal(view.props.storage.data.get('other-key'), 'preserved'); assert.equal(view.target.querySelectorAll('[type=radio]').length, 1);
    await view.unmount();
  });
  await scenario('explicit restore does not select, automatically save, or overwrite local edits', async () => {
    const store = memoryStorage(synthetic()); const view = await mount({ storage: store });
    assert.deepEqual(store.calls, []); await click(view, '기기 자료 불러오기');
    assert.deepEqual(store.calls, [['get', STUDY_STORAGE_KEY]]); assert.deepEqual(view.changes, []);
    assert.equal(view.target.querySelector('[type=checkbox]').checked, false); assert.equal(view.target.querySelector('[type=radio]').checked, false);
    await click(view, 'Unit 1 수정'); await input(view, '#study-section-excerpt', 'Unsaved revision.'); await click(view, '수정 적용');
    assert.equal(JSON.parse(store.data.get(STUDY_STORAGE_KEY)).materials[0].sections[0].excerpt, 'Synthetic excerpt.');
    assert.equal([...view.target.querySelectorAll('button')].find(button => button.textContent === '기기 자료 불러오기').disabled, true);
    await view.unmount();
    const reopened = await mount({ storage: store }); assert.equal(reopened.target.querySelectorAll('[type=radio]').length, 0);
    assert.deepEqual(reopened.changes, []); await reopened.unmount();
  });
  await scenario('corrupt storage remains untouched and delete requires an explicit confirmation', async () => {
    const store = memoryStorage(); store.data.set(STUDY_STORAGE_KEY, '{corrupt'); const view = await mount({ storage: store });
    await click(view, '기기 자료 불러오기'); assert.match(view.target.querySelector('[role=alert]').textContent, /덮어쓰지/);
    assert.equal(store.data.get(STUDY_STORAGE_KEY), '{corrupt'); await click(view, '기기에 저장된 자료 삭제');
    await click(view, '삭제 취소'); assert.equal(store.data.get(STUDY_STORAGE_KEY), '{corrupt');
    await click(view, '기기에 저장된 자료 삭제'); await click(view, '삭제 확인'); assert.equal(store.data.has(STUDY_STORAGE_KEY), false);
    await view.unmount();
  });
  await scenario('save and delete failures remain visible without claiming success', async () => {
    const store = memoryStorage(); let failSet = true, failRemove = true;
    const set = store.setItem, remove = store.removeItem;
    store.setItem = (key, value) => { if (failSet) throw new Error('synthetic quota failure'); set.call(store, key, value); };
    store.removeItem = key => { if (failRemove) throw new Error('synthetic denied'); remove.call(store, key); };
    const view = await mount({ storage: store }); await addBook(view); await addSection(view);
    await toggle(view, '[type=checkbox]'); assert.equal(view.target.querySelector('[type=checkbox]').checked, false);
    assert.match(view.target.querySelector('[role=alert]').textContent, /저장하지 못/);
    failSet = false; await toggle(view, '[type=checkbox]'); assert.equal(view.target.querySelector('[type=checkbox]').checked, true);
    await toggle(view, '[type=checkbox]'); assert.equal(view.target.querySelector('[type=checkbox]').checked, true);
    assert.match(view.target.querySelector('[role=alert]').textContent, /삭제하지 못/);
    failSet = true; await click(view, 'Unit 1 수정'); await input(view, '#study-section-excerpt', 'Memory-only revision.'); await click(view, '수정 적용');
    assert.match(view.target.querySelector('[role=alert]').textContent, /이전 저장본/);
    assert.equal(JSON.parse(store.data.get(STUDY_STORAGE_KEY)).materials[0].sections[0].excerpt, 'Synthetic excerpt.');
    failRemove = false; await toggle(view, '[type=checkbox]'); assert.equal(view.target.querySelector('[type=checkbox]').checked, false);
    await view.unmount();
  });
  await scenario('native mode is session-only and never reads or writes even injected storage', async () => {
    const store = memoryStorage(synthetic()); const view = await mount({ mode: 'native', providerName: 'Synthetic provider', storage: store });
    await addBook(view); await addSection(view); await select(view);
    assert.deepEqual(store.calls, []); assert.equal(view.target.querySelector('[type=checkbox]'), null);
    assert.match(view.target.textContent, /영구 저장 기능은 제공하지 않습니다/);
    assert.match(view.target.textContent, /Synthetic provider/);
    assert.equal(view.target.textContent.includes('기기 자료 불러오기'), false);
    await view.unmount(); assert.deepEqual(store.calls, []);
  });
  await scenario('source reset clears only active choice and does not callback over the parent source', async () => {
    const view = await mount(); await addBook(view); await addSection(view); await select(view);
    await view.render({ selectionResetKey: 1 }); assert.equal(view.target.querySelector('[type=radio]').checked, false);
    assert.equal(view.changes.length, 1); assert.equal(view.target.querySelectorAll('[type=radio]').length, 1);
    await view.unmount();
  });
  await scenario('book content renders as plain escaped text without script, image, or network execution', async () => {
    const view = await mount(); const excerpt = '<script>window.bookExecuted = true</script><img src="https://invalid.example/private">';
    await addBook(view, '<b>Synthetic book</b>'); await addSection(view, '<i>Unit 1</i>', excerpt); await select(view);
    assert.equal(view.target.querySelector('script'), null); assert.equal(view.target.querySelector('img'), null);
    assert.equal(window.bookExecuted, undefined); assert.equal(view.changes.at(-1).excerpt, excerpt);
    assert.equal(view.props.storage.calls.length, 0); await view.unmount();
  });
  console.log(`${checks} study-material React lifecycle checks passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
