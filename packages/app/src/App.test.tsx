import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router-dom";

const mocked = vi.hoisted(() => {
  const stopColorSync = vi.fn();

  return {
    stopColorSync,
    storage: {
      getItem: vi.fn(),
      setItem: vi.fn(),
      removeItem: vi.fn(),
      getAllKeys: vi.fn(),
    },
    applyAppTheme: vi.fn(),
    normalizeAppTheme: vi.fn((theme?: string) =>
      theme === "hig-solid" ? "hig-solid" : "hig-glass",
    ),
    normalizeAppColorMode: vi.fn((mode?: string) => {
      if (mode === "light" || mode === "black" || mode === "system") return mode;
      return "system";
    }),
    parsePreferences: vi.fn((raw: unknown) => {
      if (!raw) return null;
      if (typeof raw === "string") return JSON.parse(raw);
      return raw;
    }),
    syncAppColorMode: vi.fn(() => mocked.stopColorSync),
  };
});

vi.mock("@/components/layout/Sidebar", () => ({
  Sidebar: () => <div>Sidebar</div>,
}));

vi.mock("@/components/ui/sonner", () => ({
  Toaster: () => <div>Toaster</div>,
}));

vi.mock("@/lib/tauri-storage", () => ({
  storage: mocked.storage,
}));

vi.mock("@/lib/app-theme", () => ({
  applyAppTheme: mocked.applyAppTheme,
  normalizeAppTheme: mocked.normalizeAppTheme,
  normalizeAppColorMode: mocked.normalizeAppColorMode,
  parsePreferences: mocked.parsePreferences,
  syncAppColorMode: mocked.syncAppColorMode,
}));

import App from "./App";

describe("App shell", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocked.storage.getItem.mockResolvedValue(
      JSON.stringify({ appTheme: "hig-solid", appColorMode: "black" }),
    );
  });

  it("renders shell layout and applies persisted appearance", async () => {
    render(
      <MemoryRouter initialEntries={["/check"]}>
        <Routes>
          <Route element={<App />}>
            <Route path="/check" element={<div>Check page content</div>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    expect(screen.getByText("Sidebar")).toBeInTheDocument();
    expect(screen.getByText("Toaster")).toBeInTheDocument();
    expect(screen.getByText("Check page content")).toBeInTheDocument();

    await waitFor(() => {
      expect(mocked.storage.getItem).toHaveBeenCalledWith("preferences");
      expect(mocked.applyAppTheme).toHaveBeenCalledWith("hig-solid");
      expect(mocked.syncAppColorMode).toHaveBeenCalledWith("black");
    });
  });

  it("cleans up color sync on unmount", async () => {
    const view = render(
      <MemoryRouter initialEntries={["/check"]}>
        <Routes>
          <Route element={<App />}>
            <Route path="/check" element={<div>Check page content</div>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    );

    await waitFor(() => {
      expect(mocked.syncAppColorMode).toHaveBeenCalled();
    });

    view.unmount();

    expect(mocked.stopColorSync).toHaveBeenCalled();
  });
});
