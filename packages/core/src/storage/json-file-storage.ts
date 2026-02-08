import { readFile, writeFile, rename, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { homedir, tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { StorageAdapter } from "./storage";

const DEFAULT_PATH = join(homedir(), ".bex", "data.json");

export class JsonFileStorage implements StorageAdapter {
  private filePath: string;
  private cache: Record<string, string> | null = null;

  constructor(filePath?: string) {
    this.filePath = filePath ?? DEFAULT_PATH;
  }

  private async load(): Promise<Record<string, string>> {
    if (this.cache) return this.cache;
    try {
      const raw = await readFile(this.filePath, "utf-8");
      this.cache = JSON.parse(raw);
    } catch {
      this.cache = {};
    }
    return this.cache!;
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

    this.cache = data;
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
    const data = await this.load();
    await this.persist({ ...data, [key]: value });
  }

  async removeItem(key: string): Promise<void> {
    const data = await this.load();
    const { [key]: _, ...rest } = data;
    await this.persist(rest);
  }

  async getAllKeys(): Promise<string[]> {
    const data = await this.load();
    return Object.keys(data);
  }
}
