import { describe, it, expect, vi } from "vitest";
import { Preferences } from "./types";

vi.mock("./openai", () => ({
  checkWithOpenAI: vi.fn().mockResolvedValue({ corrected: "ok", explanation: "none" }),
  generateWithOpenAI: vi.fn().mockResolvedValue("generated"),
}));
vi.mock("./claude", () => ({
  checkWithClaude: vi.fn().mockResolvedValue({ corrected: "ok", explanation: "none" }),
  generateWithClaude: vi.fn().mockResolvedValue("generated"),
}));
vi.mock("./gemini", () => ({
  checkWithGemini: vi.fn().mockResolvedValue({ corrected: "ok", explanation: "none" }),
  generateWithGemini: vi.fn().mockResolvedValue("generated"),
}));
vi.mock("./ollama", () => ({
  checkWithOllama: vi.fn().mockResolvedValue({ corrected: "ok", explanation: "none" }),
  generateWithOllama: vi.fn().mockResolvedValue("generated"),
}));

import { checkGrammar, generateText } from "./provider";
import { checkWithOpenAI, generateWithOpenAI } from "./openai";
import { checkWithClaude, generateWithClaude } from "./claude";
import { checkWithGemini, generateWithGemini } from "./gemini";
import { checkWithOllama, generateWithOllama } from "./ollama";

const basePrefs: Omit<Preferences, "provider"> = {
  openaiApiKey: "test-key",
  claudeApiKey: "test-key",
  geminiApiKey: "test-key",
  model: "test-model",
};

describe("checkGrammar routing", () => {
  it("routes to OpenAI", async () => {
    await checkGrammar("hi", { ...basePrefs, provider: "openai" });
    expect(checkWithOpenAI).toHaveBeenCalled();
  });

  it("routes to Claude", async () => {
    await checkGrammar("hi", { ...basePrefs, provider: "claude" });
    expect(checkWithClaude).toHaveBeenCalled();
  });

  it("routes to Gemini", async () => {
    await checkGrammar("hi", { ...basePrefs, provider: "gemini" });
    expect(checkWithGemini).toHaveBeenCalled();
  });

  it("routes to Ollama", async () => {
    await checkGrammar("hi", { ...basePrefs, provider: "ollama" });
    expect(checkWithOllama).toHaveBeenCalled();
  });

  it("throws for unknown provider", async () => {
    await expect(
      checkGrammar("hi", { ...basePrefs, provider: "unknown" as any }),
    ).rejects.toThrow("Unknown provider");
  });
});

describe("generateText routing", () => {
  it("routes to OpenAI", async () => {
    await generateText("sys", "hi", { ...basePrefs, provider: "openai" });
    expect(generateWithOpenAI).toHaveBeenCalled();
  });

  it("routes to Claude", async () => {
    await generateText("sys", "hi", { ...basePrefs, provider: "claude" });
    expect(generateWithClaude).toHaveBeenCalled();
  });

  it("routes to Gemini", async () => {
    await generateText("sys", "hi", { ...basePrefs, provider: "gemini" });
    expect(generateWithGemini).toHaveBeenCalled();
  });

  it("routes to Ollama", async () => {
    await generateText("sys", "hi", { ...basePrefs, provider: "ollama" });
    expect(generateWithOllama).toHaveBeenCalled();
  });

  it("throws for unknown provider", async () => {
    await expect(
      generateText("sys", "hi", { ...basePrefs, provider: "unknown" as any }),
    ).rejects.toThrow("Unknown provider");
  });
});
