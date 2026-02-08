import { GrammarResult, Preferences } from "./types";
import { SYSTEM_PROMPT } from "./provider";
import { parseGrammarResponse } from "../lib/parse-json";

export async function generateWithClaude(
  text: string,
  prefs: Preferences,
  systemPrompt: string,
  signal?: AbortSignal,
): Promise<string> {
  const apiKey = prefs.claudeApiKey;
  if (!apiKey)
    throw new Error(
      "Claude API key not configured. Set it in extension preferences.",
    );

  const model = prefs.model || "claude-sonnet-4-5-20250929";

  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: 1024,
      system: systemPrompt,
      messages: [{ role: "user", content: text }],
      temperature: 0.7,
    }),
    signal,
  });

  if (!resp.ok) {
    const errorText = await resp.text();
    if (resp.status === 401)
      throw new Error("Invalid Claude API key. Check extension preferences.");
    if (resp.status === 429)
      throw new Error("Claude rate limit. Wait a moment and try again.");
    throw new Error(`Claude error (${resp.status}): ${errorText}`);
  }

  const json = await resp.json();
  const content = json.content?.[0]?.text;
  if (!content) throw new Error("Empty response from Claude.");

  return content;
}

export async function checkWithClaude(
  text: string,
  prefs: Preferences,
  systemPrompt: string,
  signal?: AbortSignal,
): Promise<GrammarResult> {
  const apiKey = prefs.claudeApiKey;
  if (!apiKey)
    throw new Error(
      "Claude API key not configured. Set it in extension preferences.",
    );

  const model = prefs.model || "claude-sonnet-4-5-20250929";

  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_tokens: 1024,
      system: systemPrompt,
      messages: [{ role: "user", content: text }],
    }),
    signal,
  });

  if (!resp.ok) {
    const errorText = await resp.text();
    if (resp.status === 401)
      throw new Error("Invalid Claude API key. Check extension preferences.");
    if (resp.status === 429)
      throw new Error("Claude rate limit. Wait a moment and try again.");
    throw new Error(`Claude error (${resp.status}): ${errorText}`);
  }

  const json = await resp.json();
  const content = json.content?.[0]?.text;
  if (!content) throw new Error("Empty response from Claude.");

  return parseGrammarResponse(content);
}
