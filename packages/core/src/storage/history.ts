import { HistoryEntry } from "../llm/types";
import { StorageAdapter } from "./storage";

const HISTORY_KEY = "history";
const MAX_HISTORY_ENTRIES = 500;

export async function loadHistory(storage: StorageAdapter): Promise<HistoryEntry[]> {
  const raw = await storage.getItem<string>(HISTORY_KEY);
  if (!raw) return [];
  try {
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

export async function saveToHistory(storage: StorageAdapter, entry: HistoryEntry): Promise<void> {
  const entries = await loadHistory(storage);
  entries.unshift(entry);
  if (entries.length > MAX_HISTORY_ENTRIES) entries.length = MAX_HISTORY_ENTRIES;
  await storage.setItem(HISTORY_KEY, JSON.stringify(entries));
}

export async function deleteHistoryEntry(storage: StorageAdapter, id: string): Promise<void> {
  const entries = await loadHistory(storage);
  const updated = entries.filter((e) => e.id !== id);
  await storage.setItem(HISTORY_KEY, JSON.stringify(updated));
}

export async function clearHistory(storage: StorageAdapter): Promise<void> {
  await storage.removeItem(HISTORY_KEY);
}
