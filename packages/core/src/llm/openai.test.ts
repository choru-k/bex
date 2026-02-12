import { describe, it, expect, vi, beforeEach } from "vitest";
import { Preferences } from "./types";
import { checkWithOpenAI, generateWithOpenAI } from "./openai";

const validPrefs: Preferences = {
  provider: "openai",
  openaiApiKey: "sk-test-key",
  model: "gpt-4.1-mini",
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

describe("checkWithOpenAI", () => {
  it("throws when API key is missing", async () => {
    await expect(
      checkWithOpenAI("hello", { ...validPrefs, openaiApiKey: undefined }, "sys"),
    ).rejects.toThrow("OpenAI API key not configured");
  });

  it("throws on 401 response", async () => {
    globalThis.fetch = mockFetch({}, 401);
    await expect(
      checkWithOpenAI("hello", validPrefs, "sys"),
    ).rejects.toThrow("Invalid OpenAI API key");
  });

  it("throws on 429 response", async () => {
    globalThis.fetch = mockFetch({}, 429);
    await expect(
      checkWithOpenAI("hello", validPrefs, "sys"),
    ).rejects.toThrow("OpenAI rate limit");
  });

  it("parses successful response", async () => {
    globalThis.fetch = mockFetch({
      choices: [
        {
          message: {
            content: '{"corrected": "Hello.", "explanation": "Capitalized."}',
          },
        },
      ],
    });
    const result = await checkWithOpenAI("hello", validPrefs, "sys");
    expect(result).toEqual({ corrected: "Hello.", explanation: "Capitalized." });
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ choices: [] });
    await expect(
      checkWithOpenAI("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from OpenAI");
  });

  it("sends correct headers and body", async () => {
    const fetchMock = mockFetch({
      choices: [{ message: { content: '{"corrected":"a","explanation":"b"}' } }],
    });
    globalThis.fetch = fetchMock;
    await checkWithOpenAI("test text", validPrefs, "system prompt");
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.openai.com/v1/chat/completions");
    expect(opts.headers.Authorization).toBe("Bearer sk-test-key");
    expect(opts.headers["Content-Type"]).toBe("application/json");
    const body = JSON.parse(opts.body);
    expect(body.model).toBe("gpt-4.1-mini");
    expect(body.messages[0].content).toBe("system prompt");
    expect(body.messages[1].content).toBe("test text");
  });
});

describe("generateWithOpenAI", () => {
  it("throws when API key is missing", async () => {
    await expect(
      generateWithOpenAI("hello", { ...validPrefs, openaiApiKey: undefined }, "sys"),
    ).rejects.toThrow("OpenAI API key not configured");
  });

  it("returns content on success", async () => {
    globalThis.fetch = mockFetch({
      choices: [{ message: { content: "Generated text" } }],
    });
    const result = await generateWithOpenAI("hello", validPrefs, "sys");
    expect(result).toBe("Generated text");
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ choices: [] });
    await expect(
      generateWithOpenAI("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from OpenAI");
  });
});
