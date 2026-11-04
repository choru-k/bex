import { SafeDocumentError } from './documentModel.ts';
import { cancelled, DOCUMENT_LIMITS, normalizeDocumentText } from './documentModel.ts';
import type { ExtractedDocument, ExtractedUnit } from './documentModel.ts';
export interface PDFTextReader {
  numPages: number;
  getPage(number: number): Promise<{ getTextContent(): Promise<{ items: unknown[] }>; cleanup(): unknown }>;
}
interface TextRun { str: string; dir?: unknown; width?: unknown; height?: unknown; transform?: unknown; hasEOL?: unknown }
const POSITION_TOLERANCE = 0.01; // PDF units: numerical roundoff, far below a normal word space.
const AXIS_TOLERANCE = 1e-10; // Relative numerical tolerance, not permission to join rotated text.
function horizontalGeometry(run: TextRun): { x: number; y: number; width: number; height: number; a: number; d: number } | null {
  if (run.dir !== 'ltr' || typeof run.hasEOL !== 'boolean' ||
      typeof run.width !== 'number' || !Number.isFinite(run.width) || run.width <= 0 ||
      typeof run.height !== 'number' || !Number.isFinite(run.height) || run.height <= 0 ||
      !Array.isArray(run.transform) || run.transform.length !== 6 ||
      !run.transform.every(value => typeof value === 'number' && Number.isFinite(value))) return null;
  const [a, b, c, d, x, y] = run.transform as [number, number, number, number, number, number];
  if (a <= 0 || d <= 0 || Math.abs(b) > a * AXIS_TOLERANCE || Math.abs(c) > d * AXIS_TOLERANCE) return null;
  return { x, y, width: run.width, height: run.height, a, d };
}
function runSeparator(previous: TextRun | null, next: TextRun): string {
  if (!previous || /\s$/u.test(previous.str) || /^\s/u.test(next.str)) return '';
  if (previous.hasEOL === true) return ' ';
  const before = horizontalGeometry(previous), after = horizontalGeometry(next);
  // Only join an unambiguous same-line LTR continuation. Font names may differ:
  // style changes can split one word. Gaps, overlap, rotation/skew, RTL/vertical,
  // mixed sizes, and absent/invalid geometry retain a conservative separator.
  if (!before || !after) return ' ';
  // A fixed tolerance must not swallow an entire glyph when text is very small.
  const tolerance = Math.min(POSITION_TOLERANCE, Math.min(before.width, after.width, before.height, after.height) * 1e-4);
  const same = (a: number, b: number) => Math.abs(a - b) <= tolerance;
  return same(before.y, after.y) && same(before.height, after.height) &&
    same(before.a, after.a) && same(before.d, after.d) && same(before.x + before.width, after.x) ? '' : ' ';
}
/** Pure reader contract for independent limits/ordering tests; extraction never executes annotations/actions. */
export async function readPdfText(document: PDFTextReader, signal?: AbortSignal): Promise<ExtractedDocument> {
  if (!Number.isInteger(document.numPages) || document.numPages < 1 || document.numPages > DOCUMENT_LIMITS.units) throw new SafeDocumentError('PDF는 1–250페이지까지 지원합니다.');
  const units: ExtractedUnit[] = []; let total = 0, emptyPages = 0;
  for (let number = 1; number <= document.numPages; number++) {
    cancelled(signal); const page = await document.getPage(number); cancelled(signal);
    try {
      const content = await page.getTextContent(); cancelled(signal);
      if (!Array.isArray(content.items) || content.items.length > 30_000) throw new SafeDocumentError('PDF 페이지의 텍스트 항목 한도를 넘었습니다.');
      const parts: string[] = []; let pageLength = 0; let previous: TextRun | null = null;
      for (const item of content.items) {
        if (!item || typeof item !== 'object' || !('str' in item)) continue;
        if (typeof item.str !== 'string') throw new SafeDocumentError('PDF 텍스트 형식을 확인하지 못했습니다.');
        const run = item as TextRun;
        // PDF.js can express a line ending as an empty text item.
        if (!run.str) {
          if (run.hasEOL === true) { parts.push(' '); pageLength++; previous = null; }
        } else {
          const separator = runSeparator(previous, run);
          pageLength += separator.length + run.str.length;
          parts.push(separator, run.str); previous = run;
        }
        if (pageLength + total > DOCUMENT_LIMITS.textCharacters) throw new SafeDocumentError('문서의 추출 텍스트 한도(600,000자)를 넘었습니다.');
      }
      const text = normalizeDocumentText(parts.join('')); total += pageLength; if (!text) emptyPages++;
      units.push({ label: `PDF 파일 페이지 ${number}`, text });
    } finally { page.cleanup(); }
  }
  return { format: 'pdf', suggestedTitle: '', units, warnings: [
    'PDF 출처는 인쇄된 쪽수가 아닌 파일의 페이지 순서입니다. 다단 편집·표·합자 등은 추출 순서가 달라질 수 있습니다.',
    ...(emptyPages ? [`텍스트가 없는 페이지 ${emptyPages}개가 있습니다. 이미지·스캔 PDF의 OCR은 지원하지 않습니다.`] : []),
  ] };
}
