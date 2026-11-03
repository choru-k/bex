/* Explicit parser validation: uses installed Mozilla package and isolated JSDOM XML parser.
 * Not a browser-worker, WebKit, or live provider test. */
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import { getDocument } from 'pdfjs-dist/legacy/build/pdf.mjs';
import { extractEpub } from '../src/study/documents/extractEpub.ts';
import { privatePdfOptions } from '../src/study/documents/pdfOptions.ts';
import { readPdfText } from '../src/study/documents/pdfTextCore.ts';
import { indexStudyDocument, retrieveStudyPassages } from '../src/study/documents/documentModel.ts';
import { epub, packageXML, chapter, simplePDF } from './document-fixtures.mjs';
const harness = createRequire(path.resolve(process.env.BEX_NODE_HARNESS || '/tmp/bex-native-node-harness', 'package.json'));
const { JSDOM } = harness('jsdom'); const dom = new JSDOM(''); globalThis.DOMParser = dom.window.DOMParser;

test('EPUB reads declared spine order and preserved title/author, not filename or guessed pages', async () => {
  const bytes = epub({ packageText: packageXML('<item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>', '<itemref idref="two"/><itemref idref="one"/>'),
    additional: [['OPS/two.xhtml', chapter('<h1>Second chapter</h1><p>Vocabulary practice.</p>')]], options: { method: 8 } });
  const result = await extractEpub(bytes); assert.equal(result.suggestedTitle, 'Synthetic Book · Test Author');
  assert.equal(result.units.length, 2); assert.match(result.units[0].text, /Vocabulary/); assert.match(result.units[1].text, /Accurate/);
  assert.equal(result.units[0].label, 'EPUB 단원 1 · Second chapter');
  assert.equal(retrieveStudyPassages(indexStudyDocument(result), 'vocabulary')[0].passage.order, 0);
});
test('EPUB text keeps inline words and block boundaries, ignores active and explicitly hidden content', async () => {
  const result = await extractEpub(epub({ body: chapter('<p>Hello <em>useful</em> world.</p>Next<p>Paragraph.</p><script>evil()</script><style>secret</style><iframe src="https://invalid.example"/><img src="https://invalid.example"/><p hidden="">hidden text</p><p aria-hidden="true">other hidden</p>') }));
  assert.equal(result.units[0].text, 'Hello useful world. Next Paragraph.');
  assert.equal(dom.window.evil, undefined);
});
for (const [label, bytes] of [
  ['DTD', epub({ body: chapter('<p>Text</p>', '<!DOCTYPE html [<!ENTITY external SYSTEM "https://invalid.example/private">]>') })],
  ['entity', epub({ body: chapter('<p>&external;</p>') })],
  ['external manifest URL', epub({ packageText: packageXML('<item id="one" href="https://invalid.example/private" media-type="application/xhtml+xml"/>') })],
  ['encoded manifest path', epub({ packageText: packageXML('<item id="one" href="%2e%2e/one.xhtml" media-type="application/xhtml+xml"/>') })],
  ['traversal manifest', epub({ packageText: packageXML('<item id="one" href="../one.xhtml" media-type="application/xhtml+xml"/>') })],
  ['duplicate ID', epub({ packageText: packageXML('<item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>') })],
  ['unknown spine', epub({ packageText: packageXML(undefined, '<itemref idref="missing"/>') })],
  ['duplicate spine', epub({ packageText: packageXML(undefined, '<itemref idref="one"/><itemref idref="one"/>') })],
  ['non-XHTML spine', epub({ packageText: packageXML('<item id="one" href="one.xhtml" media-type="text/html"/>') })],
  ['DRM/encryption', epub({ additional: [['META-INF/encryption.xml', '<encryption/>']] })],
  ['wrong XHTML namespace', epub({ body: '<html><body>text</body></html>' })],
  ['deep XML', epub({ body: chapter('<div>'.repeat(101) + 'text' + '</div>'.repeat(101)) })],
  ['quoted depth bypass', epub({ body: chapter('<div title="/>">'.repeat(101) + 'text' + '</div>'.repeat(101)) })],
  ['CDATA', epub({ body: chapter('<p><![CDATA[text]]></p>') })],
]) test(`EPUB fails closed on ${label}`, async () => assert.rejects(extractEpub(bytes)));
test('EPUB abort and malicious archive references perform no fetch', async () => {
  let calls = 0; const original = globalThis.fetch; globalThis.fetch = async () => { calls++; throw Error('network forbidden'); };
  try {
    const controller = new AbortController(); controller.abort(); await assert.rejects(extractEpub(epub(), controller.signal), { name: 'AbortError' });
    await extractEpub(epub({ body: chapter('<p>safe text</p><a href="https://invalid.example">visible link text</a><img src="https://invalid.example"/>') }));
    assert.equal(calls, 0);
  } finally { globalThis.fetch = original; }
});
test('real Mozilla PDF parser extracts synthetic PDF text with resources disabled and no fetch', async () => {
  let calls = 0; const original = globalThis.fetch; globalThis.fetch = async () => { calls++; throw Error('network forbidden'); };
  const task = getDocument(privatePdfOptions(simplePDF('Synthetic accurate writing keeps meaning.', '/OpenAction << /S /URI /URI (https://invalid.example/private) >>')));
  try {
    const document = await task.promise; const result = await readPdfText(document);
    assert.equal(result.units[0].text, 'Synthetic accurate writing keeps meaning.');
    assert.equal(result.units[0].label, 'PDF 파일 페이지 1'); assert.equal(calls, 0);
    assert.equal(retrieveStudyPassages(indexStudyDocument(result), 'accurate')[0].passage.text, result.units[0].text);
  } finally { await task.destroy(); globalThis.fetch = original; }
});
test('real PDF parser rejects corrupt bytes without surfacing pretend text', async () => {
  const task = getDocument(privatePdfOptions(new TextEncoder().encode('%PDF-1.7\ninvalid synthetic PDF')));
  try { await assert.rejects(task.promise); } finally { await task.destroy(); }
});
test('quote-shaped depth bypass is rejected before XHTML DOM allocation', async () => {
  const OriginalParser = globalThis.DOMParser; let xhtmlParsed = false;
  globalThis.DOMParser = class extends OriginalParser { parseFromString(source, type) { if (source.includes('depth-canary')) xhtmlParsed = true; return super.parseFromString(source, type); } };
  try {
    const body = '<div x="/>">'.repeat(150) + 'depth-canary' + '<x a=">"/></div>'.repeat(150);
    await assert.rejects(extractEpub(epub({ body: chapter(body) })), /깊이/); assert.equal(xhtmlParsed, false);
  } finally { globalThis.DOMParser = OriginalParser; }
});
