import { getCurrentWindow } from "@tauri-apps/api/window";
import type { Preferences } from "@bex/core";

export type AppTheme = "hig-glass" | "hig-solid";
export type AppColorMode = "light" | "black" | "system";

export const DEFAULT_APP_THEME: AppTheme = "hig-glass";
export const DEFAULT_APP_COLOR_MODE: AppColorMode = "system";

const DARK_MEDIA_QUERY = "(prefers-color-scheme: dark)";

const WINDOW_BACKGROUND_BY_MODE: Record<"light" | "black", string> = {
  light: "#f4f6fb",
  black: "#080808",
};

export function normalizeAppTheme(theme?: string): AppTheme {
  return theme === "hig-solid" ? "hig-solid" : DEFAULT_APP_THEME;
}

export function normalizeAppColorMode(mode?: string): AppColorMode {
  if (mode === "light" || mode === "black" || mode === "system") {
    return mode;
  }
  return DEFAULT_APP_COLOR_MODE;
}

export function applyAppTheme(theme: AppTheme): void {
  if (typeof document === "undefined") return;
  const value = theme === "hig-solid" ? "solid" : "glass";
  document.documentElement.setAttribute("data-app-theme", value);
}

function resolveAppColorMode(mode: AppColorMode): "light" | "black" {
  if (mode !== "system") return mode;
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return "light";
  }
  return window.matchMedia(DARK_MEDIA_QUERY).matches ? "black" : "light";
}

function isTauriWindowEnvironment(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

async function applyWindowBackgroundColor(
  resolved: "light" | "black",
): Promise<void> {
  if (!isTauriWindowEnvironment()) return;

  try {
    await getCurrentWindow().setBackgroundColor(
      WINDOW_BACKGROUND_BY_MODE[resolved],
    );
  } catch {
    // ignore platform/permission failures
  }
}

export function syncAppColorMode(mode: AppColorMode): () => void {
  if (typeof document === "undefined") return () => {};

  const root = document.documentElement;
  root.setAttribute("data-color-mode", mode);

  let lastResolved: "light" | "black" | null = null;

  const applyResolved = () => {
    const resolved = resolveAppColorMode(mode);
    root.setAttribute("data-color-mode-resolved", resolved);
    root.classList.toggle("dark", resolved === "black");
    root.style.colorScheme = resolved === "black" ? "dark" : "light";

    if (lastResolved !== resolved) {
      lastResolved = resolved;
      void applyWindowBackgroundColor(resolved);
    }
  };

  applyResolved();

  if (mode !== "system") {
    return () => {};
  }

  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return () => {};
  }

  const mediaQuery = window.matchMedia(DARK_MEDIA_QUERY);
  const handleChange = () => applyResolved();

  if (typeof mediaQuery.addEventListener === "function") {
    mediaQuery.addEventListener("change", handleChange);
    return () => mediaQuery.removeEventListener("change", handleChange);
  }

  mediaQuery.addListener(handleChange);
  return () => mediaQuery.removeListener(handleChange);
}

export function parsePreferences(raw: unknown): Preferences | null {
  if (!raw) return null;

  if (typeof raw === "string") {
    try {
      return JSON.parse(raw) as Preferences;
    } catch {
      return null;
    }
  }

  if (typeof raw === "object") {
    return raw as Preferences;
  }

  return null;
}
