import { describe, it, expect } from "vitest";
import { computeWordDiff, diffToMarkdown } from "./diff";

describe("computeWordDiff", () => {
  it("returns all unchanged for identical strings", () => {
    const diff = computeWordDiff("hello world", "hello world");
    expect(diff.every((w) => w.type === "unchanged")).toBe(true);
    expect(diff.map((w) => w.text).join("")).toBe("hello world");
  });

  it("detects a single word replacement", () => {
    const diff = computeWordDiff("the cat sat", "the dog sat");
    const removed = diff.filter((w) => w.type === "removed");
    const added = diff.filter((w) => w.type === "added");
    expect(removed.length).toBe(1);
    expect(removed[0].text).toBe("cat");
    expect(added.length).toBe(1);
    expect(added[0].text).toBe("dog");
  });

  it("detects added words", () => {
    const diff = computeWordDiff("hello world", "hello beautiful world");
    const added = diff.filter((w) => w.type === "added");
    expect(added.some((w) => w.text === "beautiful")).toBe(true);
  });

  it("detects removed words", () => {
    const diff = computeWordDiff("hello beautiful world", "hello world");
    const removed = diff.filter((w) => w.type === "removed");
    expect(removed.some((w) => w.text === "beautiful")).toBe(true);
  });

  it("handles empty original string", () => {
    const diff = computeWordDiff("", "hello");
    expect(diff).toEqual([{ text: "hello", type: "added" }]);
  });

  it("handles empty corrected string", () => {
    const diff = computeWordDiff("hello", "");
    expect(diff).toEqual([{ text: "hello", type: "removed" }]);
  });

  it("handles both strings empty", () => {
    const diff = computeWordDiff("", "");
    expect(diff).toEqual([]);
  });

  it("preserves whitespace tokens", () => {
    const diff = computeWordDiff("a  b", "a  b");
    const texts = diff.map((w) => w.text).join("");
    expect(texts).toBe("a  b");
    // The double space should be its own token
    expect(diff.some((w) => /^\s+$/.test(w.text))).toBe(true);
  });
});

describe("diffToMarkdown", () => {
  it("renders unchanged text as-is", () => {
    const md = diffToMarkdown([
      { text: "hello", type: "unchanged" },
      { text: " ", type: "unchanged" },
      { text: "world", type: "unchanged" },
    ]);
    expect(md).toBe("hello world");
  });

  it("wraps added text in bold markers", () => {
    const md = diffToMarkdown([{ text: "hello", type: "added" }]);
    expect(md).toBe("**hello**");
  });

  it("wraps removed text in strikethrough markers", () => {
    const md = diffToMarkdown([{ text: "hello", type: "removed" }]);
    expect(md).toBe("~~hello~~");
  });

  it("groups consecutive tokens of the same type", () => {
    const md = diffToMarkdown([
      { text: "hello", type: "added" },
      { text: " ", type: "added" },
      { text: "world", type: "added" },
    ]);
    expect(md).toBe("**hello world**");
  });

  it("renders mixed diff correctly", () => {
    const md = diffToMarkdown([
      { text: "the", type: "unchanged" },
      { text: " ", type: "unchanged" },
      { text: "cat", type: "removed" },
      { text: "dog", type: "added" },
      { text: " ", type: "unchanged" },
      { text: "sat", type: "unchanged" },
    ]);
    expect(md).toBe("the ~~cat~~**dog** sat");
  });

  it("handles empty diff array", () => {
    const md = diffToMarkdown([]);
    expect(md).toBe("");
  });
});
