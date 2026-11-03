import { SafeDocumentError } from './documentModel.ts';
import { cancelled, DOCUMENT_LIMITS, normalizeDocumentText } from './documentModel.ts';
import type { ExtractedDocument, ExtractedUnit } from './documentModel.ts';
export interface PDFTextReader {
  numPages: number;
  getPage(number: number): Promise<{ getTextContent(): Promise<{ items: unknown[] }>; cleanup(): unknown }>;
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
      const parts: string[] = []; let pageLength = 0;
      for (const item of content.items) {
        if (!item || typeof item !== 'object' || !('str' in item)) continue;
        if (typeof item.str !== 'string') throw new SafeDocumentError('PDF 텍스트 형식을 확인하지 못했습니다.');
        pageLength += item.str.length + 1;
        if (pageLength + total > DOCUMENT_LIMITS.textCharacters) throw new SafeDocumentError('문서의 추출 텍스트 한도(600,000자)를 넘었습니다.');
        parts.push(item.str, ' ');
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
