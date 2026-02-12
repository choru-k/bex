import { defineConfig } from "vitest/config";
import path from "path";

export default defineConfig({
  test: {
    globals: true,
    environment: "jsdom",
    include: ["src/**/*.test.{ts,tsx}"],
    setupFiles: ["./src/__test__/setup.ts"],
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      "@tauri-apps/plugin-fs": path.resolve(
        __dirname,
        "./src/__test__/tauri-fs-stub.ts",
      ),
      "@tauri-apps/api/path": path.resolve(
        __dirname,
        "./src/__test__/tauri-path-stub.ts",
      ),
      "@tauri-apps/api/window": path.resolve(
        __dirname,
        "./src/__test__/tauri-window-stub.ts",
      ),
    },
  },
});
