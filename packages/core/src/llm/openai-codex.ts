import { GrammarResult, Preferences } from "./types";
import { parseGrammarResponse } from "../lib/parse-json";

const CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const AUTHORIZE_URL = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL = "https://auth.openai.com/oauth/token";
const REDIRECT_URI = "http://localhost:1455/auth/callback";
const SCOPE = "openid profile email offline_access";
const ACCOUNT_CLAIM_KEY = "https://api.openai.com/auth";
const CODEX_RESPONSES_URL = "https://chatgpt.com/backend-api/codex/responses";

export interface OpenAICodexAuthFlow {
  url: string;
  state: string;
  verifier: string;
}

export interface OpenAICodexSession {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  accountId: string;
}

interface ParsedAuthorizationInput {
  code?: string;
  state?: string;
}

function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) {
    binary += String.fromCharCode(b);
  }

  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function decodeBase64Url(input: string): string {
  const normalized = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  return atob(padded);
}

function createState(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function createPkce(): Promise<{ verifier: string; challenge: string }> {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  const verifier = encodeBase64Url(bytes);

  const hashBuffer = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(verifier),
  );
  const challenge = encodeBase64Url(new Uint8Array(hashBuffer));

  return { verifier, challenge };
}

function parseAuthorizationInput(input: string): ParsedAuthorizationInput {
  const value = input.trim();
  if (!value) return {};

  try {
    const url = new URL(value);
    return {
      code: url.searchParams.get("code") || undefined,
      state: url.searchParams.get("state") || undefined,
    };
  } catch {
    // not URL input, continue
  }

  if (value.includes("#")) {
    const [code, state] = value.split("#", 2);
    return { code, state };
  }

  if (value.includes("code=")) {
    const params = new URLSearchParams(value);
    return {
      code: params.get("code") || undefined,
      state: params.get("state") || undefined,
    };
  }

  return { code: value };
}

function extractAccountId(accessToken: string): string {
  const parts = accessToken.split(".");
  if (parts.length !== 3) {
    throw new Error("Failed to decode Codex access token.");
  }

  try {
    const payloadJson = decodeBase64Url(parts[1]);
    const payload = JSON.parse(payloadJson) as Record<string, unknown>;
    const auth = payload[ACCOUNT_CLAIM_KEY] as
      | { chatgpt_account_id?: unknown }
      | undefined;
    const accountId = auth?.chatgpt_account_id;

    if (typeof accountId === "string" && accountId.length > 0) {
      return accountId;
    }
  } catch {
    // fallthrough to error below
  }

  throw new Error("Failed to extract ChatGPT account ID from token.");
}

async function exchangeAuthorizationCode(
  code: string,
  verifier: string,
): Promise<OpenAICodexSession> {
  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code,
      code_verifier: verifier,
      redirect_uri: REDIRECT_URI,
    }),
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`Codex OAuth token exchange failed (${response.status}): ${text}`);
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const json: any = await response.json();
  if (!json.access_token || !json.refresh_token || typeof json.expires_in !== "number") {
    throw new Error("Codex OAuth token response was incomplete.");
  }

  const accessToken = json.access_token as string;
  const refreshToken = json.refresh_token as string;
  const expiresAt = Date.now() + Number(json.expires_in) * 1000;
  const accountId = extractAccountId(accessToken);

  return {
    accessToken,
    refreshToken,
    expiresAt,
    accountId,
  };
}

export async function refreshOpenAICodexSession(
  refreshToken: string,
): Promise<OpenAICodexSession> {
  const response = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
    }),
  });

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    throw new Error(`Failed to refresh Codex session (${response.status}): ${text}`);
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const json: any = await response.json();
  if (!json.access_token || !json.refresh_token || typeof json.expires_in !== "number") {
    throw new Error("Codex refresh response was incomplete.");
  }

  const accessToken = json.access_token as string;
  const refreshedToken = json.refresh_token as string;
  const expiresAt = Date.now() + Number(json.expires_in) * 1000;
  const accountId = extractAccountId(accessToken);

  return {
    accessToken,
    refreshToken: refreshedToken,
    expiresAt,
    accountId,
  };
}

export async function beginOpenAICodexOAuth(
  originator = "bex",
): Promise<OpenAICodexAuthFlow> {
  const { verifier, challenge } = await createPkce();
  const state = createState();

  const url = new URL(AUTHORIZE_URL);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("client_id", CLIENT_ID);
  url.searchParams.set("redirect_uri", REDIRECT_URI);
  url.searchParams.set("scope", SCOPE);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  url.searchParams.set("id_token_add_organizations", "true");
  url.searchParams.set("codex_cli_simplified_flow", "true");
  url.searchParams.set("originator", originator);

  return {
    url: url.toString(),
    state,
    verifier,
  };
}

export async function completeOpenAICodexOAuth(
  flow: OpenAICodexAuthFlow,
  input: string,
): Promise<OpenAICodexSession> {
  const parsed = parseAuthorizationInput(input);

  if (parsed.state && parsed.state !== flow.state) {
    throw new Error("State mismatch while completing Codex login.");
  }

  if (!parsed.code) {
    throw new Error("Missing authorization code.");
  }

  return exchangeAuthorizationCode(parsed.code, flow.verifier);
}

export function applyOpenAICodexSessionToPreferences(
  prefs: Preferences,
  session: OpenAICodexSession,
): Preferences {
  return {
    ...prefs,
    openaiCodexAccessToken: session.accessToken,
    openaiCodexRefreshToken: session.refreshToken,
    openaiCodexExpiresAt: session.expiresAt,
    openaiCodexAccountId: session.accountId,
  };
}

async function ensureOpenAICodexSession(
  prefs: Preferences,
): Promise<OpenAICodexSession> {
  const accessToken = prefs.openaiCodexAccessToken;
  const refreshToken = prefs.openaiCodexRefreshToken;
  const accountId = prefs.openaiCodexAccountId;
  const expiresAt = prefs.openaiCodexExpiresAt || 0;

  if (!refreshToken) {
    throw new Error("OpenAI Codex is not connected. Connect ChatGPT in Settings.");
  }

  const now = Date.now();
  const hasValidAccess =
    !!accessToken && !!accountId && expiresAt > now + 30_000;

  if (hasValidAccess) {
    return {
      accessToken,
      refreshToken,
      expiresAt,
      accountId,
    };
  }

  const refreshed = await refreshOpenAICodexSession(refreshToken);

  prefs.openaiCodexAccessToken = refreshed.accessToken;
  prefs.openaiCodexRefreshToken = refreshed.refreshToken;
  prefs.openaiCodexExpiresAt = refreshed.expiresAt;
  prefs.openaiCodexAccountId = refreshed.accountId;

  return refreshed;
}

function parseCodexErrorBody(text: string): string {
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const parsed: any = JSON.parse(text);

    if (typeof parsed?.detail === "string" && parsed.detail) {
      return parsed.detail;
    }

    const error = parsed?.error;
    if (!error) return text;

    const code = String(error.code || error.type || "");
    if (/usage_limit_reached|usage_not_included|rate_limit_exceeded/i.test(code)) {
      return "You have hit your ChatGPT usage limit. Try again later.";
    }

    if (typeof error.message === "string" && error.message) {
      return error.message;
    }
  } catch {
    // keep raw text
  }

  return text;
}

function extractTextFromCompletedResponse(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  response: any,
): string {
  const output = Array.isArray(response?.output) ? response.output : [];
  const chunks: string[] = [];

  for (const item of output) {
    if (item?.type !== "message" || !Array.isArray(item.content)) continue;
    for (const content of item.content) {
      if (content?.type === "output_text" && typeof content.text === "string") {
        chunks.push(content.text);
      }
    }
  }

  return chunks.join("");
}

function extractTextFromSseBody(raw: string): string {
  let outputText = "";
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let completedResponse: any = null;
  const normalized = raw.replace(/\r\n/g, "\n");

  for (const chunk of normalized.split("\n\n")) {
    const data = chunk
      .split("\n")
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trim())
      .join("\n")
      .trim();

    if (!data || data === "[DONE]") continue;

    try {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const event: any = JSON.parse(data);
      if (event.type === "response.output_text.delta" && typeof event.delta === "string") {
        outputText += event.delta;
      } else if (
        event.type === "response.output_text.done" &&
        typeof event.text === "string" &&
        outputText.length === 0
      ) {
        outputText += event.text;
      } else if (
        (event.type === "response.completed" || event.type === "response.done") &&
        event.response
      ) {
        completedResponse = event.response;
      }
    } catch {
      // ignore malformed chunks
    }
  }

  return (outputText || extractTextFromCompletedResponse(completedResponse)).trim();
}

interface CodexProxyResponse {
  status: number;
  statusText: string;
  body: string;
}

function getTauriInvoke():
  | ((cmd: string, args?: Record<string, unknown>) => Promise<unknown>)
  | null {
  if (typeof window === "undefined") return null;
  const maybeInternals = (window as { __TAURI_INTERNALS__?: unknown })
    .__TAURI_INTERNALS__;

  if (!maybeInternals || typeof maybeInternals !== "object") return null;

  const invoke = (maybeInternals as { invoke?: unknown }).invoke;
  if (typeof invoke !== "function") return null;

  return invoke as (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;
}

async function requestCodexJsonViaProxy(
  text: string,
  systemPrompt: string,
  model: string,
  session: OpenAICodexSession,
): Promise<CodexProxyResponse> {
  const invoke = getTauriInvoke();
  if (!invoke) {
    throw new Error("OpenAI Codex is available in the desktop app only.");
  }

  const result = (await invoke("openai_codex_proxy_request", {
    payload: {
      accessToken: session.accessToken,
      accountId: session.accountId,
      model,
      systemPrompt,
      inputText: text,
    },
  })) as CodexProxyResponse;

  return result;
}

async function requestCodexJsonDirect(
  text: string,
  systemPrompt: string,
  model: string,
  session: OpenAICodexSession,
  signal?: AbortSignal,
): Promise<CodexProxyResponse> {
  const response = await fetch(CODEX_RESPONSES_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session.accessToken}`,
      "chatgpt-account-id": session.accountId,
      "OpenAI-Beta": "responses=experimental",
      originator: "bex",
      accept: "text/event-stream",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model,
      store: false,
      stream: true,
      instructions: systemPrompt,
      input: [
        {
          role: "user",
          content: [{ type: "input_text", text }],
        },
      ],
      text: { verbosity: "medium" },
    }),
    signal,
  });

  return {
    status: response.status,
    statusText: response.statusText,
    body: await response.text(),
  };
}

async function requestCodexText(
  text: string,
  systemPrompt: string,
  model: string,
  session: OpenAICodexSession,
  signal?: AbortSignal,
): Promise<string> {
  let response: CodexProxyResponse;

  try {
    response = await requestCodexJsonViaProxy(text, systemPrompt, model, session);
  } catch {
    response = await requestCodexJsonDirect(text, systemPrompt, model, session, signal);
  }

  if (response.status < 200 || response.status >= 300) {
    if (response.status === 401 || response.status === 403) {
      throw new Error("OpenAI Codex login expired. Reconnect in Settings.");
    }
    if (response.status === 429) {
      throw new Error("OpenAI Codex usage limit reached. Try again later.");
    }

    const message = parseCodexErrorBody(response.body || response.statusText);
    throw new Error(`OpenAI Codex error (${response.status}): ${message}`);
  }

  let content = "";

  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const json: any = JSON.parse(response.body);
    if (json?.error) {
      throw new Error(parseCodexErrorBody(response.body));
    }

    content =
      (typeof json?.output_text === "string" ? json.output_text : "") ||
      extractTextFromCompletedResponse(json);
  } catch {
    content = extractTextFromSseBody(response.body);
  }

  if (!content || !content.trim()) {
    throw new Error("Empty response from OpenAI Codex.");
  }

  return content.trim();
}

export async function generateWithOpenAICodex(
  text: string,
  prefs: Preferences,
  systemPrompt: string,
  signal?: AbortSignal,
): Promise<string> {
  const session = await ensureOpenAICodexSession(prefs);
  const model = prefs.model || "gpt-5.1-codex-mini";
  return requestCodexText(text, systemPrompt, model, session, signal);
}

export async function checkWithOpenAICodex(
  text: string,
  prefs: Preferences,
  systemPrompt: string,
  signal?: AbortSignal,
): Promise<GrammarResult> {
  const session = await ensureOpenAICodexSession(prefs);
  const model = prefs.model || "gpt-5.1-codex-mini";
  const content = await requestCodexText(text, systemPrompt, model, session, signal);
  return parseGrammarResponse(content);
}
