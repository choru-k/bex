/** Portable simulation contract. Not a native bridge or an authorization boundary. */
import { DEFAULT_POLICY, makeRequest, parsePolicy, parseResult } from '../core/model.ts';
import type { CorrectionResult, CorrectionTransport, LearningPolicy } from '../core/model.ts';

export const HOST_EVENT_VERSION = 1 as const;
export const MAX_FEEDBACK_ITEMS = 20;
export const MAX_PENDING_COACHING = 4;
export const DEFAULT_COACHING_TIMEOUT_MS = 8_000;
export interface HostTarget { sessionId: string; appId: string; conversationId: string }
export interface DraftSnapshot extends HostTarget { revision: number; text: string }
/** Only the host's confirmed original-user-message send can produce this observation. */
export interface SentObservation extends HostTarget {
  version: 1;
  type: 'user-message-sent';
  messageId: string;
  text: string;
}
export interface SentMessage extends HostTarget { messageId: string; text: string; origin: 'original' | 'fix-and-send' }
export type Delivery = { status: 'sent' } | { status: 'not-sent' } | { status: 'unknown' };
export interface ReviewHost {
  /** Snapshot must come from the host, not from model output. */
  snapshot(): DraftSnapshot;
  /** One atomic host operation. No separately timed replace + keypress implementation. */
  compareAndSend(expected: DraftSnapshot, corrected: string, operationId: string): Delivery;
}
export type FeedbackState = 'pending' | 'ready' | 'unavailable' | 'skipped';
export interface FeedbackItem {
  observation: SentObservation;
  state: FeedbackState;
  policy: LearningPolicy;
  result?: CorrectionResult;
}
export type ReviewState =
  | { status: 'idle' }
  | { status: 'pending'; id: string; draft: DraftSnapshot }
  | { status: 'ready'; id: string; draft: DraftSnapshot; result: CorrectionResult }
  | { status: 'blocked' | 'unavailable' | 'sent' | 'unknown' };
export interface HostFlowState { feedback: FeedbackItem[]; review: ReviewState }
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);
const identifier = (value: unknown): value is string =>
  typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value);
const validText = (value: unknown): value is string =>
  typeof value === 'string' && value.trim().length > 0 && value.length <= 12_000;
const validTarget = (value: Record<string, unknown>) =>
  identifier(value.sessionId) && identifier(value.appId) && identifier(value.conversationId);
const exactKeys = (value: Record<string, unknown>, keys: string[]) =>
  Object.keys(value).length === keys.length && Object.keys(value).every(key => keys.includes(key));
export function parseSentObservation(value: unknown): SentObservation {
  if (!record(value) || !exactKeys(value, ['version', 'type', 'sessionId', 'appId', 'conversationId', 'messageId', 'text']) ||
      value.version !== HOST_EVENT_VERSION || value.type !== 'user-message-sent' ||
      !validTarget(value) || !identifier(value.messageId) || !validText(value.text)) {
    throw new Error('Invalid host observation');
  }
  return { version: 1, type: 'user-message-sent', sessionId: value.sessionId as string,
    appId: value.appId as string, conversationId: value.conversationId as string,
    messageId: value.messageId, text: value.text };
}
function parseDraft(value: unknown): DraftSnapshot {
  if (!record(value) || !exactKeys(value, ['sessionId', 'appId', 'conversationId', 'revision', 'text']) ||
      !validTarget(value) || !Number.isSafeInteger(value.revision) || (value.revision as number) < 0 || !validText(value.text)) {
    throw new Error('Invalid host draft');
  }
  return { sessionId: value.sessionId as string, appId: value.appId as string,
    conversationId: value.conversationId as string, revision: value.revision as number, text: value.text };
}
export const sameDraft = (a: DraftSnapshot, b: DraftSnapshot): boolean =>
  a.sessionId === b.sessionId && a.appId === b.appId && a.conversationId === b.conversationId &&
  a.revision === b.revision && a.text === b.text;
const observationKey = (event: SentObservation) => JSON.stringify([event.sessionId, event.appId, event.conversationId, event.messageId]);

/**
 * Coaching has no send/replace capability. It runs only after an original send.
 * Review is an explicit separate operation with a stale-draft compare-and-send fence.
 * This implementation is fixture-only; native provider consent is NOT implied.
 */
export class HostFlow {
  private readonly transport: CorrectionTransport;
  private readonly timeoutMs: number;
  private readonly changed: () => void;
  private policy: LearningPolicy = { ...DEFAULT_POLICY };
  private feedback: FeedbackItem[] = [];
  private pending = new Map<string, { controller: AbortController; timer: ReturnType<typeof setTimeout> }>();
  // Cancellation changes presentation immediately, but is not proof of transport completion.
  private coachingOutstanding = new Set<AbortController>();
  private review: ReviewState = { status: 'idle' };
  private reviewPending: { controller: AbortController; timer: ReturnType<typeof setTimeout> } | null = null;
  private reviewOutstanding: AbortController | null = null;
  private sequence = 0;
  private readonly instanceId = crypto.randomUUID();
  private disposed = false;
  constructor(transport: CorrectionTransport, changed: () => void = () => {}, timeoutMs = DEFAULT_COACHING_TIMEOUT_MS) {
    if (transport.kind !== 'fixture') throw new Error('Host flow is simulation-only. Live provider admission is not wired.');
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) throw new Error('Invalid timeout');
    this.transport = transport; this.changed = changed; this.timeoutMs = timeoutMs;
  }
  snapshot(): HostFlowState { return structuredClone({ feedback: this.feedback, review: this.review }); }
  configure(policy: LearningPolicy): void {
    const next = parsePolicy(policy);
    if (JSON.stringify(next) !== JSON.stringify(this.policy)) { this.policy = next; this.cancelReview(); }
  }
  private notify(): void { try { this.changed(); } catch { /* A view failure cannot affect the host's send. */ } }
  /** Never throws, never delays the original send, never calls the host. */
  observeSent(raw: unknown): void {
    if (this.disposed) return;
    let event: SentObservation;
    try { event = parseSentObservation(raw); } catch { return; }
    const key = observationKey(event);
    if (this.feedback.some(item => observationKey(item.observation) === key)) return;
    // Keep memory bounded; evicted requests cannot later reintroduce old cards.
    if (this.feedback.length === MAX_FEEDBACK_ITEMS) {
      const oldest = this.feedback.shift()!; this.stopCoaching(observationKey(oldest.observation));
    }
    const item: FeedbackItem = { observation: event, state: 'pending', policy: { ...this.policy } };
    this.feedback.push(item);
    if (this.coachingOutstanding.size >= MAX_PENDING_COACHING) { item.state = 'skipped'; this.notify(); return; }
    const controller = new AbortController();
    const timer = setTimeout(() => {
      if (!this.pending.has(key)) return;
      this.stopCoaching(key); item.state = 'unavailable'; this.notify();
    }, this.timeoutMs);
    this.coachingOutstanding.add(controller);
    this.pending.set(key, { controller, timer }); this.notify();
    // Microtask separation: even a synchronously throwing transport cannot touch send.
    void Promise.resolve().then(() => {
      if (controller.signal.aborted) throw new Error('Cancelled');
      return this.transport.check(makeRequest(event.text, item.policy), controller.signal);
    }).then(rawResult => {
      if (this.disposed || controller.signal.aborted || !this.pending.has(key)) return;
      item.result = parseResult(rawResult, event.text); item.state = 'ready';
    }).catch(() => {
      if (!this.disposed && !controller.signal.aborted && this.pending.has(key)) item.state = 'unavailable';
    }).finally(() => {
      this.coachingOutstanding.delete(controller);
      if (this.pending.get(key)?.controller !== controller) return;
      this.stopCoaching(key); this.notify();
    });
  }
  private stopCoaching(key: string): void {
    const pending = this.pending.get(key);
    if (pending) { clearTimeout(pending.timer); pending.controller.abort(); this.pending.delete(key); }
  }
  beginReview(host: ReviewHost): void {
    if (this.disposed || this.review.status === 'unknown') return;
    this.cancelReview();
    // At most one unsettled review per instance, even if its transport ignores abort.
    if (this.reviewOutstanding) { this.review = { status: 'unavailable' }; this.notify(); return; }
    let draft: DraftSnapshot;
    try { draft = parseDraft(host.snapshot()); } catch { this.review = { status: 'blocked' }; this.notify(); return; }
    const id = `review-${this.instanceId}-${++this.sequence}`;
    const controller = new AbortController();
    const timer = setTimeout(() => {
      if (this.reviewPending?.controller !== controller) return;
      this.stopReview(); this.review = { status: 'unavailable' }; this.notify();
    }, this.timeoutMs);
    this.reviewOutstanding = controller;
    this.reviewPending = { controller, timer };
    this.review = { status: 'pending', id, draft }; this.notify();
    const request = makeRequest(draft.text, this.policy);
    void Promise.resolve().then(() => {
      if (controller.signal.aborted) throw new Error('Cancelled');
      return this.transport.check(request, controller.signal);
    }).then(rawResult => {
      if (this.disposed || controller.signal.aborted || this.reviewPending?.controller !== controller) return;
      const result = parseResult(rawResult, draft.text);
      let current: DraftSnapshot;
      try { current = parseDraft(host.snapshot()); } catch { this.review = { status: 'blocked' }; return; }
      if (!sameDraft(draft, current)) { this.review = { status: 'blocked' }; return; }
      this.review = { status: 'ready', id, draft, result };
    }).catch(() => {
      if (!this.disposed && !controller.signal.aborted && this.reviewPending?.controller === controller) this.review = { status: 'unavailable' };
    }).finally(() => {
      if (this.reviewOutstanding === controller) this.reviewOutstanding = null;
      if (this.reviewPending?.controller !== controller) return;
      this.stopReview(); this.notify();
    });
  }
  /** Caller supplies the exact review shown to the user, never a corrected string. */
  confirmFixAndSend(host: ReviewHost, reviewId: string): Delivery {
    if (this.disposed || this.review.status !== 'ready' || this.review.id !== reviewId) return { status: 'not-sent' };
    const review = this.review;
    // Consume approval before calling host, including thrown/uncertain outcomes.
    this.review = { status: 'blocked' };
    let delivery: Delivery = { status: 'not-sent' };
    let attempted = false;
    try {
      if (sameDraft(review.draft, parseDraft(host.snapshot()))) {
        attempted = true;
        const outcome = host.compareAndSend(review.draft, review.result.corrected, review.id);
        delivery = outcome?.status === 'sent' || outcome?.status === 'not-sent' ? outcome : { status: 'unknown' };
      }
    } catch { delivery = { status: attempted ? 'unknown' : 'not-sent' }; }
    this.review = { status: delivery.status === 'not-sent' ? 'blocked' : delivery.status }; this.notify();
    return delivery;
  }
  private stopReview(): void {
    if (this.reviewPending) { clearTimeout(this.reviewPending.timer); this.reviewPending.controller.abort(); this.reviewPending = null; }
  }
  cancelReview(): void {
    this.stopReview();
    // An uncertain delivery must be inspected at the host, not retried by dismissing UI.
    if (this.review.status !== 'unknown') this.review = { status: 'idle' };
    this.notify();
  }
  /** Requests cancellation; does not promise transport drain or cross-instance quiescence. */
  dispose(): void {
    this.disposed = true; this.stopReview();
    for (const key of this.pending.keys()) this.stopCoaching(key);
    this.feedback = []; this.review = { status: 'idle' };
  }
}

/** Memory-only host. It does not read/write another app, intercept keys, or send a network request. */
export class SimulatedHost implements ReviewHost {
  private draft: DraftSnapshot;
  private sequence = 0;
  private messages: SentMessage[] = [];
  private readonly attempts = new Set<string>();
  constructor(appId = 'chatgpt', text = '') {
    if (!identifier(appId)) throw new Error('Invalid simulated app');
    this.draft = { sessionId: 'simulation', appId, conversationId: 'conversation-1', revision: 0, text };
  }
  snapshot(): DraftSnapshot { return { ...this.draft }; }
  transcript(): SentMessage[] { return structuredClone(this.messages); }
  edit(text: string): void { this.draft = { ...this.draft, revision: this.draft.revision + 1, text }; }
  switchTarget(appId: string, conversationId = 'conversation-1'): void {
    if (!identifier(appId) || !identifier(conversationId)) throw new Error('Invalid simulated target');
    this.draft = { ...this.draft, appId, conversationId, revision: this.draft.revision + 1 };
  }
  sendOriginal(): SentObservation {
    const draft = parseDraft(this.draft);
    const messageId = `message-${++this.sequence}`;
    this.append(draft, draft.text, messageId, 'original');
    return { version: 1, type: 'user-message-sent', sessionId: draft.sessionId, appId: draft.appId,
      conversationId: draft.conversationId, messageId, text: draft.text };
  }
  compareAndSend(expected: DraftSnapshot, corrected: string, operationId: string): Delivery {
    if (this.attempts.has(operationId)) return { status: 'not-sent' };
    this.attempts.add(operationId);
    if (this.attempts.size > MAX_FEEDBACK_ITEMS * 2) this.attempts.delete(this.attempts.values().next().value!);
    if (!sameDraft(expected, this.draft) || (typeof corrected !== 'string' || !corrected.trim() || corrected.length > 24_000)) return { status: 'not-sent' };
    this.append(expected, corrected, `message-${++this.sequence}`, 'fix-and-send');
    return { status: 'sent' };
  }
  private append(draft: DraftSnapshot, text: string, messageId: string, origin: SentMessage['origin']): void {
    this.messages.push({ sessionId: draft.sessionId, appId: draft.appId, conversationId: draft.conversationId, messageId, text, origin });
    if (this.messages.length > MAX_FEEDBACK_ITEMS) this.messages.shift();
    this.draft = { ...this.draft, text: '', revision: this.draft.revision + 1 };
  }
}
