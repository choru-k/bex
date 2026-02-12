import type { StorageAdapter } from "@bex/core";
import {
  readTextFile,
  writeTextFile,
  mkdir,
  exists,
} from "@tauri-apps/plugin-fs";
import { homeDir } from "@tauri-apps/api/path";

const FILE_NAME = ".bex/data.json";

export class TauriFileStorage implements StorageAdapter {
  private cache: Record<string, string> | null = null;
  private filePath: string | null = null;

  private async getFilePath(): Promise<string> {
    if (this.filePath) return this.filePath;
    const home = await homeDir();
    this.filePath = `${home}${FILE_NAME}`;
    return this.filePath;
  }

  private async getDirPath(): Promise<string> {
    const home = await homeDir();
    return `${home}.bex`;
  }

  private async load(): Promise<Record<string, string>> {
    if (this.cache) return this.cache;
    try {
      const filePath = await this.getFilePath();
      const fileExists = await exists(filePath);
      if (!fileExists) {
        this.cache = {};
        return this.cache;
      }
      const raw = await readTextFile(filePath);
      this.cache = JSON.parse(raw);
    } catch {
      this.cache = {};
    }
    return this.cache!;
  }

  private async persist(data: Record<string, string>): Promise<void> {
    const dirPath = await this.getDirPath();
    const dirExists = await exists(dirPath);
    if (!dirExists) {
      await mkdir(dirPath, { recursive: true });
    }

    const filePath = await this.getFilePath();
    await writeTextFile(filePath, JSON.stringify(data, null, 2));
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

export const storage = new TauriFileStorage();
