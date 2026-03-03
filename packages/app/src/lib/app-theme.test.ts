import { beforeEach, describe, expect, it, vi } from "vitest";
import { waitFor } from "@testing-library/react";

const mocked = vi.hoisted(() => {
  const setBackgroundColor = vi.fn().mockResolvedValue(undefined);
  const getCurrentWindow = vi.fn(() => ({ setBackgroundColor }));

  return {
    setBackgroundColor,
    getCurrentWindow,
  };
});

vi.mock("@tauri-apps/api/window", () => ({
  getCurrentWindow: mocked.getCurrentWindow,
}));

import {
  applyAppTheme,
  normalizeAppTheme,
  normalizeAppColorMode,
  parsePreferences,
  syncAppColorMode,
} from "./app-theme";

function installMatchMedia(initialMatches: boolean) {
  let changeHandler: ((event: { matches: boolean }) => void) | null = null;
  const mediaQuery = {
    matches: initialMatches,
    media: "(prefers-color-scheme: dark)",
    addEventListener: vi.fn((type: string, cb: (event: { matches: boolean }) => void) => {
      if (type === "change") changeHandler = cb;
    }),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    onchange: null,
    dispatchEvent: vi.fn(),
  };

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn(() => mediaQuery),
  });

  return {
    mediaQuery,
    emit(next: boolean) {
      mediaQuery.matches = next;
      changeHandler?.({ matches: next });
    },
  };
}

describe("app-theme", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    document.documentElement.removeAttribute("data-app-theme");
    document.documentElement.removeAttribute("data-color-mode");
    document.documentElement.removeAttribute("data-color-mode-resolved");
    document.documentElement.classList.remove("dark");
    document.documentElement.style.colorScheme = "";
    delete (window as Record<string, unknown>).__TAURI_INTERNALS__;
  });

  it("normalizes theme and color mode values", () => {
    expect(normalizeAppTheme("hig-solid")).toBe("hig-solid");
    expect(normalizeAppTheme("unexpected")).toBe("hig-glass");

    expect(normalizeAppColorMode("light")).toBe("light");
    expect(normalizeAppColorMode("black")).toBe("black");
    expect(normalizeAppColorMode("system")).toBe("system");
    expect(normalizeAppColorMode("unexpected")).toBe("system");
  });

  it("applies app theme attribute", () => {
    applyAppTheme("hig-glass");
    expect(document.documentElement.getAttribute("data-app-theme")).toBe("glass");

    applyAppTheme("hig-solid");
    expect(document.documentElement.getAttribute("data-app-theme")).toBe("solid");
  });

  it("syncs system color mode and cleans up media listeners", async () => {
    (window as Record<string, unknown>).__TAURI_INTERNALS__ = {};
    const { mediaQuery, emit } = installMatchMedia(false);

    const cleanup = syncAppColorMode("system");

    expect(document.documentElement.getAttribute("data-color-mode")).toBe("system");
    expect(document.documentElement.getAttribute("data-color-mode-resolved")).toBe("light");
    expect(document.documentElement.classList.contains("dark")).toBe(false);

    await waitFor(() => {
      expect(mocked.setBackgroundColor).toHaveBeenCalledWith("#f4f6fb");
    });

    emit(true);

    expect(document.documentElement.getAttribute("data-color-mode-resolved")).toBe("black");
    expect(document.documentElement.classList.contains("dark")).toBe(true);

    await waitFor(() => {
      expect(mocked.setBackgroundColor).toHaveBeenCalledWith("#080808");
    });

    cleanup();

    expect(mediaQuery.addEventListener).toHaveBeenCalledWith(
      "change",
      expect.any(Function),
    );
    expect(mediaQuery.removeEventListener).toHaveBeenCalledWith(
      "change",
      expect.any(Function),
    );
  });

  it("parses preferences from both JSON string and object", () => {
    const fromString = parsePreferences('{"provider":"openai"}');
    const fromObject = parsePreferences({ provider: "openai" });

    expect(fromString).toEqual({ provider: "openai" });
    expect(fromObject).toEqual({ provider: "openai" });
    expect(parsePreferences("invalid-json")).toBeNull();
    expect(parsePreferences(undefined)).toBeNull();
  });
});
