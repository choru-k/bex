/* Cloud loader lifecycle and React integration with delayed local-module doubles.
 * Real PDF/XML parser coverage remains in study-documents-parsers.test.mjs.
 */
const fs = require('node:fs'); const path = require('node:path'); const assert = require('node:assert/strict'); const Module = require('node:module');
const harness = Module.createRequire(path.resolve(process.env.BEX_NODE_HARNESS || '/tmp/bex-native-node-harness', 'package.json')); const ts = harness('typescript');
for (const extension of ['.ts', '.tsx']) require.extensions[extension] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX },
}).outputText, file);
let moduleLoads = 0, pdfExtractions = 0, epubExtractions = 0;
const documentValue = format => ({ format, suggestedTitle: 'Synthetic title', units: [{ label: format === 'pdf' ? 'PDF 파일 페이지 1' : 'EPUB 단원 1', text: 'Synthetic vocabulary practice.' }], warnings: [] });
const pdfModule = { async extractPdf(bytes, signal) { assert.equal(signal.aborted, false); pdfExtractions++; return documentValue('pdf'); } };
let load = () => pdfModule;
const originalLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request === './extractPdf.ts') { moduleLoads++; return load(); }
  if (request === './extractEpub.ts') return { async extractEpub() { epubExtractions++; return documentValue('epub'); } };
  return originalLoad.call(this, request, parent, isMain);
};
const { importStudyDocument } = require('../src/study/documents/importDocument.ts');
const { DOCUMENT_LIMITS } = require('../src/study/documents/documentModel.ts');
function localFile({ name = 'synthetic.pdf', size = 50, header = '%PDF-', read } = {}) {
  const counts = { header: 0, full: 0 };
  return { counts, size, name, slice(start, end) { assert.equal(start, 0); assert.equal(end, 5); counts.header++; return { async arrayBuffer() { return new TextEncoder().encode(header).buffer; } }; },
    async arrayBuffer() { counts.full++; return read ? read() : new TextEncoder().encode('%PDF-synthetic-text').buffer; } };
}
function deferred() { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; }
const tick = () => new Promise(resolve => setImmediate(resolve));
let checks = 0; async function scenario(name, run) { await run(); checks++; console.log('PASS ' + name); }
(async () => {
  await scenario('startup, rejected file size/extension/header, and pre-abort never load PDF code', async () => {
    assert.equal(moduleLoads, 0);
    for (const file of [localFile({ size: 0 }), localFile({ size: DOCUMENT_LIMITS.fileBytes + 1 }), localFile({ name: 'unknown.txt' }), localFile({ header: 'wrong' })]) {
      await assert.rejects(importStudyDocument(file, new AbortController().signal)); assert.equal(file.counts.full, 0);
    }
    const cancelled = new AbortController(); cancelled.abort(); const file = localFile();
    await assert.rejects(importStudyDocument(file, cancelled.signal), { name: 'AbortError' });
    assert.deepEqual(file.counts, { header: 0, full: 0 }); assert.equal(moduleLoads, 0);
  });
  await scenario('EPUB extraction never requests or evaluates the PDF module', async () => {
    const file = localFile({ name: 'synthetic.epub' }); const before = moduleLoads;
    const result = await importStudyDocument(file, new AbortController().signal);
    assert.equal(result.format, 'epub'); assert.equal(moduleLoads, before); assert.equal(epubExtractions, 1); assert.deepEqual(file.counts, { header: 0, full: 1 });
  });
  await scenario('pending module retains only a five-byte read; cancel waits for settlement then starts no full read/parser', async () => {
    const chunk = deferred(); load = () => chunk.promise; const file = localFile(); const controller = new AbortController(); let settled = false; const before = pdfExtractions;
    const pending = importStudyDocument(file, controller.signal); pending.then(() => { settled = true; }, () => { settled = true; });
    await tick(); assert.deepEqual(file.counts, { header: 1, full: 0 }); controller.abort(); await tick(); assert.equal(settled, false);
    chunk.resolve(pdfModule); await assert.rejects(pending, { name: 'AbortError' }); assert.equal(pdfExtractions, before); assert.equal(file.counts.full, 0);
  });
  await scenario('20-second deadline includes module loading and late resolve starts no full read or parser', async () => {
    const chunk = deferred(); load = () => chunk.promise; const file = localFile(); const before = pdfExtractions;
    const originalTimer = global.setTimeout; let deadline;
    global.setTimeout = (callback, delay) => { assert.equal(delay, 20_000); deadline = callback; return 1; };
    try {
      const pending = importStudyDocument(file, new AbortController().signal); await tick(); deadline(); await tick();
      assert.equal(file.counts.full, 0); chunk.resolve(pdfModule); await assert.rejects(pending, /시간 한도/);
      assert.equal(file.counts.full, 0); assert.equal(pdfExtractions, before);
    } finally { global.setTimeout = originalTimer; }
  });
  await scenario('delayed timer task cannot admit a module resolved beyond the monotonic deadline', async () => {
    const original = Object.getOwnPropertyDescriptor(global, 'performance'); let now = 0;
    Object.defineProperty(global, 'performance', { configurable: true, value: { now: () => now } });
    const file = localFile(); const before = pdfExtractions;
    load = () => { now = DOCUMENT_LIMITS.timeoutMs + 1; return pdfModule; };
    try {
      await assert.rejects(importStudyDocument(file, new AbortController().signal), /시간 한도/);
      assert.equal(file.counts.full, 0); assert.equal(pdfExtractions, before);
    } finally { Object.defineProperty(global, 'performance', original); }
  });
  await scenario('chunk failure is generic and a later explicit attempt is not stuck on an app-cached rejection', async () => {
    const chunk = deferred(); load = () => chunk.promise; const first = localFile(); const before = moduleLoads;
    const pending = importStudyDocument(first, new AbortController().signal); await tick(); chunk.reject(new Error('PDF private-canary https://private.invalid/path'));
    await assert.rejects(pending, error => /모듈을 불러오지 못/.test(error.message) && !error.message.includes('private-canary') && !error.message.includes('private.invalid'));
    assert.equal(first.counts.full, 0); load = () => pdfModule;
    const second = localFile(); assert.equal((await importStudyDocument(second, new AbortController().signal)).format, 'pdf');
    assert.equal(moduleLoads, before + 2); assert.deepEqual(second.counts, { header: 1, full: 1 });
  });
  await scenario('cancel then chunk rejection reports cancellation without leaking chunk details', async () => {
    const chunk = deferred(); load = () => chunk.promise; const controller = new AbortController(); const file = localFile();
    const pending = importStudyDocument(file, controller.signal); await tick(); controller.abort(); chunk.reject(new Error('secret chunk error'));
    await assert.rejects(pending, { name: 'AbortError' }); assert.equal(file.counts.full, 0);
  });
  await scenario('cancel during full read after successful module load starts no parser when bytes arrive', async () => {
    load = () => pdfModule; const bytes = deferred(); const file = localFile({ read: () => bytes.promise }); const controller = new AbortController(); const before = pdfExtractions;
    const pending = importStudyDocument(file, controller.signal); await tick(); assert.equal(file.counts.full, 1); controller.abort(); bytes.resolve(new Uint8Array([1]).buffer);
    await assert.rejects(pending, { name: 'AbortError' }); assert.equal(pdfExtractions, before);
  });

  // Exercise the actual UI + importStudyDocument + lazy loader, not a replacement importer.
  const { JSDOM } = harness('jsdom'); const dom = new JSDOM('<html><body></body></html>', { url: 'http://127.0.0.1' });
  for (const key of ['window', 'document', 'HTMLElement', 'Event']) global[key] = dom.window[key];
  Object.defineProperty(global, 'navigator', { value: dom.window.navigator, configurable: true }); global.IS_REACT_ACT_ENVIRONMENT = true;
  const React = require('react'); const { act } = React; const { createRoot } = require('react-dom/client');
  const { StudyDocumentImport } = require('../src/study/StudyDocumentImport.tsx');
  async function mount() {
    const target = document.createElement('div'); document.body.append(target); const root = createRoot(target);
    await act(async () => root.render(React.createElement(React.StrictMode, null, React.createElement(StudyDocumentImport, { onAdd() { assert.fail('No source selected'); } }))));
    return { target, async unmount() { await act(async () => root.unmount()); target.remove(); } };
  }
  async function choose(view, file) { const field = view.target.querySelector('[type=file]'); Object.defineProperty(field, 'files', { value: [file], configurable: true }); await act(async () => field.dispatchEvent(new Event('change', { bubbles: true }))); }
  async function cancel(view) { const button = [...view.target.querySelectorAll('button')].find(button => button.textContent === '문서 읽기 취소'); assert.ok(button); await act(async () => button.click()); }
  await scenario('React cancel holds admission across chunk load, ignores repeat choices, then allows explicit retry', async () => {
    const chunk = deferred(); load = () => chunk.promise; const before = moduleLoads, extracts = pdfExtractions; const view = await mount(); const first = localFile();
    await choose(view, first); await cancel(view); assert.equal(view.target.querySelector('[type=file]').disabled, true);
    const second = localFile(); await choose(view, second); await choose(view, localFile()); assert.equal(moduleLoads, before + 1);
    assert.deepEqual(second.counts, { header: 0, full: 0 }); assert.equal(first.counts.full, 0);
    await act(async () => chunk.resolve(pdfModule)); assert.equal(pdfExtractions, extracts); assert.equal(view.target.querySelector('[type=file]').disabled, false);
    load = () => pdfModule; await choose(view, second); assert.ok(view.target.querySelector('#import-document-title')); assert.equal(pdfExtractions, extracts + 1);
    assert.equal(dom.window.localStorage.length, 0); await view.unmount();
  });
  await scenario('React unmount while code loads rejects late module completion without reading full file', async () => {
    const chunk = deferred(); load = () => chunk.promise; const before = pdfExtractions; const view = await mount(); const file = localFile();
    await choose(view, file); await view.unmount(); await act(async () => chunk.resolve(pdfModule)); assert.equal(file.counts.full, 0); assert.equal(pdfExtractions, before);
  });
  await scenario('React module failure displays fixed copy and enables a later explicit retry', async () => {
    const chunk = deferred(); load = () => chunk.promise; const view = await mount(); await choose(view, localFile());
    await act(async () => chunk.reject(new Error('private-syntax-stack'))); assert.match(view.target.querySelector('[role=alert]').textContent, /모듈을 불러오지 못/);
    assert.ok(!view.target.textContent.includes('private-syntax-stack')); assert.equal(view.target.querySelector('[type=file]').disabled, false);
    load = () => pdfModule; await choose(view, localFile()); assert.ok(view.target.querySelector('#import-document-title')); await view.unmount();
  });
  console.log(`${checks} PDF on-demand lifecycle scenarios passed (no browser launch).`);
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => { Module._load = originalLoad; });
