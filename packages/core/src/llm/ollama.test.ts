import { describe, it, expect, vi, beforeEach } from "vitest";
import { Preferences } from "./types";
import { checkWithOllama, generateWithOllama } from "./ollama";

const validPrefs: Preferences = {
  provider: "ollama",
  model: "llama3.2",
  ollamaUrl: "http://localhost:11434",
};

function mockFetch(body: object, status = 200) {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    json: () => Promise.resolve(body),
    text: () => Promise.resolve(JSON.stringify(body)),
  });
}

beforeEach(() => {
  vi.restoreAllMocks();
});

describe("checkWithOllama", () => {
  it("throws when connection fails", async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error("fetch failed"));
    await expect(
      checkWithOllama("hello", validPrefs, "sys"),
    ).rejects.toThrow("Cannot connect to Ollama");
  });

  it("re-throws AbortError as-is", async () => {
    const abortError = new DOMException("The operation was aborted.", "AbortError");
    globalThis.fetch = vi.fn().mockRejectedValue(abortError);
    await expect(
      checkWithOllama("hello", validPrefs, "sys"),
    ).rejects.toThrow("The operation was aborted.");
  });

  it("throws when model is not found", async () => {
    globalThis.fetch = mockFetch({}, 404);
    // Override text to include "not found"
    (globalThis.fetch as any).mockResolvedValue({
      ok: false,
      status: 404,
      text: () => Promise.resolve("model 'llama3.2' not found"),
    });
    await expect(
      checkWithOllama("hello", validPrefs, "sys"),
    ).rejects.toThrow("not found");
  });

  it("parses successful response", async () => {
    globalThis.fetch = mockFetch({
      message: {
        content: '{"corrected": "Hello.", "explanation": "Capitalized."}',
      },
    });
    const result = await checkWithOllama("hello", validPrefs, "sys");
    expect(result).toEqual({ corrected: "Hello.", explanation: "Capitalized." });
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ message: {} });
    await expect(
      checkWithOllama("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from Ollama");
  });

  it("sends correct body with stream: false and format: json", async () => {
    const fetchMock = mockFetch({
      message: { content: '{"corrected":"a","explanation":"b"}' },
    });
    globalThis.fetch = fetchMock;
    await checkWithOllama("test text", validPrefs, "system prompt");
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("http://localhost:11434/api/chat");
    const body = JSON.parse(opts.body);
    expect(body.stream).toBe(false);
    expect(body.format).toBe("json");
    expect(body.model).toBe("llama3.2");
    expect(body.messages[0].content).toBe("system prompt");
    expect(body.messages[1].content).toBe("test text");
  });
});

describe("generateWithOllama", () => {
  it("returns content on success", async () => {
    globalThis.fetch = mockFetch({
      message: { content: "Generated text" },
    });
    const result = await generateWithOllama("hello", validPrefs, "sys");
    expect(result).toBe("Generated text");
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ message: {} });
    await expect(
      generateWithOllama("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from Ollama");
  });

  it("throws when connection fails", async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error("fetch failed"));
    await expect(
      generateWithOllama("hello", validPrefs, "sys"),
    ).rejects.toThrow("Cannot connect to Ollama");
  });
});
