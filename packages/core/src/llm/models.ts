import { LlmProvider, Preferences } from "./types";

export interface ModelOption {
  id: string;
  name: string;
}

const OPENAI_CHAT_PREFIXES = ["gpt-", "o1", "o3", "o4", "chatgpt-"];

async function fetchOpenAIModels(apiKey: string): Promise<ModelOption[]> {
  const resp = await fetch("https://api.openai.com/v1/models", {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!resp.ok) return [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const json: any = await resp.json();
  return (json.data || [])
    .filter(
      (m: { id: string }) =>
        OPENAI_CHAT_PREFIXES.some((p) => m.id.startsWith(p)) &&
        !m.id.includes(":"),
    )
    .map((m: { id: string }) => ({ id: m.id, name: m.id }))
    .sort((a: ModelOption, b: ModelOption) => a.name.localeCompare(b.name));
}

async function fetchClaudeModels(apiKey: string): Promise<ModelOption[]> {
  const resp = await fetch("https://api.anthropic.com/v1/models?limit=100", {
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
  });
  if (!resp.ok) return [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const json: any = await resp.json();
  return (json.data || [])
    .map((m: { id: string; display_name?: string }) => ({
      id: m.id,
      name: m.display_name || m.id,
    }))
    .sort((a: ModelOption, b: ModelOption) => a.name.localeCompare(b.name));
}

async function fetchGeminiModels(apiKey: string): Promise<ModelOption[]> {
  const resp = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models?key=${apiKey}`,
  );
  if (!resp.ok) return [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const json: any = await resp.json();
  return (json.models || [])
    .filter((m: { supportedGenerationMethods?: string[] }) =>
      m.supportedGenerationMethods?.includes("generateContent"),
    )
    .map((m: { name: string; displayName?: string }) => ({
      id: m.name.replace("models/", ""),
      name: m.displayName || m.name.replace("models/", ""),
    }))
    .sort((a: ModelOption, b: ModelOption) => a.name.localeCompare(b.name));
}

async function fetchOllamaModels(url: string): Promise<ModelOption[]> {
  try {
    const resp = await fetch(`${url}/api/tags`);
    if (!resp.ok) return [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const json: any = await resp.json();
    return (json.models || [])
      .map((m: { name: string }) => ({ id: m.name, name: m.name }))
      .sort((a: ModelOption, b: ModelOption) => a.name.localeCompare(b.name));
  } catch {
    return [];
  }
}

export const DEFAULT_MODELS: Record<LlmProvider, string> = {
  openai: "gpt-4.1-mini",
  claude: "claude-sonnet-4-5-20250929",
  gemini: "gemini-2.5-flash",
  ollama: "llama3.2",
};

export async function fetchModels(
  provider: LlmProvider,
  prefs: Preferences,
): Promise<ModelOption[]> {
  switch (provider) {
    case "openai":
      return prefs.openaiApiKey ? fetchOpenAIModels(prefs.openaiApiKey) : [];
    case "claude":
      return prefs.claudeApiKey ? fetchClaudeModels(prefs.claudeApiKey) : [];
    case "gemini":
      return prefs.geminiApiKey ? fetchGeminiModels(prefs.geminiApiKey) : [];
    case "ollama":
      return fetchOllamaModels(prefs.ollamaUrl || "http://localhost:11434");
  }
}
