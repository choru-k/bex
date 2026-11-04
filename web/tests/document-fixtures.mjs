import { deflateRawSync } from 'node:zlib';
import { crc32 } from '../src/study/documents/boundedZip.ts';
export function zip(entries) {
  const locals = [], centrals = []; let offset = 0;
  for (const [name, content, options = {}] of entries) {
    const filename = Buffer.from(name); const raw = Buffer.from(content); const method = options.method ?? 0;
    const bytes = method === 8 ? deflateRawSync(raw) : raw;
    const crc = options.crc ?? crc32(raw); const size = options.size ?? raw.length; const flags = options.flags ?? 0x800;
    const local = Buffer.alloc(30); local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4);
    local.writeUInt16LE(flags, 6); local.writeUInt16LE(method, 8); local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(bytes.length, 18); local.writeUInt32LE(size, 22); local.writeUInt16LE(filename.length, 26);
    const central = Buffer.alloc(46); central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6);
    central.writeUInt16LE(flags, 8); central.writeUInt16LE(method, 10); central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(bytes.length, 20); central.writeUInt32LE(size, 24); central.writeUInt16LE(filename.length, 28);
    central.writeUInt32LE(options.attributes ?? 0, 38); central.writeUInt32LE(offset, 42);
    locals.push(local, filename, bytes); centrals.push(central, filename); offset += local.length + filename.length + bytes.length;
  }
  const centralBytes = Buffer.concat(centrals); const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(centralBytes.length, 12); end.writeUInt32LE(offset, 16);
  return new Uint8Array(Buffer.concat([...locals, centralBytes, end]));
}
export const chapter = (body = '<h1>Chapter One</h1><p>Accurate writing keeps meaning.</p>', extra = '') =>
  `${extra}<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Synthetic chapter</title></head><body>${body}</body></html>`;
export const packageXML = (items = '<item id="one" href="one.xhtml" media-type="application/xhtml+xml"/>', spine = '<itemref idref="one"/>') =>
  `<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Synthetic Book</dc:title><dc:creator>Test Author</dc:creator></metadata><manifest>${items}</manifest><spine>${spine}</spine></package>`;
export function epub({ body, packageText = packageXML(), additional = [], options = {}, container } = {}) {
  return zip([['mimetype', 'application/epub+zip'], ['META-INF/container.xml', container ?? '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'],
    ['OPS/book.opf', packageText], ['OPS/one.xhtml', body ?? chapter(), options], ...additional]);
}
export function simplePDF(text = 'Synthetic accurate writing keeps meaning.', catalogExtra = '') {
  const stream = `BT /F1 12 Tf 72 720 Td (${text.replace(/[()\\]/g, '\\$&')}) Tj ET`;
  const objects = [`<< /Type /Catalog /Pages 2 0 R ${catalogExtra} >>`, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`];
  let result = '%PDF-1.7\n'; const offsets = [0];
  for (const [index, object] of objects.entries()) { offsets.push(Buffer.byteLength(result)); result += `${index + 1} 0 obj\n${object}\nendobj\n`; }
  const start = Buffer.byteLength(result); result += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) result += `${String(offset).padStart(10, '0')} 00000 n \n`;
  result += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`;
  return new Uint8Array(Buffer.from(result));
}
/** Real PDF text-run fixture: two standard fonts and caller-specified content operators. */
export function textRunsPDF(stream) {
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>',
    `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`];
  let pdf = '%PDF-1.7\n'; const offsets = [0];
  for (const [index, object] of objects.entries()) { offsets.push(Buffer.byteLength(pdf)); pdf += `${index + 1} 0 obj\n${object}\nendobj\n`; }
  const start = Buffer.byteLength(pdf); pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets.slice(1)) pdf += `${String(offset).padStart(10, '0')} 00000 n \n`;
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${start}\n%%EOF\n`;
  return new Uint8Array(Buffer.from(pdf));
}
