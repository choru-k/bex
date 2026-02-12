import { describe, it, expect } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { resolve, join } from "node:path";

describe("production bundle", () => {
  it("contains no node: bare imports", () => {
    const distDir = resolve(__dirname, "../dist/assets");
    const jsFiles = readdirSync(distDir).filter((f) => f.endsWith(".js"));
    expect(jsFiles.length).toBeGreaterThan(0);

    for (const file of jsFiles) {
      const content = readFileSync(join(distDir, file), "utf-8");
      const nodeImports = content.match(/import\s*"node:[^"]+"/g);
      expect(nodeImports, `${file} contains node: imports`).toBeNull();
    }
  });
});
