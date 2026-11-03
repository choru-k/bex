/* Coordinator lifecycle with deterministic worker/PDF transport doubles; actual parser tested separately. */
const fs = require('node:fs'); const path = require('node:path'); const assert = require('node:assert/strict'); const Module = require('node:module');
const harness = Module.createRequire(path.resolve(process.env.BEX_NODE_HARNESS || '/tmp/bex-native-node-harness', 'package.json')); const ts = harness('typescript');
require.extensions['.ts'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText, file);
let workerPorts = [], wrappers = [], tasks = [], createFailure = false, mode = 'pending';
class WorkerDouble {
  constructor() { this.terminated = 0; this.listeners = new Map(); workerPorts.push(this); }
  terminate() { this.terminated++; }
  addEventListener(name, listener) { this.listeners.set(name, listener); }
  removeEventListener(name) { this.listeners.delete(name); }
}
const oldLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request === './pdf.worker.ts?worker') return { default: WorkerDouble };
  if (request === 'pdfjs-dist/legacy/build/pdf.mjs') return {
    PDFWorker: { create({ port }) { if (createFailure) throw Error('synthetic failure'); const wrapper = { port, promise: Promise.resolve(), destroyed: 0, destroy() { this.destroyed++; } }; wrappers.push(wrapper); return wrapper; } },
    getDocument(options) { let resolve, reject; const task = { options, destroyed: 0, promise: new Promise((yes, no) => { resolve = yes; reject = no; }), destroy() { this.destroyed++; reject(new Error('destroyed')); return Promise.resolve(); } };
      task.resolve = resolve; task.reject = reject; tasks.push(task);
      if (mode === 'success') resolve({ numPages: 1, async getPage() { return { async getTextContent() { return { items: [{ str: 'Synthetic text' }] }; }, cleanup() {} }; } });
      return task;
    },
  };
  return oldLoad.call(this, request, parent, isMain);
};
const { extractPdf } = require('../src/study/documents/extractPdf.ts'); Module._load = oldLoad;
const bytes = () => new TextEncoder().encode('%PDF-synthetic'); const tick = () => new Promise(resolve => setImmediate(resolve));
let count = 0; async function scenario(name, run) { await run(); count++; console.log('PASS ' + name); }
(async () => {
  await scenario('pre-cancelled/invalid inputs create no worker', async () => { const before = workerPorts.length; const controller = new AbortController(); controller.abort(); await assert.rejects(extractPdf(bytes(), controller.signal), { name: 'AbortError' }); await assert.rejects(extractPdf(new TextEncoder().encode('not PDF'))); assert.equal(workerPorts.length, before); });
  await scenario('cancellation terminates actual worker, destroys parser, rejects even if parser never responds', async () => {
    mode = 'pending'; const controller = new AbortController(); const pending = extractPdf(bytes(), controller.signal); await tick(); controller.abort();
    await assert.rejects(pending, { name: 'AbortError' }); assert.equal(workerPorts.at(-1).terminated, 1); assert.equal(wrappers.at(-1).destroyed, 1); assert.equal(tasks.at(-1).destroyed, 1); assert.equal(workerPorts.at(-1).listeners.size, 0);
  });
  await scenario('password event rejects without prompting for or retaining a password', async () => {
    const pending = extractPdf(bytes()); await tick(); tasks.at(-1).onPassword(); await assert.rejects(pending, /암호로 보호/);
    assert.equal(workerPorts.at(-1).terminated, 1); assert.equal(tasks.at(-1).destroyed, 1); assert.equal('password' in tasks.at(-1).options, false);
  });
  await scenario('worker error fails closed without a main-thread/fake-worker fallback', async () => {
    const pending = extractPdf(bytes()); await tick(); workerPorts.at(-1).listeners.get('error')(); await assert.rejects(pending, /시작하지 못/); assert.equal(workerPorts.at(-1).terminated, 1);
  });
  await scenario('wrapper creation failure also terminates already-created worker', async () => {
    createFailure = true; await assert.rejects(extractPdf(bytes()), /synthetic failure/); createFailure = false; assert.equal(workerPorts.at(-1).terminated, 1);
  });
  await scenario('successful extraction disposes resources and returns only attributed text', async () => {
    mode = 'success'; const result = await extractPdf(bytes()); assert.equal(result.units[0].text, 'Synthetic text'); assert.equal(workerPorts.at(-1).terminated, 1); assert.equal(tasks.at(-1).destroyed, 1);
    assert.equal(tasks.at(-1).options.worker, wrappers.at(-1)); assert.equal('url' in tasks.at(-1).options, false);
  });
  console.log(`${count} PDF worker lifecycle scenarios passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
