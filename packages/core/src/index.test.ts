import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

describe("barrel export", () => {
  it("does not re-export Node.js-only modules", () => {
    const barrel = readFileSync(resolve(__dirname, "index.ts"), "utf-8");
    expect(barrel).not.toMatch(/json-file-storage/);
  });
});
