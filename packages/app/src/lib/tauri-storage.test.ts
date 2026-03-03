import { describe, it, expect, beforeEach, vi } from "vitest";

vi.mock("@tauri-apps/plugin-fs", () => ({
  readTextFile: vi.fn(),
  writeTextFile: vi.fn(),
  mkdir: vi.fn(),
  exists: vi.fn(),
}));

vi.mock("@tauri-apps/api/path", () => ({
  homeDir: vi.fn(),
  join: vi.fn(),
}));

import { readTextFile, writeTextFile, mkdir, exists } from "@tauri-apps/plugin-fs";
import { homeDir, join } from "@tauri-apps/api/path";
import { TauriFileStorage } from "./tauri-storage";

describe("TauriFileStorage", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    vi.mocked(homeDir).mockResolvedValue("/Users/test");
    vi.mocked(join).mockImplementation(async (...parts: string[]) => {
      return parts.join("/").replace(/\/+/g, "/");
    });
  });

  it("writes data to $HOME/.bex/data.json", async () => {
    vi.mocked(exists).mockResolvedValue(false);

    const storage = new TauriFileStorage();
    await storage.setItem("preferences", JSON.stringify({ provider: "openai" }));

    expect(join).toHaveBeenCalledWith("/Users/test", ".bex");
    expect(join).toHaveBeenCalledWith("/Users/test/.bex", "data.json");

    expect(mkdir).toHaveBeenCalledWith("/Users/test/.bex", { recursive: true });
    expect(writeTextFile).toHaveBeenCalledWith(
      "/Users/test/.bex/data.json",
      expect.any(String),
    );
  });

  it("reads persisted JSON values from data file", async () => {
    vi.mocked(exists).mockImplementation(async (path: string) =>
      path.endsWith("data.json"),
    );
    vi.mocked(readTextFile).mockResolvedValue(
      JSON.stringify({
        preferences: JSON.stringify({ provider: "openai" }),
      }),
    );

    const storage = new TauriFileStorage();
    const prefs = await storage.getItem<{ provider: string }>("preferences");

    expect(prefs).toEqual({ provider: "openai" });
  });

  it("does not use stale cache between reads", async () => {
    vi.mocked(exists).mockImplementation(async (path: string) =>
      path.endsWith("data.json"),
    );
    vi.mocked(readTextFile)
      .mockResolvedValueOnce(JSON.stringify({ history: JSON.stringify([]) }))
      .mockResolvedValueOnce(
        JSON.stringify({
          history: JSON.stringify([
            {
              id: "h1",
              original: "a",
              corrected: "b",
              explanation: "x",
              provider: "openai",
              model: "gpt-4.1-mini",
              timestamp: new Date().toISOString(),
            },
          ]),
        }),
      );

    const storage = new TauriFileStorage();

    expect(await storage.getItem("history")).toEqual([]);
    expect(await storage.getItem("history")).toEqual([
      expect.objectContaining({ id: "h1" }),
    ]);
  });

  it("serializes concurrent writes so keys are not lost", async () => {
    let fileData = JSON.stringify({});

    vi.mocked(exists).mockResolvedValue(true);
    vi.mocked(readTextFile).mockImplementation(async () => fileData);
    vi.mocked(writeTextFile).mockImplementation(async (_path, content) => {
      fileData = content;
    });

    const storage = new TauriFileStorage();

    await Promise.all([
      storage.setItem("preferences", JSON.stringify({ provider: "openai" })),
      storage.setItem("history", JSON.stringify([{ id: "1" }])),
    ]);

    const parsed = JSON.parse(fileData);
    expect(parsed.preferences).toBeDefined();
    expect(parsed.history).toBeDefined();
  });
});
