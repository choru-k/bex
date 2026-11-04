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
import { epub, packageXML, chapter, simplePDF, textRunsPDF } from './document-fixtures.mjs';
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

for (const [label, body, expected, query] of [
  ['table headers/cells', '<table><thead><tr><th>Singular</th><th>Plural</th></tr></thead><tbody><tr><td>child</td><td>children</td></tr></tbody></table>', 'Singular Plural child children', 'children'],
  ...[4, 5, 6].map(level => [`h${level} headings`, `<h${level}>Countable nouns</h${level}><h${level}>Uncountable nouns</h${level}>`, 'Countable nouns Uncountable nouns', 'uncountable']),
  ['definition terms/descriptions', '<dl><dt>article</dt><dd>A word that marks a noun.</dd></dl>', 'article A word that marks a noun.', 'article'],
  ['caption and surrounding text', 'Before<table><caption>Examples</caption><tr><td>One</td><td>Two</td></tr></table>After', 'Before Examples One Two After', 'two'],
  ['nested structural text', '<main><header>Introduction</header><aside>Note</aside><blockquote>Quoted example</blockquote><figure><figcaption>Caption</figcaption>Detail</figure><footer>End</footer></main>', 'Introduction Note Quoted example Caption Detail End', 'detail'],
  ['inline styling and punctuation', '<p>gram<strong>mar</strong>, co<em>operate</em> and don<span>’</span>t split<code>-</code>words.</p>', 'grammar, cooperate and don’t split-words.', 'grammar'],
  ['soft break inside a word', '<p>main<wbr/>tain the source.</p>', 'maintain the source.', 'maintain'],
  ['hidden/active cells remain excluded', '<table><tr><td>visible</td><td hidden="">private</td><td aria-hidden="true">secret</td><td>word<script>injected</script></td></tr></table>', 'visible word', 'word'],
]) test(`real EPUB keeps trustworthy boundaries for ${label}`, async () => {
  const result = await extractEpub(epub({ body: chapter(body) })); assert.equal(result.units[0].text, expected);
  const matches = retrieveStudyPassages(indexStudyDocument(result), query); assert.equal(matches.length, 1); assert.equal(matches[0].passage.text, expected);
  assert.match(matches[0].passage.label, /^EPUB 단원 1/);
});

for (const [label, stream, expected, query, checkItems] of [
  ['contiguous font-split word', 'BT /F1 12 Tf 72 720 Td (gram) Tj /F2 12 Tf (mar) Tj ET', 'grammar', 'grammar', items => {
    const text = items.filter(item => item.str); assert.deepEqual(text.map(item => item.str), ['gram', 'mar']);
    assert.notEqual(text[0].fontName, text[1].fontName); assert.ok(Math.abs(text[0].transform[4] + text[0].width - text[1].transform[4]) < 0.001);
  }],
  ['explicit space across fonts', 'BT /F1 12 Tf 72 720 Td (hello) Tj /F2 12 Tf ( world) Tj ET', 'hello world', 'world', items => assert.ok(items.some(item => /^\s+$/.test(item.str ?? '')))],
  ['positioned words with a real gap', 'BT /F1 12 Tf 72 720 Td (hello) Tj 40 0 Td /F2 12 Tf (world) Tj ET', 'hello world', 'world', items => assert.ok(items.some(item => /^\s+$/.test(item.str ?? '')))],
  ['separate columns retain a boundary', 'BT /F1 12 Tf 72 720 Td (left) Tj 230 0 Td /F2 12 Tf (right) Tj ET', 'left right', 'right', () => {}],
  ['explicit next line including empty EOL marker', 'BT /F1 12 Tf 72 720 Td (hello) Tj 0 -20 Td /F2 12 Tf (world) Tj ET', 'hello world', 'world', items => assert.ok(items.some(item => item.str === '' && item.hasEOL === true))],
  ['content-stream order is not coordinate sorted', 'BT /F1 12 Tf 72 700 Td (second) Tj 0 20 Td /F2 12 Tf (first) Tj ET', 'second first', 'first', () => {}],
  ['mixed-font inline punctuation', 'BT /F1 12 Tf 72 720 Td (Hello) Tj /F2 12 Tf (,) Tj /F1 12 Tf ( world.) Tj ET', 'Hello, world.', 'world', () => {}],
  ['rotated runs stay conservatively separate', 'BT /F1 12 Tf 0 1 -1 0 72 720 Tm (gram) Tj /F2 12 Tf (mar) Tj ET', 'gram mar', 'mar', items => assert.ok(items.some(item => item.transform?.[0] === 0))],
]) test(`real PDF boundary extraction: ${label}`, async () => {
  const task = getDocument(privatePdfOptions(textRunsPDF(stream)));
  try {
    const document = await task.promise; const items = (await (await document.getPage(1)).getTextContent()).items; checkItems(items);
    const result = await readPdfText(document); assert.equal(result.units[0].text, expected);
    const matches = retrieveStudyPassages(indexStudyDocument(result), query); assert.equal(matches.length, 1); assert.equal(matches[0].passage.text, expected);
    assert.match(matches[0].passage.label, /^PDF 파일 페이지 1/);
  } finally { await task.destroy(); }
});
