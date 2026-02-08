import { GrammarResult, Preferences } from "./types";
import { SYSTEM_PROMPT } from "./provider";
import { parseGrammarResponse } from "../lib/parse-json";

export async function checkWithOpenAI(
  text: string,
  prefs: Preferences,
  signal?: AbortSignal,
): Promise<GrammarResult> {
  const apiKey = prefs.openaiApiKey;
  if (!apiKey)
    throw new Error(
      "OpenAI API key not configured. Set it in extension preferences.",
    );

  const model = prefs.model || "gpt-4o-mini";

  const resp = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: text },
      ],
      temperature: 0.3,
    }),
    signal,
  });

  if (!resp.ok) {
    const errorText = await resp.text();
    if (resp.status === 401)
      throw new Error("Invalid OpenAI API key. Check extension preferences.");
    if (resp.status === 429)
      throw new Error("OpenAI rate limit. Wait a moment and try again.");
    throw new Error(`OpenAI error (${resp.status}): ${errorText}`);
  }

  const json = await resp.json();
  const content = json.choices?.[0]?.message?.content;
  if (!content) throw new Error("Empty response from OpenAI.");

  return parseGrammarResponse(content);
}
