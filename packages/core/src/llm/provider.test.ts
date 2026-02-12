import { describe, it, expect } from "vitest";
import { buildSystemPrompt, SYSTEM_PROMPT } from "./provider";

describe("buildSystemPrompt", () => {
  it("returns SYSTEM_PROMPT when no argument is given", () => {
    expect(buildSystemPrompt()).toBe(SYSTEM_PROMPT);
  });

  it("returns SYSTEM_PROMPT when undefined is passed", () => {
    expect(buildSystemPrompt(undefined)).toBe(SYSTEM_PROMPT);
  });

  it("returns SYSTEM_PROMPT when empty string is passed", () => {
    expect(buildSystemPrompt("")).toBe(SYSTEM_PROMPT);
  });

  it("appends profile prompt with 'Additional context' section", () => {
    const profile = "I write British English.";
    const result = buildSystemPrompt(profile);
    expect(result).toContain(SYSTEM_PROMPT);
    expect(result).toContain("Additional context from the user:");
    expect(result).toContain(profile);
  });
});
