import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { homedir, tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { StorageAdapter } from "./storage";

export class JsonFileStorage implements StorageAdapter {
  private filePath: string;
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(filePath?: string) {
    this.filePath = filePath ?? join(homedir(), ".bex", "data.json");
  }

  private async load(): Promise<Record<string, string>> {
    try {
      const raw = await readFile(this.filePath, "utf-8");
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === "object") {
        return parsed as Record<string, string>;
      }
      return {};
    } catch {
      return {};
    }
  }

  private async persist(data: Record<string, string>): Promise<void> {
    const dir = dirname(this.filePath);
    await mkdir(dir, { recursive: true, mode: 0o700 });

    const tmp = join(tmpdir(), `bex-${randomUUID()}.json`);
    await writeFile(tmp, JSON.stringify(data, null, 2), {
      encoding: "utf-8",
      mode: 0o600,
    });
    await rename(tmp, this.filePath);
  }

  async getItem<T = string>(key: string): Promise<T | undefined> {
    const data = await this.load();
    const value = data[key];
    if (value === undefined) return undefined;
    try {
      return JSON.parse(value) as T;
    } catch {
      return value as T;
    }
  }

  async setItem(key: string, value: string): Promise<void> {
    const run = this.writeQueue.then(async () => {
      const data = await this.load();
      await this.persist({ ...data, [key]: value });
    });
    this.writeQueue = run.catch(() => {});
    return run;
  }

  async removeItem(key: string): Promise<void> {
    const run = this.writeQueue.then(async () => {
      const data = await this.load();
      const { [key]: _, ...rest } = data;
      await this.persist(rest);
    });
    this.writeQueue = run.catch(() => {});
    return run;
  }

  async getAllKeys(): Promise<string[]> {
    const data = await this.load();
    return Object.keys(data);
  }
}
