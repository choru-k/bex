import { afterEach, describe, expect, it, vi } from "vitest";
import { DEFAULT_MODELS, fetchModels } from "./models";
import type { Preferences } from "./types";

function basePrefs(provider: Preferences["provider"]): Preferences {
  return {
    provider,
    openaiApiKey: "openai-key",
    claudeApiKey: "claude-key",
    geminiApiKey: "gemini-key",
    ollamaUrl: "http://localhost:11434",
    model: undefined,
  };
}

describe("fetchModels", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("returns static Codex model list for openai-codex", async () => {
    const models = await fetchModels("openai-codex", basePrefs("openai-codex"));

    expect(models.length).toBeGreaterThan(0);
    expect(models.some((m) => m.id === DEFAULT_MODELS["openai-codex"])).toBe(true);
  });

  it("returns [] for OpenAI when api key is missing", async () => {
    const prefs = basePrefs("openai");
    prefs.openaiApiKey = undefined;

    const models = await fetchModels("openai", prefs);
    expect(models).toEqual([]);
  });

  it("filters OpenAI models to chat-compatible ids", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            data: [
              { id: "gpt-5.2" },
              { id: "o4-mini" },
              { id: "text-embedding-3-small" },
              { id: "gpt-5.2:realtime" },
            ],
          }),
          { status: 200 },
        ),
      ),
    );

    const models = await fetchModels("openai", basePrefs("openai"));

    expect(models.map((m) => m.id)).toEqual(["gpt-5.2", "o4-mini"]);
  });

  it("filters Gemini models by generateContent support", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          JSON.stringify({
            models: [
              {
                name: "models/gemini-2.5-flash",
                displayName: "Gemini 2.5 Flash",
                supportedGenerationMethods: ["generateContent"],
              },
              {
                name: "models/embedding-001",
                supportedGenerationMethods: ["embedContent"],
              },
            ],
          }),
          { status: 200 },
        ),
      ),
    );

    const models = await fetchModels("gemini", basePrefs("gemini"));

    expect(models).toEqual([
      { id: "gemini-2.5-flash", name: "Gemini 2.5 Flash" },
    ]);
  });

  it("returns [] when Ollama fetch fails", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));

    const models = await fetchModels("ollama", basePrefs("ollama"));
    expect(models).toEqual([]);
  });
});
