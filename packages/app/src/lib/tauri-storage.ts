import type { StorageAdapter } from "@bex/core";
import {
  readTextFile,
  writeTextFile,
  mkdir,
  exists,
} from "@tauri-apps/plugin-fs";
import { homeDir, join } from "@tauri-apps/api/path";

const DIR_NAME = ".bex";
const FILE_NAME = "data.json";

export class TauriFileStorage implements StorageAdapter {
  private filePath: string | null = null;
  private dirPath: string | null = null;
  private writeQueue: Promise<void> = Promise.resolve();

  private async getDirPath(): Promise<string> {
    if (this.dirPath) return this.dirPath;
    const home = await homeDir();
    this.dirPath = await join(home, DIR_NAME);
    return this.dirPath;
  }

  private async getFilePath(): Promise<string> {
    if (this.filePath) return this.filePath;
    const dirPath = await this.getDirPath();
    this.filePath = await join(dirPath, FILE_NAME);
    return this.filePath;
  }

  private async load(): Promise<Record<string, string>> {
    try {
      const filePath = await this.getFilePath();
      const fileExists = await exists(filePath);
      if (!fileExists) {
        return {};
      }
      const raw = await readTextFile(filePath);
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
    const dirPath = await this.getDirPath();
    const dirExists = await exists(dirPath);
    if (!dirExists) {
      await mkdir(dirPath, { recursive: true });
    }

    const filePath = await this.getFilePath();
    await writeTextFile(filePath, JSON.stringify(data, null, 2));
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

export const storage = new TauriFileStorage();
