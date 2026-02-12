import { describe, it, expect, vi, beforeEach } from "vitest";
import { Preferences } from "./types";
import { checkWithClaude, generateWithClaude } from "./claude";

const validPrefs: Preferences = {
  provider: "claude",
  claudeApiKey: "sk-ant-test-key",
  model: "claude-sonnet-4-5-20250929",
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

describe("checkWithClaude", () => {
  it("throws when API key is missing", async () => {
    await expect(
      checkWithClaude("hello", { ...validPrefs, claudeApiKey: undefined }, "sys"),
    ).rejects.toThrow("Claude API key not configured");
  });

  it("throws on 401 response", async () => {
    globalThis.fetch = mockFetch({}, 401);
    await expect(
      checkWithClaude("hello", validPrefs, "sys"),
    ).rejects.toThrow("Invalid Claude API key");
  });

  it("throws on 429 response", async () => {
    globalThis.fetch = mockFetch({}, 429);
    await expect(
      checkWithClaude("hello", validPrefs, "sys"),
    ).rejects.toThrow("Claude rate limit");
  });

  it("parses successful response", async () => {
    globalThis.fetch = mockFetch({
      content: [
        { text: '{"corrected": "Hello.", "explanation": "Capitalized."}' },
      ],
    });
    const result = await checkWithClaude("hello", validPrefs, "sys");
    expect(result).toEqual({ corrected: "Hello.", explanation: "Capitalized." });
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ content: [] });
    await expect(
      checkWithClaude("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from Claude");
  });

  it("sends correct headers and body", async () => {
    const fetchMock = mockFetch({
      content: [{ text: '{"corrected":"a","explanation":"b"}' }],
    });
    globalThis.fetch = fetchMock;
    await checkWithClaude("test text", validPrefs, "system prompt");
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    expect(opts.headers["x-api-key"]).toBe("sk-ant-test-key");
    expect(opts.headers["anthropic-version"]).toBe("2023-06-01");
    const body = JSON.parse(opts.body);
    expect(body.model).toBe("claude-sonnet-4-5-20250929");
    expect(body.system).toBe("system prompt");
    expect(body.messages[0].content).toBe("test text");
  });
});

describe("generateWithClaude", () => {
  it("throws when API key is missing", async () => {
    await expect(
      generateWithClaude("hello", { ...validPrefs, claudeApiKey: undefined }, "sys"),
    ).rejects.toThrow("Claude API key not configured");
  });

  it("returns content on success", async () => {
    globalThis.fetch = mockFetch({
      content: [{ text: "Generated text" }],
    });
    const result = await generateWithClaude("hello", validPrefs, "sys");
    expect(result).toBe("Generated text");
  });

  it("throws on empty response", async () => {
    globalThis.fetch = mockFetch({ content: [] });
    await expect(
      generateWithClaude("hello", validPrefs, "sys"),
    ).rejects.toThrow("Empty response from Claude");
  });
});
