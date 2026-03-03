import { afterEach, describe, expect, it } from "vitest";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { JsonFileStorage } from "./json-file-storage";

const createdDirs: string[] = [];

async function createStorage() {
  const dir = await mkdtemp(join(tmpdir(), "bex-json-storage-"));
  createdDirs.push(dir);
  const file = join(dir, "data.json");
  return {
    storage: new JsonFileStorage(file),
    file,
  };
}

afterEach(async () => {
  await Promise.all(
    createdDirs.splice(0, createdDirs.length).map((dir) =>
      rm(dir, { recursive: true, force: true }),
    ),
  );
});

describe("JsonFileStorage", () => {
  it("round-trips JSON values", async () => {
    const { storage } = await createStorage();

    await storage.setItem("preferences", JSON.stringify({ provider: "openai" }));

    const prefs = await storage.getItem<{ provider: string }>("preferences");
    expect(prefs).toEqual({ provider: "openai" });
  });

  it("reflects external file changes on subsequent reads", async () => {
    const { storage, file } = await createStorage();

    await storage.setItem("history", JSON.stringify([]));
    expect(await storage.getItem("history")).toEqual([]);

    await writeFile(
      file,
      JSON.stringify({
        history: JSON.stringify([{ id: "h1" }]),
      }),
      "utf-8",
    );

    expect(await storage.getItem("history")).toEqual([{ id: "h1" }]);
  });

  it("serializes concurrent writes so keys are not lost", async () => {
    const { storage, file } = await createStorage();

    await Promise.all([
      storage.setItem("preferences", JSON.stringify({ provider: "openai" })),
      storage.setItem("history", JSON.stringify([{ id: "1" }])),
    ]);

    const raw = await readFile(file, "utf-8");
    const parsed = JSON.parse(raw) as Record<string, string>;

    expect(parsed.preferences).toBeDefined();
    expect(parsed.history).toBeDefined();
  });
});
