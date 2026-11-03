/** Build-output audit, not browser timing/execution proof.
 * npm exec -- vite build --manifest
 * node tests/pdf-build-graph.mjs dist [baseline-dist]
 */
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
async function graph(directory) {
  const root = path.resolve(directory);
  const manifest = JSON.parse(await readFile(path.join(root, '.vite/manifest.json'), 'utf8'));
  const entry = manifest['index.html']; assert.ok(entry?.isEntry, 'browser entry exists');
  const seen = new Set();
  function visit(key) {
    if (seen.has(key)) return;
    seen.add(key); assert.ok(manifest[key], `manifest import exists: ${key}`);
    for (const dependency of manifest[key].imports ?? []) visit(dependency);
  }
  visit('index.html');
  const initial = await Promise.all([...seen].map(async key => {
    const file = manifest[key].file; const bytes = await readFile(path.join(root, file));
    return { key, file, bytes: bytes.length, sha256: hash(bytes), code: bytes.toString('utf8') };
  }));
  return { root, manifest, entry, initial, initialBytes: initial.reduce((sum, item) => sum + item.bytes, 0) };
}
const built = await graph(process.argv[2] ?? 'dist');
const packageJSON = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const version = packageJSON.dependencies['pdfjs-dist'];
const pdfKey = 'src/study/documents/extractPdf.ts';
const pdf = built.manifest[pdfKey];
assert.equal(pdf?.isDynamicEntry, true, 'PDF extraction is a dynamic chunk');
assert.ok(built.entry.dynamicImports?.includes(pdfKey), 'entry loads PDF only through a dynamic edge');
assert.ok(!built.initial.some(item => item.key === pdfKey), 'PDF chunk absent from initial static import closure');
for (const item of built.initial) {
  assert.ok(!item.code.includes(version), 'initial JS excludes Mozilla parser version fingerprint');
  assert.ok(!item.code.includes('pdf.worker-'), 'initial JS cannot instantiate the PDF worker');
}
const pdfBytes = await readFile(path.join(built.root, pdf.file));
assert.ok(pdfBytes.toString('utf8').includes(version), 'deferred chunk contains pinned actual PDF parser');
const workers = (pdf.assets ?? []).filter(file => /pdf\.worker-[^/]+\.js$/.test(file));
assert.equal(workers.length, 1, 'PDF chunk owns exactly one local worker asset');
const html = await readFile(path.join(built.root, 'index.html'), 'utf8');
assert.ok(!html.includes(path.basename(pdf.file)), 'HTML does not preload PDF code');
assert.ok(!html.includes(path.basename(workers[0])), 'HTML does not preload PDF worker');
const workerBytes = await readFile(path.join(built.root, workers[0]));
const result = { initialJavaScript: built.initial.map(({ code, ...item }) => item), initialBytes: built.initialBytes,
  deferredPDF: { file: pdf.file, bytes: pdfBytes.length, sha256: hash(pdfBytes) },
  deferredWorker: { file: workers[0], bytes: workerBytes.length, sha256: hash(workerBytes) },
  limitations: 'Static production chunk graph and fingerprints only; no browser execution, network trace, or measured startup latency.' };
if (process.argv[3]) {
  const baseline = await graph(process.argv[3]);
  assert.ok(baseline.initial.some(item => item.code.includes(version)), 'comparison baseline eagerly contains same PDF parser version');
  assert.ok(built.initialBytes < baseline.initialBytes, 'initial JavaScript is smaller than exact baseline');
  result.baselineInitialBytes = baseline.initialBytes;
  result.initialBytesRemoved = baseline.initialBytes - built.initialBytes;
  result.initialBytesReductionPercent = Number((100 * result.initialBytesRemoved / baseline.initialBytes).toFixed(2));
}
console.log(JSON.stringify(result, null, 2));
