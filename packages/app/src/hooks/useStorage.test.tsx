import { describe, expect, it, vi, beforeEach } from "vitest";
import { act, renderHook, waitFor } from "@testing-library/react";

const mocked = vi.hoisted(() => ({
  storage: {
    getItem: vi.fn(),
    setItem: vi.fn(),
    removeItem: vi.fn(),
    getAllKeys: vi.fn(),
  },
}));

vi.mock("@/lib/tauri-storage", () => ({
  storage: mocked.storage,
}));

import { useStorage, useStorageMutation, useStorageQuery } from "./useStorage";

describe("useStorage hooks", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns shared storage adapter", () => {
    const { result } = renderHook(() => useStorage());
    expect(result.current).toBe(mocked.storage);
  });

  it("useStorageQuery returns data on success", async () => {
    const queryFn = vi.fn(async () => "ok");
    const { result } = renderHook(() => useStorageQuery(queryFn));

    await act(async () => {
      await result.current.execute();
    });

    expect(queryFn).toHaveBeenCalledWith(mocked.storage);
    expect(result.current.data).toBe("ok");
    expect(result.current.loading).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it("useStorageQuery exposes error on failure", async () => {
    const queryFn = vi.fn(async () => {
      throw new Error("boom");
    });
    const { result } = renderHook(() => useStorageQuery(queryFn));

    await act(async () => {
      const value = await result.current.execute();
      expect(value).toBeUndefined();
    });

    await waitFor(() => {
      expect(result.current.error).toBe("boom");
    });
    expect(result.current.loading).toBe(false);
  });

  it("useStorageMutation returns result and tracks loading", async () => {
    const mutationFn = vi.fn(async (_storage: unknown, input: string) => input.toUpperCase());
    const { result } = renderHook(() =>
      useStorageMutation<[string], string>(mutationFn),
    );

    await act(async () => {
      const value = await result.current.execute("hello");
      expect(value).toBe("HELLO");
    });

    expect(mutationFn).toHaveBeenCalledWith(mocked.storage, "hello");
    expect(result.current.loading).toBe(false);
    expect(result.current.error).toBeNull();
  });

  it("useStorageMutation exposes error and returns undefined", async () => {
    const mutationFn = vi.fn(async () => {
      throw new Error("write failed");
    });
    const { result } = renderHook(() => useStorageMutation(mutationFn));

    await act(async () => {
      const value = await result.current.execute();
      expect(value).toBeUndefined();
    });

    expect(result.current.loading).toBe(false);
    expect(result.current.error).toBe("write failed");
  });
});
