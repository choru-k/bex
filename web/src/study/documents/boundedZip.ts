import { SafeDocumentError } from './documentModel.ts';
import { cancelled, DOCUMENT_LIMITS, validateFileBytes } from './documentModel.ts';
interface ZipEntry { path: string; method: number; flags: number; crc: number; size: number; compressed: number; start: number; end: number }
const fail = (): never => { throw new SafeDocumentError('이 EPUB ZIP 구조는 손상되었거나 지원되지 않습니다. 암호화·ZIP64·중복 경로·외부 경로는 허용하지 않습니다.'); };
const decoder = new TextDecoder('utf-8', { fatal: true });
export function safeArchivePath(value: string): string {
  if (!value || value.length > 512 || /[\\\u0000-\u001f\u007f:#?%]/.test(value) || value.startsWith('/') ||
      value.split('/').some(part => !part || part === '.' || part === '..')) return fail();
  return value;
}
export function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0); }
  return (crc ^ 0xffffffff) >>> 0;
}
/** Read-only ZIP subset; never extracts a file to disk or follows symlinks/URLs. */
export class BoundedZip {
  private readonly bytes: Uint8Array;
  private readonly entries = new Map<string, ZipEntry>();
  private expanded = 0;
  constructor(bytes: Uint8Array) {
    validateFileBytes(bytes); this.bytes = bytes;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const u16 = (at: number) => view.getUint16(at, true), u32 = (at: number) => view.getUint32(at, true);
    if (bytes.length < 22) return fail();
    let end = -1;
    for (let at = bytes.length - 22; at >= Math.max(0, bytes.length - 65_557); at--) {
      if (u32(at) === 0x06054b50 && at + 22 + u16(at + 20) === bytes.length) { end = at; break; }
    }
    if (end < 0 || u16(end + 4) || u16(end + 6) || u16(end + 8) !== u16(end + 10)) return fail();
    const count = u16(end + 10), directorySize = u32(end + 12), directory = u32(end + 16);
    if (!count || count > DOCUMENT_LIMITS.entries || directory + directorySize !== end) return fail();
    let at = directory, declaredTotal = 0; const ranges: Array<[number, number]> = [];
    for (let i = 0; i < count; i++) {
      if (at + 46 > end || u32(at) !== 0x02014b50) return fail();
      const flags = u16(at + 8), method = u16(at + 10), crc = u32(at + 16), compressed = u32(at + 20), size = u32(at + 24);
      const nameSize = u16(at + 28), extraSize = u16(at + 30), commentSize = u16(at + 32), offset = u32(at + 42);
      const unixType = (u32(at + 38) >>> 16) & 0xf000;
      if (flags & ~0x0808 || ![0, 8].includes(method) || u16(at + 34) || unixType === 0xa000 ||
          size > DOCUMENT_LIMITS.entryBytes || compressed > DOCUMENT_LIMITS.fileBytes ||
          (compressed > 0 && size > compressed * 200) || at + 46 + nameSize + extraSize + commentSize > end) return fail();
      let path: string; try { path = decoder.decode(bytes.subarray(at + 46, at + 46 + nameSize)); } catch { return fail(); }
      const directoryEntry = path.endsWith('/'); path = safeArchivePath(directoryEntry ? path.slice(0, -1) : path);
      if (this.entries.has(path) || ranges.some(range => offset >= range[0] && offset < range[1]) || offset + 30 > directory || u32(offset) !== 0x04034b50) return fail();
      const localNameSize = u16(offset + 26), localExtra = u16(offset + 28), start = offset + 30 + localNameSize + localExtra;
      let localPath: string; try { localPath = decoder.decode(bytes.subarray(offset + 30, offset + 30 + localNameSize)); } catch { return fail(); }
      if (localPath !== (directoryEntry ? path + '/' : path) || u16(offset + 6) !== flags || u16(offset + 8) !== method || start + compressed > directory ||
          (!(flags & 8) && (u32(offset + 14) !== crc || u32(offset + 18) !== compressed || u32(offset + 22) !== size)) ||
          (method === 0 && size !== compressed) || (directoryEntry && size !== 0)) return fail();
      // Zip64 extras are unsupported even when misleading legacy size fields look small.
      for (const [extraStart, extraEnd] of [[at + 46 + nameSize, at + 46 + nameSize + extraSize], [offset + 30 + localNameSize, start]]) {
        let position = extraStart!;
        while (position < extraEnd!) { if (position + 4 > extraEnd! || u16(position) === 1) return fail(); const length = u16(position + 2); position += 4 + length; if (position > extraEnd!) return fail(); }
      }
      declaredTotal += size; if (declaredTotal > DOCUMENT_LIMITS.archiveBytes) return fail();
      ranges.push([offset, start + compressed]);
      this.entries.set(path, { path, method, flags, crc, size, compressed, start, end: start + compressed });
      at += 46 + nameSize + extraSize + commentSize;
    }
    if (at !== end) return fail();
    ranges.sort((a, b) => a[0] - b[0]);
    for (let i = 1; i < ranges.length; i++) if (ranges[i]![0] < ranges[i - 1]![1]) return fail();
  }
  has(path: string): boolean { return this.entries.has(path); }
  async read(path: string, signal?: AbortSignal): Promise<Uint8Array> {
    cancelled(signal); const entry = this.entries.get(safeArchivePath(path)); if (!entry) return fail();
    const compressed = this.bytes.slice(entry.start, entry.end); let output: Uint8Array;
    if (entry.method === 0) output = compressed;
    else {
      if (typeof DecompressionStream === 'undefined') throw new SafeDocumentError('이 브라우저는 EPUB 압축 해제를 지원하지 않습니다.');
      const stream = new Blob([compressed]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
      const reader = stream.getReader(); const chunks: Uint8Array[] = []; let length = 0;
      const abort = () => { void reader.cancel().catch(() => {}); };
      signal?.addEventListener('abort', abort, { once: true });
      try {
        while (true) {
          cancelled(signal); const next = await reader.read(); cancelled(signal); if (next.done) break;
          length += next.value.length;
          if (length > entry.size || length > DOCUMENT_LIMITS.entryBytes || this.expanded + length > DOCUMENT_LIMITS.archiveBytes) { await reader.cancel(); return fail(); }
          chunks.push(next.value);
        }
      } finally { signal?.removeEventListener('abort', abort); reader.releaseLock(); }
      output = new Uint8Array(length); let offset = 0; for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.length; }
    }
    this.expanded += output.length;
    if (output.length !== entry.size || crc32(output) !== entry.crc || this.expanded > DOCUMENT_LIMITS.archiveBytes) return fail();
    cancelled(signal); return output;
  }
  async text(path: string, signal?: AbortSignal): Promise<string> {
    try { return decoder.decode(await this.read(path, signal)); } catch (error) {
      if (error instanceof Error && error.name === 'AbortError') throw error;
      throw new SafeDocumentError('EPUB 항목을 안전한 UTF-8 텍스트로 읽지 못했습니다.');
    }
  }
}
