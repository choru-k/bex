import { GrammarResult, Preferences } from "./types";
import { SYSTEM_PROMPT } from "./provider";
import { parseGrammarResponse } from "../lib/parse-json";

export async function checkWithGemini(
  text: string,
  prefs: Preferences,
  signal?: AbortSignal,
): Promise<GrammarResult> {
  const apiKey = prefs.geminiApiKey;
  if (!apiKey)
    throw new Error(
      "Gemini API key not configured. Set it in extension preferences.",
    );

  const model = prefs.model || "gemini-3-flash-preview";
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`;

  const resp = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
    body: JSON.stringify({
      system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
      contents: [{ parts: [{ text }] }],
      generationConfig: {
        temperature: 0.3,
        responseMimeType: "application/json",
      },
    }),
    signal,
  });

  if (!resp.ok) {
    const errorText = await resp.text();
    if (resp.status === 400)
      throw new Error(
        "Bad request to Gemini. Check your model name and input.",
      );
    if (resp.status === 401 || resp.status === 403)
      throw new Error("Invalid Gemini API key. Check extension preferences.");
    if (resp.status === 429)
      throw new Error("Gemini rate limit. Wait a moment and try again.");
    throw new Error(`Gemini error (${resp.status}): ${errorText}`);
  }

  const json = await resp.json();
  if (json.error)
    throw new Error(
      `Gemini error: ${json.error.message || JSON.stringify(json.error)}`,
    );
  const content = json.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!content) throw new Error("Empty response from Gemini.");

  return parseGrammarResponse(content);
}
