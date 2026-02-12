import { StorageAdapter } from "../storage/storage";

export function createMockStorage(): StorageAdapter {
  const store = new Map<string, string>();
  return {
    async getItem<T = string>(key: string): Promise<T | undefined> {
      const val = store.get(key);
      return val as T | undefined;
    },
    async setItem(key: string, value: string): Promise<void> {
      store.set(key, value);
    },
    async removeItem(key: string): Promise<void> {
      store.delete(key);
    },
    async getAllKeys(): Promise<string[]> {
      return [...store.keys()];
    },
  };
}
