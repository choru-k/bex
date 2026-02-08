export interface StorageAdapter {
  getItem<T = string>(key: string): Promise<T | undefined>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
  getAllKeys(): Promise<string[]>;
}
