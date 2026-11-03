/* Parser boundary/admission regression tests with deliberately ignored abort and slow File.arrayBuffer. */
const fs = require('node:fs'); const path = require('node:path'); const assert = require('node:assert/strict'); const Module = require('node:module');
const harness = Module.createRequire(path.resolve(process.env.BEX_NODE_HARNESS || '/tmp/bex-native-node-harness', 'package.json')); const ts = harness('typescript');
require.extensions['.ts'] = (module, file) => module._compile(ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText, file);
let parser = async () => ({ format: 'pdf', suggestedTitle: 'Synthetic', units: [{ label: 'PDF 파일 페이지 1', text: 'Synthetic text' }], warnings: [] }); let calls = 0;
const oldLoad = Module._load;
Module._load = function(request, parent, isMain) {
  if (request === './extractPdf.ts') return { extractPdf(...args) { calls++; return parser(...args); } };
  if (request === './extractEpub.ts') return { extractEpub(...args) { calls++; return parser(...args); } };
  return oldLoad.call(this, request, parent, isMain);
};
const { importStudyDocument } = require('../src/study/documents/importDocument.ts'); Module._load = oldLoad;
const { SafeDocumentError } = require('../src/study/documents/documentModel.ts');
const file = (arrayBuffer = async () => new Uint8Array([1, 2]).buffer) => ({ size: 2, name: 'synthetic.pdf', arrayBuffer });
const tick = () => new Promise(resolve => setImmediate(resolve)); let count = 0;
async function scenario(name, run) { await run(); count++; console.log('PASS ' + name); }
(async () => {
  await scenario('third-party prefix-shaped parser errors never leak private document text', async () => {
    for (const message of ['PDF <private text>', 'EPUB <private text>', '문서 <private text>']) {
      parser = async () => { throw new Error(message); };
      await assert.rejects(importStudyDocument(file(), new AbortController().signal), error => !error.message.includes('private text') && /읽지 못했습니다/.test(error.message));
    }
    parser = async () => { throw new SafeDocumentError('PDF 고정 안전 메시지'); };
    await assert.rejects(importStudyDocument(file(), new AbortController().signal), /PDF 고정 안전 메시지/);
  });
  await scenario('cancel during uncancellable file read remains pending until read actually settles and starts no parser', async () => {
    let finish; const before = calls; const controller = new AbortController(); let settled = false;
    const pending = importStudyDocument(file(() => new Promise(resolve => { finish = resolve; })), controller.signal);
    pending.then(() => { settled = true; }, () => { settled = true; }); controller.abort(); await tick(); assert.equal(settled, false);
    finish(new Uint8Array([1]).buffer); await assert.rejects(pending, { name: 'AbortError' }); assert.equal(calls, before);
  });
  await scenario('deadline during slow file read stays pending and cannot admit a parser when bytes arrive later', async () => {
    let timeout, finish; const original = global.setTimeout; const before = calls;
    global.setTimeout = callback => { timeout = callback; return 1; };
    try {
      const pending = importStudyDocument(file(() => new Promise(resolve => { finish = resolve; })), new AbortController().signal);
      timeout(); await tick(); finish(new Uint8Array([1]).buffer); await assert.rejects(pending, /시간 한도/); assert.equal(calls, before);
    } finally { global.setTimeout = original; }
  });
  console.log(`${count} document boundary/admission scenarios passed.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
