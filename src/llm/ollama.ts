import { GrammarResult, Preferences } from "./types";
import { SYSTEM_PROMPT } from "./provider";
import { parseGrammarResponse } from "../lib/parse-json";

export async function checkWithOllama(
  text: string,
  prefs: Preferences,
  signal?: AbortSignal,
): Promise<GrammarResult> {
  const url = prefs.ollamaUrl || "http://localhost:11434";
  const model = prefs.model || "llama3.2";

  let resp: Response;
  try {
    resp = await fetch(`${url}/api/chat`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model,
        stream: false,
        format: "json",
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: text },
        ],
      }),
      signal,
    });
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") throw err;
    throw new Error(
      `Cannot connect to Ollama at ${url}. Make sure Ollama is running.`,
    );
  }

  if (!resp.ok) {
    const errorText = await resp.text();
    if (errorText.includes("not found")) {
      throw new Error(`Model '${model}' not found. Run: ollama pull ${model}`);
    }
    throw new Error(`Ollama error (${resp.status}): ${errorText}`);
  }

  const json = await resp.json();
  const content = json.message?.content;
  if (!content) throw new Error("Empty response from Ollama.");

  return parseGrammarResponse(content);
}
