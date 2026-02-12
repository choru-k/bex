import { useState, useCallback } from "react";
import { storage } from "@/lib/tauri-storage";
import type { StorageAdapter } from "@bex/core";

interface UseStorageState<T> {
  data: T | undefined;
  loading: boolean;
  error: string | null;
}

export function useStorage() {
  return storage as StorageAdapter;
}

export function useStorageQuery<T>(
  queryFn: (storage: StorageAdapter) => Promise<T>,
) {
  const [state, setState] = useState<UseStorageState<T>>({
    data: undefined,
    loading: false,
    error: null,
  });

  const execute = useCallback(async () => {
    setState((prev) => ({ ...prev, loading: true, error: null }));
    try {
      const data = await queryFn(storage);
      setState({ data, loading: false, error: null });
      return data;
    } catch (err) {
      const message = err instanceof Error ? err.message : "Storage error";
      setState((prev) => ({ ...prev, loading: false, error: message }));
      return undefined;
    }
  }, [queryFn]);

  return { ...state, execute };
}

export function useStorageMutation<TArgs extends unknown[], TResult = void>(
  mutationFn: (storage: StorageAdapter, ...args: TArgs) => Promise<TResult>,
) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const execute = useCallback(
    async (...args: TArgs): Promise<TResult | undefined> => {
      setLoading(true);
      setError(null);
      try {
        const result = await mutationFn(storage, ...args);
        setLoading(false);
        return result;
      } catch (err) {
        const message = err instanceof Error ? err.message : "Storage error";
        setError(message);
        setLoading(false);
        return undefined;
      }
    },
    [mutationFn],
  );

  return { execute, loading, error };
}
