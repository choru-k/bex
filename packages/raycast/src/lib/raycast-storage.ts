import { LocalStorage } from "@raycast/api";
import type { StorageAdapter } from "@bex/core";
import { JsonFileStorage } from "@bex/core/node";

const fileStorage = new JsonFileStorage();

export class RaycastSyncStorage implements StorageAdapter {
  async getItem<T = string>(key: string): Promise<T | undefined> {
    const value = await LocalStorage.getItem<string>(key);
    return value as T | undefined;
  }
  async setItem(key: string, value: string): Promise<void> {
    await LocalStorage.setItem(key, value);
    try { await fileStorage.setItem(key, value); } catch { /* non-blocking */ }
  }
  async removeItem(key: string): Promise<void> {
    await LocalStorage.removeItem(key);
    try { await fileStorage.removeItem(key); } catch { /* non-blocking */ }
  }
  async getAllKeys(): Promise<string[]> {
    return LocalStorage.allItems().then(items => Object.keys(items));
  }
}

export const storage = new RaycastSyncStorage();
