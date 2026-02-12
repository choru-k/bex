import { describe, it, expect } from "vitest";
import { HistoryEntry } from "../llm/types";
import { createMockStorage } from "../__test__/mock-storage";
import {
  loadHistory,
  saveToHistory,
  deleteHistoryEntry,
  clearHistory,
} from "./history";

function makeEntry(id: string): HistoryEntry {
  return {
    id,
    original: `original-${id}`,
    corrected: `corrected-${id}`,
    explanation: "Fixed.",
    provider: "openai",
    model: "gpt-4.1-mini",
    timestamp: new Date().toISOString(),
  };
}

describe("loadHistory", () => {
  it("returns empty array when storage is empty", async () => {
    const storage = createMockStorage();
    expect(await loadHistory(storage)).toEqual([]);
  });

  it("parses valid JSON from storage", async () => {
    const storage = createMockStorage();
    const entries = [makeEntry("1"), makeEntry("2")];
    await storage.setItem("history", JSON.stringify(entries));
    expect(await loadHistory(storage)).toEqual(entries);
  });

  it("returns empty array for corrupt JSON", async () => {
    const storage = createMockStorage();
    await storage.setItem("history", "broken{json");
    expect(await loadHistory(storage)).toEqual([]);
  });
});

describe("saveToHistory", () => {
  it("prepends entry to history", async () => {
    const storage = createMockStorage();
    const first = makeEntry("1");
    const second = makeEntry("2");
    await saveToHistory(storage, first);
    await saveToHistory(storage, second);
    const history = await loadHistory(storage);
    expect(history[0].id).toBe("2");
    expect(history[1].id).toBe("1");
  });

  it("caps at 500 entries", async () => {
    const storage = createMockStorage();
    // Pre-fill with 500 entries
    const entries = Array.from({ length: 500 }, (_, i) => makeEntry(`e-${i}`));
    await storage.setItem("history", JSON.stringify(entries));
    // Add one more
    await saveToHistory(storage, makeEntry("new"));
    const history = await loadHistory(storage);
    expect(history.length).toBe(500);
    expect(history[0].id).toBe("new");
  });
});

describe("deleteHistoryEntry", () => {
  it("removes entry by id", async () => {
    const storage = createMockStorage();
    await saveToHistory(storage, makeEntry("1"));
    await saveToHistory(storage, makeEntry("2"));
    await deleteHistoryEntry(storage, "1");
    const history = await loadHistory(storage);
    expect(history.length).toBe(1);
    expect(history[0].id).toBe("2");
  });

  it("is a no-op for missing id", async () => {
    const storage = createMockStorage();
    await saveToHistory(storage, makeEntry("1"));
    await deleteHistoryEntry(storage, "nonexistent");
    const history = await loadHistory(storage);
    expect(history.length).toBe(1);
  });
});

describe("clearHistory", () => {
  it("removes all history entries", async () => {
    const storage = createMockStorage();
    await saveToHistory(storage, makeEntry("1"));
    await saveToHistory(storage, makeEntry("2"));
    await clearHistory(storage);
    expect(await loadHistory(storage)).toEqual([]);
  });
});
