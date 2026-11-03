import test from 'node:test';
import assert from 'node:assert/strict';
import { BoundedZip, safeArchivePath } from '../src/study/documents/boundedZip.ts';
import { DOCUMENT_LIMITS, indexStudyDocument, passageSource, retrieveStudyPassages, validateFileBytes } from '../src/study/documents/documentModel.ts';
import { readPdfText } from '../src/study/documents/pdfTextCore.ts';
import { privatePdfOptions } from '../src/study/documents/pdfOptions.ts';
import { zip } from './document-fixtures.mjs';
const document = (units) => indexStudyDocument({ format: 'pdf', suggestedTitle: 'Synthetic', units, warnings: [] });

test('stored and deflated ZIP entries round-trip only through bounded memory', async () => {
  const archive = new BoundedZip(zip([['plain.txt', 'synthetic'], ['compressed.txt', 'a short synthetic excerpt', { method: 8 }]]));
  assert.equal(await archive.text('plain.txt'), 'synthetic'); assert.equal(await archive.text('compressed.txt'), 'a short synthetic excerpt');
});
for (const path of ['../escape', '/absolute', 'a/../escape', 'a/./b', 'a//b', 'https://remote', 'a%2fb', 'C:drive', 'a\\b', 'a\u0000b', 'a?b', 'a#b']) {
  test(`reject unsafe archive path ${JSON.stringify(path)}`, () => assert.throws(() => safeArchivePath(path)));
}
for (const [name, entries] of [
  ['encryption', [['entry', 'abc', { flags: 1 }]]], ['unknown compression', [['entry', 'abc', { method: 12 }]]],
  ['symlink', [['entry', 'abc', { attributes: 0xa0000000 }]]], ['duplicate names', [['entry', 'a'], ['entry', 'b']]],
  ['parent path', [['../entry', 'abc']]], ['declared entry size', [['entry', 'abc', { size: DOCUMENT_LIMITS.entryBytes + 1 }]]],
  ['ratio bomb', [['entry', 'a'.repeat(100_000), { method: 8 }]]],
]) test(`ZIP rejects ${name}`, () => assert.throws(() => new BoundedZip(zip(entries))));
test('reject CRC mismatch and understated decompression size without accepting partial text', async () => {
  await assert.rejects(new BoundedZip(zip([['entry', 'actual text', { crc: 1 }]])).text('entry'));
  await assert.rejects(new BoundedZip(zip([['entry', 'actual text', { method: 8, size: 1 }]])).text('entry'));
});
test('reject malformed local header, central header, truncation, and wrong local name', () => {
  const bytes = zip([['entry', 'abc']]);
  for (const mutate of [raw => raw.fill(0, 0, 4), raw => raw[30] = 0x78, raw => raw.fill(0, raw.length - 22, raw.length - 18)]) {
    const copy = bytes.slice(); mutate(copy); assert.throws(() => new BoundedZip(copy));
  }
  assert.throws(() => new BoundedZip(bytes.subarray(0, bytes.length - 1)));
});
test('cancelled ZIP read is rejected before parsing output', async () => {
  const controller = new AbortController(); controller.abort();
  await assert.rejects(new BoundedZip(zip([['entry', 'abc']])).text('entry', controller.signal), { name: 'AbortError' });
});
test('empty and oversized file input is rejected', () => {
  assert.throws(() => validateFileBytes(new Uint8Array())); assert.throws(() => validateFileBytes(new Uint8Array(DOCUMENT_LIMITS.fileBytes + 1)));
});
test('passages are bounded, deterministic, ordered and attributed to actual file pages', () => {
  const source = { format: 'pdf', suggestedTitle: 'Book', warnings: [], units: [{ label: 'PDF 파일 페이지 4', text: 'word '.repeat(650) }] };
  const first = indexStudyDocument(source); assert.deepEqual(first, indexStudyDocument(source));
  assert.equal(first.passages.length, 3); assert.ok(first.passages.every(item => item.text.length <= DOCUMENT_LIMITS.passageCharacters));
  assert.ok(first.passages.every(item => item.label.startsWith('PDF 파일 페이지 4 · 발췌')));
  assert.deepEqual(passageSource('Book · Author', first.passages[0]), { title: 'Book · Author', section: first.passages[0].label, excerpt: first.passages[0].text });
});
test('surrogate pairs are not split and extraction is normalized rather than claimed exact layout', () => {
  const result = document([{ label: 'Page 1', text: '😀'.repeat(700) }]);
  assert.ok(result.passages.every(item => !/[\uD800-\uDBFF]$/.test(item.text) && !/^[\uDC00-\uDFFF]/.test(item.text)));
});
test('retrieval prefers term coverage, then bounded counts, then source order', () => {
  const index = document([{ label: 'Page 1', text: 'grammar '.repeat(20) }, { label: 'Page 2', text: 'grammar vocabulary' }, { label: 'Page 3', text: 'grammar vocabulary' }]);
  assert.deepEqual(retrieveStudyPassages(index, 'grammar vocabulary').map(item => item.passage.order), [1, 2, 0]);
  assert.deepEqual(retrieveStudyPassages(index, 'unmatched'), []); assert.deepEqual(retrieveStudyPassages(index, 'the and of'), []);
  assert.deepEqual(retrieveStudyPassages(index, ''), []); assert.throws(() => retrieveStudyPassages(index, 'x'.repeat(301)));
});
test('exact unicode tokens match, substrings do not, and code-like queries never execute', () => {
  const index = document([{ label: 'Unit 1', text: '학습 teaches learning. <script>alert(1)</script>' }]);
  assert.equal(retrieveStudyPassages(index, '학습').length, 1); assert.equal(retrieveStudyPassages(index, 'learn').length, 0);
  assert.equal(retrieveStudyPassages(index, '<script>alert(1)</script>').length, 1);
});
test('index rejects empty text and corpus/unit limits rather than pretending complete import', () => {
  assert.throws(() => document([{ label: 'Page 1', text: ' ' }]));
  assert.throws(() => document([{ label: 'Page 1', text: 'x'.repeat(DOCUMENT_LIMITS.textCharacters + 1) }]));
  assert.throws(() => document(Array.from({ length: 251 }, () => ({ label: 'Page', text: 'text' }))));
});
test('PDF reader keeps physical page attribution and cleans each page', async () => {
  let cleaned = 0; const result = await readPdfText({ numPages: 2, async getPage(page) { return { async getTextContent() { return { items: page === 1 ? [{ str: 'Synthetic text' }] : [] }; }, cleanup() { cleaned++; } }; } });
  assert.equal(cleaned, 2); assert.equal(result.units[0].label, 'PDF 파일 페이지 1'); assert.equal(result.units[0].text, 'Synthetic text');
  assert.match(result.warnings.join(' '), /OCR/);
});
test('PDF reader rejects oversized pages/items/text and aborts between operations', async () => {
  await assert.rejects(readPdfText({ numPages: 251, getPage() { assert.fail(); } }));
  for (const items of [Array.from({ length: 30_001 }, () => ({ str: 'x' })), [{ str: 'x'.repeat(600_001) }], [{ str: 42 }]]) {
    let cleaned = false;
    await assert.rejects(readPdfText({ numPages: 1, async getPage() { return { async getTextContent() { return { items }; }, cleanup() { cleaned = true; } }; } }));
    assert.equal(cleaned, true);
  }
  const controller = new AbortController(); controller.abort(); await assert.rejects(readPdfText({ numPages: 1, getPage() { assert.fail(); } }, controller.signal), { name: 'AbortError' });
});
test('PDF options accept data only and block external resources, forms, rendering and wasm', async () => {
  const bytes = new Uint8Array([1]); const options = privatePdfOptions(bytes);
  assert.equal(options.data, bytes); assert.equal('url' in options, false);
  for (const field of ['useWorkerFetch', 'useWasm', 'enableXfa', 'useSystemFonts', 'isOffscreenCanvasSupported', 'isImageDecoderSupported']) assert.equal(options[field], false);
  assert.equal(options.disableFontFace, true); assert.equal(options.stopAtErrors, true);
  await assert.rejects(new options.BinaryDataFactory().fetch({ url: 'https://invalid.example/private' }));
});
test('PDF worker wrapper denies both fetch and XMLHttpRequest rather than relying on parser defaults', async () => {
  const { readFile } = await import('node:fs/promises'); const { runInNewContext } = await import('node:vm');
  const code = (await readFile(new URL('../src/study/documents/pdf.worker.ts', import.meta.url), 'utf8')).replace(/^import .*;$/m, '');
  const context = {}; runInNewContext(code, context);
  await assert.rejects(context.fetch('https://invalid.example')); assert.throws(() => new context.XMLHttpRequest());
  assert.equal(Object.getOwnPropertyDescriptor(context, 'fetch').writable, false);
  assert.equal(Object.getOwnPropertyDescriptor(context, 'XMLHttpRequest').writable, false);
});

const run = (str, x, changes = {}) => ({ str, dir: 'ltr', width: 10, height: 12, transform: [12, 0, 0, 12, x, 720], hasEOL: false, ...changes });
async function readRuns(items) {
  return (await readPdfText({ numPages: 1, async getPage() { return { async getTextContent() { return { items }; }, cleanup() {} }; } })).units[0].text;
}
test('PDF joins only compatible contiguous horizontal runs including tiny numerical roundoff', async () => {
  assert.equal(await readRuns([run('gram', 72, { fontName: 'regular' }), run('mar', 82 - 1e-12, { fontName: 'bold' })]), 'grammar');
  assert.equal(await readRuns([run('Hello', 72), run(',', 82)]), 'Hello,');
});
for (const [name, previous, next] of [
  ['word gap', run('hello', 72), run('world', 85)],
  ['column gap', run('left', 72), run('right', 300)],
  ['different baseline', run('first', 72), run('second', 82, { transform: [12, 0, 0, 12, 82, 700] })],
  ['explicit EOL', run('first', 72, { hasEOL: true }), run('second', 82)],
  ['overlap beyond roundoff', run('first', 72), run('second', 80)],
  ['RTL direction', run('first', 72, { dir: 'rtl' }), run('second', 82, { dir: 'rtl' })],
  ['vertical direction', run('first', 72, { dir: 'ttb' }), run('second', 82, { dir: 'ttb' })],
  ['rotation', run('first', 72, { transform: [0, 12, -12, 0, 72, 720] }), run('second', 82)],
  ['skew', run('first', 72, { transform: [12, 0, 1, 12, 72, 720] }), run('second', 82)],
  ['mixed font size', run('first', 72), run('second', 82, { height: 10, transform: [10, 0, 0, 10, 82, 720] })],
  ['missing geometry', { str: 'first' }, { str: 'second' }],
  ['nonfinite geometry', run('first', 72, { width: Infinity }), run('second', 82)],
  ['tiny meaningful gap', run('first', 72, { width: 0.00001, height: 0.00001, transform: [0.00001, 0, 0, 0.00001, 72, 720] }), run('second', 72.00002, { width: 0.00001, height: 0.00001, transform: [0.00001, 0, 0, 0.00001, 72.00002, 720] })],
  ['tiny overlapping text', run('first', 72, { width: 0.00001, height: 0.00001, transform: [0.00001, 0, 0, 0.00001, 72, 720] }), run('second', 72, { width: 0.00001, height: 0.00001, transform: [0.00001, 0, 0, 0.00001, 72, 720] })],
  ['negative width', run('first', 72, { width: -10 }), run('second', 62)],
]) test(`PDF keeps a conservative separator for ${name}`, async () => {
  assert.equal(await readRuns([previous, next]), `${previous.str} ${next.str}`);
});
test('PDF explicit spaces and empty EOL markers survive run assembly', async () => {
  assert.equal(await readRuns([run('hello', 72), { str: ' ' }, run('world', 82)]), 'hello world');
  assert.equal(await readRuns([run('hello ', 72), run('world', 82)]), 'hello world');
  assert.equal(await readRuns([run('hello', 72), run(' world', 82)]), 'hello world');
  assert.equal(await readRuns([run('first', 72), { str: '', hasEOL: true }, run('second', 82)]), 'first second');
});
test('PDF source order is retained rather than sorting by page position', async () => {
  assert.equal(await readRuns([run('second', 300), run('first', 72)]), 'second first');
});
test('inserted PDF boundaries count toward the existing text limit', async () => {
  await assert.rejects(readRuns([{ str: 'a'.repeat(DOCUMENT_LIMITS.textCharacters) }, { str: '', hasEOL: true }]));
});
