import { describe, it, expect, vi, beforeEach } from "vitest";
import { Preferences } from "./types";
import { checkWithGemini, generateWithGemini } from "./gemini";

const validPrefs: Preferences = {
  provider: "gemini",
  geminiApiKey: "test-gemini-key",
  model: "gemini-2.5-flash",
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

describe("checkWithGemini", () => {
  it("throws when API key is missing", async () => {
    await expect(
      checkWithGemini("hello", { ...validPrefs, geminiApiKey: undefined }, "sys"),
    ).rejects.toThrow("Gemini API key not configured");
  });

  it("throws on 401/403 response", async () => {
    globalThis.fetch = mockFetch({}, 403);
    await expect(
      checkWithGemini("hello", validPrefs, "sys"),
    ).rejects.toThrow("Invalid Gemini API key");
  });

  it("throws on 400 response", async () => {
    globalThis.fetch = mockFetch({}, 400);
    await expect(
      checkWithGemini("hello", validPrefs, "sys"),
    ).rejects.toThrow("Bad request to Gemini");
  });

  it("throws on 429 response", async () => {
    globalThis.fetch = mockFetch({}, 429);
    await expect(
      checkWithGemini("hello", validPrefs, "sys"),
    ).rejects.toThrow("Gemini rate limit");
  });

  it("parses successful response", async () => {
    globalThis.fetch = mockFetch({
      candidates: [
        {
          content: {
            parts: [
              { text: '{"corrected": "Hello.", "explanation": "Capitalized."}' },
            ],
          },
        },
      ],
    });
    const result = await checkWithGemini("hello", validPrefs, "sys");
    expect(result).toEqual({ corrected: "Hello.", explanation: "Capitalized." });
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ candidates: [] });
    await expect(
      checkWithGemini("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from Gemini");
  });

  it("throws on API error in body", async () => {
    globalThis.fetch = mockFetch({
      error: { message: "Something went wrong" },
    });
    await expect(
      checkWithGemini("hello", validPrefs, "sys"),
    ).rejects.toThrow("Gemini error: Something went wrong");
  });

  it("sends correct headers and body", async () => {
    const fetchMock = mockFetch({
      candidates: [{ content: { parts: [{ text: '{"corrected":"a","explanation":"b"}' }] } }],
    });
    globalThis.fetch = fetchMock;
    await checkWithGemini("test text", validPrefs, "system prompt");
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toContain("generativelanguage.googleapis.com");
    expect(url).toContain("gemini-2.5-flash");
    expect(opts.headers["x-goog-api-key"]).toBe("test-gemini-key");
    const body = JSON.parse(opts.body);
    expect(body.system_instruction.parts[0].text).toBe("system prompt");
    expect(body.contents[0].parts[0].text).toBe("test text");
  });
});

describe("generateWithGemini", () => {
  it("throws when API key is missing", async () => {
    await expect(
      generateWithGemini("hello", { ...validPrefs, geminiApiKey: undefined }, "sys"),
    ).rejects.toThrow("Gemini API key not configured");
  });

  it("returns content on success", async () => {
    globalThis.fetch = mockFetch({
      candidates: [{ content: { parts: [{ text: "Generated text" }] } }],
    });
    const result = await generateWithGemini("hello", validPrefs, "sys");
    expect(result).toBe("Generated text");
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ candidates: [] });
    await expect(
      generateWithGemini("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from Gemini");
  });
});
