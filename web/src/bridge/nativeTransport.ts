/** Credential-free renderer adapter. Native host remains the security/consent boundary. */
import { makeRequest, parseResult } from '../core/model.ts';
import type { CorrectionRequest, CorrectionResult, CorrectionTransport } from '../core/model.ts';

export const BRIDGE_VERSION = 1;
export const MAX_BRIDGE_BYTES = 128_000;
export interface NativeEndpoint {
  /** Only the packaged native host may supply this endpoint; never a window message listener. */
  postMessage(json: string): void;
  subscribe(listener: (json: string) => void): () => void;
}
export interface BridgeCapabilities {
  providerName: string;
  perRequestConsent: true;
}
interface Pending {
  kind: 'hello' | 'correct';
  original?: string;
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
  finish: () => void;
}
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const only = (value: Record<string, unknown>, keys: string[]) =>
  Object.keys(value).every(key => keys.includes(key));
const abortError = () => new DOMException('Correction cancelled.', 'AbortError');
function encode(value: unknown): string {
  const json = JSON.stringify(value);
  if (new TextEncoder().encode(json).length > MAX_BRIDGE_BYTES) throw new Error('Bridge message is too large.');
  return json;
}
function validatedRequest(value: CorrectionRequest): CorrectionRequest {
  if (!record(value) || value.protocolVersion !== 1 ||
      !only(value, ['protocolVersion', 'text', 'policy', 'source'])) throw new Error('Invalid correction request.');
  return makeRequest(value.text, value.policy, value.source);
}

/** Not installed in the fixture lab. connect() must succeed before check() can send writing. */
export class NativeCorrectionTransport implements CorrectionTransport {
  readonly kind = 'native' as const;
  private readonly endpoint: NativeEndpoint;
  private readonly sessionID = crypto.randomUUID();
  private readonly timeoutMs: number;
  private readonly pending = new Map<string, Pending>();
  private unsubscribe: (() => void) | undefined;
  private capabilities: BridgeCapabilities | null = null;
  private closed = false;
  private connecting = false;

  constructor(endpoint: NativeEndpoint, timeoutMs = 30_000) {
    if (!Number.isFinite(timeoutMs) || timeoutMs < 1 || timeoutMs > 120_000) throw new Error('Invalid bridge timeout.');
    this.endpoint = endpoint;
    this.timeoutMs = timeoutMs;
    this.unsubscribe = endpoint.subscribe(json => this.receive(json));
  }

  async connect(signal: AbortSignal): Promise<BridgeCapabilities> {
    if (this.closed) throw new Error('Bridge is closed.');
    if (signal.aborted) throw abortError();
    if (this.capabilities) return { ...this.capabilities };
    if (this.connecting) throw new Error('Bridge handshake is already pending.');
    this.connecting = true;
    try {
      const capabilities = await this.exchange('hello', undefined, signal) as BridgeCapabilities;
      if (this.closed) throw new Error('Bridge is closed.');
      if (signal.aborted) throw abortError();
      this.capabilities = capabilities;
      return { ...capabilities };
    } finally { this.connecting = false; }
  }

  async check(value: CorrectionRequest, signal: AbortSignal): Promise<CorrectionResult> {
    if (this.closed) throw new Error('Bridge is closed.');
    if (signal.aborted) throw abortError();
    if (!this.capabilities) throw new Error('Native provider is not connected.');
    const request = validatedRequest(value);
    if (this.pending.size >= 4) throw new Error('Too many pending corrections.');
    return await this.exchange('correct', request, signal) as CorrectionResult;
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.capabilities = null;
    for (const [requestID, pending] of [...this.pending]) {
      pending.finish();
      this.cancel(requestID);
      pending.reject(new Error('Bridge is closed.'));
    }
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  private cancel(requestID: string): void {
    // Cancellation is best effort. A late result is still rejected locally.
    try { this.endpoint.postMessage(encode({ bridgeVersion: BRIDGE_VERSION, sessionID: this.sessionID, requestID, kind: 'cancel' })); }
    catch { /* do not replace an abort/timeout with a host delivery error */ }
  }

  private exchange(kind: 'hello' | 'correct', request: CorrectionRequest | undefined, signal: AbortSignal): Promise<unknown> {
    const requestID = crypto.randomUUID();
    const message = encode({ bridgeVersion: BRIDGE_VERSION, sessionID: this.sessionID, requestID, kind, ...(request ? { request } : {}) });
    return new Promise((resolve, reject) => {
      const finish = () => { clearTimeout(timer); signal.removeEventListener('abort', onAbort); this.pending.delete(requestID); };
      const fail = (error: Error) => { finish(); this.cancel(requestID); reject(error); };
      const onAbort = () => fail(abortError());
      const timer = setTimeout(() => fail(new Error('Native provider timed out.')), this.timeoutMs);
      this.pending.set(requestID, { kind, original: request?.text, resolve, reject, finish });
      signal.addEventListener('abort', onAbort, { once: true });
      if (signal.aborted) { onAbort(); return; }
      try { this.endpoint.postMessage(message); }
      catch { finish(); reject(new Error('Native bridge is unavailable.')); }
    });
  }

  private receive(json: string): void {
    if (this.closed || typeof json !== 'string' || json.length > MAX_BRIDGE_BYTES ||
        new TextEncoder().encode(json).length > MAX_BRIDGE_BYTES) return;
    let message: unknown;
    try { message = JSON.parse(json); } catch { return; }
    if (!record(message) || message.sessionID !== this.sessionID || typeof message.requestID !== 'string') return;
    const pending = this.pending.get(message.requestID);
    if (!pending) return;
    const fail = () => { pending.finish(); this.cancel(message.requestID as string); pending.reject(new Error('Invalid native provider response.')); };
    if (message.bridgeVersion !== BRIDGE_VERSION ||
        !only(message, ['bridgeVersion', 'sessionID', 'requestID', 'kind', 'capabilities', 'result', 'code'])) { fail(); return; }
    if (message.kind === 'error') {
      if (!only(message, ['bridgeVersion', 'sessionID', 'requestID', 'kind', 'code']) ||
          !['consent-denied', 'unavailable', 'provider-failed'].includes(message.code as string)) { fail(); return; }
      pending.finish();
      // Never display arbitrary provider error text, which may contain prompts or credentials.
      pending.reject(new Error(message.code === 'consent-denied' ? 'Native consent was not granted.' : 'Native provider could not complete the correction.'));
      return;
    }
    try {
      let result: unknown;
      if (pending.kind === 'hello' && message.kind === 'capabilities' &&
          only(message, ['bridgeVersion', 'sessionID', 'requestID', 'kind', 'capabilities'])) {
        const c = message.capabilities;
        if (!record(c) || !only(c, ['providerName', 'perRequestConsent', 'operations']) ||
            typeof c.providerName !== 'string' || !c.providerName.trim() || c.providerName.length > 80 ||
            c.perRequestConsent !== true || !Array.isArray(c.operations) || c.operations.length !== 2 ||
            !c.operations.includes('correct') || !c.operations.includes('cancel')) throw new Error();
        result = { providerName: c.providerName.trim(), perRequestConsent: true };
      } else if (pending.kind === 'correct' && message.kind === 'result' &&
          only(message, ['bridgeVersion', 'sessionID', 'requestID', 'kind', 'result'])) {
        const parsed = parseResult(message.result, pending.original!);
        if (parsed.provenance !== 'provider') throw new Error();
        result = parsed;
      } else throw new Error();
      pending.finish(); pending.resolve(result);
    } catch { fail(); }
  }
}
