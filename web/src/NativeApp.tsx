import { useEffect, useRef, useState } from 'react';
import { App } from './App.tsx';
import { NativeCorrectionTransport } from './bridge/nativeTransport.ts';
import type { NativeEndpoint } from './bridge/nativeTransport.ts';

declare global {
  interface Window {
    /** Supplied only by the packaged host. This declaration is not authentication. */
    readonly __bexNativeCorrectionEndpoint?: NativeEndpoint;
  }
}

type Connection = { transport: NativeCorrectionTransport; providerName: string };

/** Explicit alternate entry. Never connects on mount and never falls back to fixtures. */
export function NativeApp() {
  const [ready, setReady] = useState(false);
  const [phase, setPhase] = useState<'idle' | 'connecting' | 'connected' | 'closed'>('idle');
  const [connection, setConnection] = useState<Connection | null>(null);
  const [error, setError] = useState('');
  const mounted = useRef(false);
  const attempted = useRef(false);
  const generation = useRef(0);
  const pending = useRef<AbortController | null>(null);
  const transport = useRef<NativeCorrectionTransport | null>(null);

  function dispose() {
    generation.current += 1;
    pending.current?.abort();
    pending.current = null;
    transport.current?.close();
    transport.current = null;
  }

  useEffect(() => {
    mounted.current = true;
    setReady(true);
    return () => { mounted.current = false; dispose(); };
  }, []);

  async function connect() {
    // The host binds one session per document. An attempted connection is terminal
    // on cancellation/failure; silently replacing it with another session cannot work.
    if (!ready || !mounted.current || attempted.current) return;
    attempted.current = true;
    const current = ++generation.current;
    setPhase('connecting');
    setError('');
    try {
      const endpoint = window.__bexNativeCorrectionEndpoint;
      if (!endpoint || typeof endpoint.postMessage !== 'function' || typeof endpoint.subscribe !== 'function') {
        throw new Error('Native host endpoint is unavailable.');
      }
      const next = new NativeCorrectionTransport(endpoint);
      const controller = new AbortController();
      transport.current = next;
      pending.current = controller;
      // hello contains protocol/session identifiers only, never writing or source.
      const capabilities = await next.connect(controller.signal);
      if (!mounted.current || current !== generation.current) return;
      pending.current = null;
      setConnection({ transport: next, providerName: capabilities.providerName });
      setPhase('connected');
    } catch {
      if (!mounted.current || current !== generation.current) return;
      dispose();
      setConnection(null);
      setPhase('closed');
      setError('네이티브 연결을 완료하지 못했습니다. 네이티브 호스트에서 이 화면을 새로 여세요. 샘플 결과로 대체하지 않습니다.');
    }
  }

  function disconnect() {
    dispose();
    setConnection(null);
    setPhase('closed');
    setError('연결을 종료했습니다. 다시 연결하려면 네이티브 호스트에서 이 화면을 새로 여세요.');
  }

  return <>
    <section className="shell" aria-label="Native connection" data-native-phase={phase} data-native-ready={ready}>
      <h1>Bex Native Preview</h1>
      <p>Connect native는 연결 상태와 제공자 이름만 확인하며 원문이나 자료를 보내지 않습니다.</p>
      <p>연결 후 교정 요청 시 원문·학습 설정·선택한 자료 제목, 단원, 발췌문을 호스트에 전달합니다. 제공자 전송 전 요청마다 네이티브 동의가 필요합니다.</p>
      {connection && <p role="status">전송 대상: <strong>{connection.providerName}</strong></p>}
      {phase === 'idle' && <button className="button primary" type="button" disabled={!ready} onClick={() => void connect()}>Connect native</button>}
      {phase === 'connecting' && <><p role="status">네이티브 연결 확인 중…</p><button type="button" className="button secondary" onClick={disconnect}>연결 취소</button></>}
      {phase === 'connected' && <button type="button" className="button secondary" onClick={disconnect}>연결 종료</button>}
      {error && <p className="alert error" role="alert">{error}</p>}
    </section>
    {connection && <App transport={connection.transport} providerName={connection.providerName} />}
  </>;
}
