import { afterEach, describe, expect, it, vi } from "vitest";
import type { Preferences } from "./types";
import { checkWithOpenAICodex, generateWithOpenAICodex } from "./openai-codex";

function createPrefs(): Preferences {
  return {
    provider: "openai-codex",
    openaiCodexAccessToken: "access-token",
    openaiCodexRefreshToken: "refresh-token",
    openaiCodexAccountId: "account-id",
    openaiCodexExpiresAt: Date.now() + 10 * 60 * 1000,
    model: "gpt-5.1-codex-mini",
  };
}

describe("openai codex responses", () => {
  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("sends stream=true and parses SSE output", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(
        [
          'data: {"type":"response.output_text.delta","delta":"Hello"}',
          "",
          'data: {"type":"response.output_text.delta","delta":" world"}',
          "",
          'data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"Hello world"}]}]}}',
          "",
          "data: [DONE]",
          "",
        ].join("\r\n"),
        {
          status: 200,
          statusText: "OK",
          headers: { "content-type": "text/event-stream" },
        },
      ),
    );

    vi.stubGlobal("fetch", fetchMock);

    const text = await generateWithOpenAICodex("Input", createPrefs(), "System prompt");

    expect(text).toBe("Hello world");
    expect(fetchMock).toHaveBeenCalledTimes(1);

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body));

    expect(body.stream).toBe(true);
  });

  it("uses JSON detail message for 400 responses", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response('{"detail":"Stream must be set to true"}', {
          status: 400,
          statusText: "Bad Request",
        }),
      ),
    );

    await expect(
      generateWithOpenAICodex("Input", createPrefs(), "System prompt"),
    ).rejects.toThrow("OpenAI Codex error (400): Stream must be set to true");
  });

  it("parses grammar JSON when stream emits deltas and output_text.done", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue(
        new Response(
          [
            'data: {"type":"response.output_text.delta","delta":"{\\"corrected\\":\\"Fixed.\\","}',
            "",
            'data: {"type":"response.output_text.delta","delta":"\\"explanation\\":\\"Cleaned up.\\"}"}',
            "",
            'data: {"type":"response.output_text.done","text":"{\\"corrected\\":\\"Fixed.\\",\\"explanation\\":\\"Cleaned up.\\"}"}',
            "",
            "data: [DONE]",
            "",
          ].join("\r\n"),
          {
            status: 200,
            statusText: "OK",
            headers: { "content-type": "text/event-stream" },
          },
        ),
      ),
    );

    const result = await checkWithOpenAICodex("Input", createPrefs(), "System prompt");

    expect(result).toEqual({
      corrected: "Fixed.",
      explanation: "Cleaned up.",
    });
  });
});
