import { useEffect } from "react";
import { Outlet } from "react-router-dom";
import { Sidebar } from "@/components/layout/Sidebar";
import { Toaster } from "@/components/ui/sonner";
import { storage } from "@/lib/tauri-storage";
import {
  applyAppTheme,
  normalizeAppTheme,
  normalizeAppColorMode,
  parsePreferences,
  syncAppColorMode,
} from "@/lib/app-theme";

const PREFS_KEY = "preferences";

export default function App() {
  useEffect(() => {
    let cancelled = false;
    let stopColorSync = () => {};

    (async () => {
      const raw = await storage.getItem<unknown>(PREFS_KEY);
      if (cancelled) return;

      const prefs = parsePreferences(raw);
      applyAppTheme(normalizeAppTheme(prefs?.appTheme));
      stopColorSync = syncAppColorMode(
        normalizeAppColorMode(prefs?.appColorMode),
      );
    })();

    return () => {
      cancelled = true;
      stopColorSync();
    };
  }, []);

  return (
    <div className="relative flex h-screen overflow-hidden">
      <div data-tauri-drag-region className="absolute inset-x-0 top-0 z-30 h-8" />
      <Sidebar />
      <main className="flex-1 overflow-auto bg-background/40 px-6 pb-6 pt-10">
        <Outlet />
      </main>
      <Toaster />
    </div>
  );
}
