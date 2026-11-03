import { SafeDocumentError } from './documentModel.ts';
import { BoundedZip, safeArchivePath } from './boundedZip.ts';
import { cancelled, DOCUMENT_LIMITS, normalizeDocumentText } from './documentModel.ts';
import type { ExtractedDocument, ExtractedUnit } from './documentModel.ts';
const NS_CONTAINER = 'urn:oasis:names:tc:opendocument:xmlns:container';
const NS_PACKAGE = 'http://www.idpf.org/2007/opf';
const NS_XHTML = 'http://www.w3.org/1999/xhtml';
const XML_LIMIT = 1_000_000;
function xml(text: string, namespace: string, root: string): Document {
  if (text.length > XML_LIMIT || /<!\s*(?:DOCTYPE|ENTITY)\b/i.test(text)) throw new SafeDocumentError('EPUB의 DTD·엔터티 선언 또는 너무 큰 XML은 지원하지 않습니다.');
  // Conservative preflight before allocating a DOM. Comments/CDATA are not needed for text extraction.
  if (text.includes('<![CDATA[') || text.includes('<!--') || (text.match(/</g)?.length ?? 0) > 25_000) throw new SafeDocumentError('EPUB XML 토큰 한도를 넘었거나 지원하지 않는 주석·CDATA를 포함합니다.');
  let depth = 0, tokens = 0, position = 0;
  while ((position = text.indexOf('<', position)) !== -1) {
    if (++tokens > 25_000) throw new SafeDocumentError('EPUB XML 토큰 한도를 넘었습니다.');
    const start = position++; let quote = '';
    for (; position < text.length; position++) {
      const character = text[position]!;
      if (quote) { if (character === quote) quote = ''; continue; }
      if (character === '"' || character === "'") { quote = character; continue; }
      if (character === '>') break;
    }
    if (position >= text.length || quote) throw new SafeDocumentError('EPUB XML 토큰을 확인하지 못했습니다.');
    const token = text.slice(start, position + 1); position++;
    if (token.startsWith('<?xml ') && token.endsWith('?>') && start === 0) continue;
    if (token.startsWith('<?') || token.startsWith('<!')) throw new SafeDocumentError('EPUB 처리 명령과 선언은 지원하지 않습니다.');
    if (token.startsWith('</')) depth--;
    else if (!/\/\s*>$/.test(token)) depth++;
    if (depth < 0 || depth > 100) throw new SafeDocumentError('EPUB XML의 깊이 한도를 넘었습니다.');
  }
  const document = new DOMParser().parseFromString(text, 'application/xml');
  if (document.getElementsByTagName('parsererror').length || document.documentElement.localName !== root || document.documentElement.namespaceURI !== namespace) throw new SafeDocumentError('EPUB XML 구조를 확인하지 못했습니다.');
  // Iterative bounded walk prevents recursive user-content processing and limits pathological DOMs.
  const stack: Array<{ node: Node; depth: number }> = [{ node: document.documentElement, depth: 0 }]; let nodes = 0;
  while (stack.length) {
    const current = stack.pop()!;
    if (++nodes > 25_000 || current.depth > 100) throw new SafeDocumentError('EPUB XML의 깊이 또는 노드 한도를 넘었습니다.');
    for (const child of current.node.childNodes) stack.push({ node: child, depth: current.depth + 1 });
  }
  return document;
}
const descendants = (parent: Element | Document, namespace: string, name: string) => Array.from(parent.getElementsByTagNameNS(namespace, name));
function resolvePackagePath(packagePath: string, href: string): string {
  // A narrow safe subset: no URL, fragment, query, percent-encoding, or parent traversal.
  safeArchivePath(href);
  const base = packagePath.includes('/') ? packagePath.slice(0, packagePath.lastIndexOf('/') + 1) : '';
  return safeArchivePath(base + href);
}
function chapterText(document: Document): string {
  const bodies = descendants(document, NS_XHTML, 'body'); if (bodies.length !== 1) throw new SafeDocumentError('EPUB 본문 구조를 확인하지 못했습니다.');
  const ignored = new Set(['script', 'style', 'noscript', 'svg', 'math', 'iframe', 'object', 'audio', 'video', 'canvas']);
  const blocks = new Set(['p', 'div', 'section', 'article', 'h1', 'h2', 'h3', 'li', 'br', 'tr']);
  const stack: Array<Node | string> = [bodies[0]!]; const output: string[] = []; let length = 0;
  while (stack.length) {
    const node = stack.pop()!;
    if (typeof node === 'string') { output.push(node); continue; }
    if (node.nodeType === 3) {
      const text = node.nodeValue ?? ''; length += text.length;
      if (length > DOCUMENT_LIMITS.textCharacters) throw new SafeDocumentError('문서의 텍스트 한도를 넘었습니다.');
      output.push(text); continue;
    }
    if (node.nodeType !== 1) continue;
    const element = node as Element;
    if (element.namespaceURI !== NS_XHTML || ignored.has(element.localName) || element.hasAttribute('hidden') || element.getAttribute('aria-hidden') === 'true') continue;
    if (blocks.has(element.localName)) { output.push(' '); stack.push(' '); }
    const children = Array.from(element.childNodes);
    // Preserve text order with no HTML insertion or resource loading.
    for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]!);
  }
  return normalizeDocumentText(output.join(''));
}
export async function extractEpub(bytes: Uint8Array, signal?: AbortSignal): Promise<ExtractedDocument> {
  cancelled(signal); const archive = new BoundedZip(bytes);
  if (await archive.text('mimetype', signal) !== 'application/epub+zip') throw new SafeDocumentError('EPUB 형식 식별자가 올바르지 않습니다.');
  if (archive.has('META-INF/encryption.xml')) throw new SafeDocumentError('암호화·DRM 또는 글꼴 난독화가 포함된 EPUB은 지원하지 않습니다.');
  const container = xml(await archive.text('META-INF/container.xml', signal), NS_CONTAINER, 'container');
  const roots = descendants(container, NS_CONTAINER, 'rootfile').filter(item => item.getAttribute('media-type') === 'application/oebps-package+xml');
  if (roots.length !== 1) throw new SafeDocumentError('하나의 패키지로 구성된 EPUB만 지원합니다.');
  const packagePath = safeArchivePath(roots[0]!.getAttribute('full-path') ?? '');
  const packageDocument = xml(await archive.text(packagePath, signal), NS_PACKAGE, 'package');
  const manifests = descendants(packageDocument, NS_PACKAGE, 'manifest'), spines = descendants(packageDocument, NS_PACKAGE, 'spine');
  if (manifests.length !== 1 || spines.length !== 1) throw new SafeDocumentError('EPUB의 목차 순서를 확인하지 못했습니다.');
  const items = new Map<string, { path: string; type: string }>();
  for (const item of descendants(manifests[0]!, NS_PACKAGE, 'item')) {
    const id = item.getAttribute('id') ?? '', href = item.getAttribute('href') ?? '';
    if (!id || id.length > 256 || items.has(id)) throw new SafeDocumentError('EPUB의 항목 ID가 중복되었거나 올바르지 않습니다.');
    // Reject external resources in the manifest, even though non-spine resources are never opened.
    items.set(id, { path: resolvePackagePath(packagePath, href), type: item.getAttribute('media-type') ?? '' });
  }
  const spine = descendants(spines[0]!, NS_PACKAGE, 'itemref');
  if (!spine.length || spine.length > DOCUMENT_LIMITS.units) throw new SafeDocumentError('EPUB 단원 수는 1–250개까지 지원합니다.');
  const units: ExtractedUnit[] = []; const seen = new Set<string>(); let total = 0;
  for (const [index, ref] of spine.entries()) {
    cancelled(signal); const item = items.get(ref.getAttribute('idref') ?? '');
    if (!item || item.type !== 'application/xhtml+xml' || seen.has(item.path)) throw new SafeDocumentError('지원되지 않거나 중복된 EPUB 본문 항목입니다.');
    seen.add(item.path);
    const chapter = xml(await archive.text(item.path, signal), NS_XHTML, 'html');
    const text = chapterText(chapter); total += text.length;
    if (total > DOCUMENT_LIMITS.textCharacters) throw new SafeDocumentError('문서의 추출 텍스트 한도(600,000자)를 넘었습니다.');
    const heading = descendants(chapter, NS_XHTML, 'h1')[0]?.textContent ?? descendants(chapter, NS_XHTML, 'title')[0]?.textContent ?? '';
    units.push({ label: `EPUB 단원 ${index + 1}${heading.trim() ? ' · ' + normalizeDocumentText(heading).slice(0, 80) : ''}`, text });
  }
  const title = descendants(packageDocument, 'http://purl.org/dc/elements/1.1/', 'title')[0]?.textContent ?? '';
  const author = descendants(packageDocument, 'http://purl.org/dc/elements/1.1/', 'creator')[0]?.textContent ?? '';
  cancelled(signal);
  return { format: 'epub', suggestedTitle: normalizeDocumentText([title, author].filter(Boolean).join(' · ')).slice(0, 160), units,
    warnings: ['EPUB 순서는 패키지의 spine 기준입니다. 페이지 번호는 만들지 않습니다.', '스타일·그림·수식·숨김 요소를 재현하지 않습니다. 추출문과 출처를 원본에서 확인하세요.'] };
}
