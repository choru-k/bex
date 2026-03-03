import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";

const mocked = vi.hoisted(() => {
  const memory: Record<string, string> = {};

  return {
    memory,
    flow: {
      url: "https://auth.openai.com/mock",
      state: "mock-state",
      verifier: "mock-verifier",
    },
    session: {
      accessToken: "access-token",
      refreshToken: "refresh-token",
      expiresAt: 1_900_000_000_000,
      accountId: "account-id",
    },
    storage: {
      getItem: vi.fn(async (key: string) => mocked.memory[key]),
      setItem: vi.fn(async (key: string, value: string) => {
        mocked.memory[key] = value;
      }),
      removeItem: vi.fn(async (key: string) => {
        delete mocked.memory[key];
      }),
      getAllKeys: vi.fn(async () => Object.keys(mocked.memory)),
    },
    fetchModels: vi.fn(async () => [{ id: "gpt-5.1-codex-mini", name: "GPT-5.1 Codex Mini" }]),
    beginOpenAICodexOAuth: vi.fn(async () => mocked.flow),
    completeOpenAICodexOAuth: vi.fn(async () => mocked.session),
    applyOpenAICodexSessionToPreferences: vi.fn((prefs: Record<string, unknown>, session: typeof mocked.session) => ({
      ...prefs,
      openaiCodexAccessToken: session.accessToken,
      openaiCodexRefreshToken: session.refreshToken,
      openaiCodexExpiresAt: session.expiresAt,
      openaiCodexAccountId: session.accountId,
    })),
    invoke: vi.fn(async () => "http://localhost:1455/auth/callback?code=abc&state=mock-state"),
    openUrl: vi.fn(async () => undefined),
    toast: {
      success: vi.fn(),
      error: vi.fn(),
      message: vi.fn(),
    },
  };
});

vi.mock("@bex/core", () => ({
  fetchModels: mocked.fetchModels,
  DEFAULT_MODELS: {
    openai: "gpt-4.1-mini",
    "openai-codex": "gpt-5.1-codex-mini",
    claude: "claude-sonnet-4-5-20250929",
    gemini: "gemini-2.5-flash",
    ollama: "llama3.2",
  },
  beginOpenAICodexOAuth: mocked.beginOpenAICodexOAuth,
  completeOpenAICodexOAuth: mocked.completeOpenAICodexOAuth,
  applyOpenAICodexSessionToPreferences: mocked.applyOpenAICodexSessionToPreferences,
}));

vi.mock("@/lib/tauri-storage", () => ({
  storage: mocked.storage,
}));

vi.mock("@tauri-apps/api/core", () => ({
  invoke: mocked.invoke,
}));

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: mocked.openUrl,
}));

vi.mock("sonner", () => ({
  toast: mocked.toast,
}));

vi.mock("@/lib/app-theme", () => ({
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
  syncAppColorMode: vi.fn(() => () => {}),
  DEFAULT_APP_THEME: "hig-glass",
  DEFAULT_APP_COLOR_MODE: "system",
}));

vi.mock("@/components/ui/button", () => ({
  Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button {...props}>{children}</button>
  ),
}));

vi.mock("@/components/ui/input", () => ({
  Input: (props: React.InputHTMLAttributes<HTMLInputElement>) => <input {...props} />,
}));

vi.mock("@/components/ui/label", () => ({
  Label: ({ children, ...props }: React.LabelHTMLAttributes<HTMLLabelElement>) => (
    <label {...props}>{children}</label>
  ),
}));

vi.mock("@/components/ui/card", () => ({
  Card: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardHeader: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardTitle: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardDescription: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("@/components/ui/select", () => ({
  Select: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectTrigger: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectValue: () => null,
  SelectContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectItem: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("lucide-react", () => ({
  Loader2: () => <span data-testid="loader" />,
  Eye: () => <span data-testid="eye" />,
  EyeOff: () => <span data-testid="eye-off" />,
  RotateCcw: () => <span data-testid="rotate" />,
  Link2: () => <span data-testid="link" />,
  LogOut: () => <span data-testid="logout" />,
}));

import Settings from "./Settings";

describe("Settings Codex OAuth persistence", () => {
  beforeEach(() => {
    vi.clearAllMocks();

    Object.keys(mocked.memory).forEach((key) => delete mocked.memory[key]);
    mocked.memory.preferences = JSON.stringify({
      provider: "openai-codex",
      appTheme: "hig-glass",
      appColorMode: "system",
    });
  });

  it("keeps connected status after remount when Codex auth was saved", async () => {
    const view = render(<Settings />);

    await waitFor(() => {
      expect(screen.getByRole("button", { name: /Connect ChatGPT/i })).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: /Connect ChatGPT/i }));

    await waitFor(() => {
      expect(screen.getByText(/Status:\s*Connected/)).toBeInTheDocument();
    });

    expect(mocked.openUrl).toHaveBeenCalledWith(mocked.flow.url);
    expect(mocked.invoke).toHaveBeenCalledWith("openai_codex_wait_for_callback", {
      payload: { state: mocked.flow.state, timeoutMs: 180_000 },
    });

    const savedPrefs = JSON.parse(mocked.memory.preferences);
    expect(savedPrefs.openaiCodexRefreshToken).toBe("refresh-token");

    view.unmount();
    render(<Settings />);

    await waitFor(() => {
      expect(screen.getByText(/Status:\s*Connected/)).toBeInTheDocument();
    });
    expect(
      screen.getByRole("button", { name: /Reconnect ChatGPT/i }),
    ).toBeInTheDocument();
  });

  it("auto-saves changes and does not render a Save Settings button", async () => {
    mocked.memory.preferences = JSON.stringify({
      provider: "openai",
      openaiApiKey: "sk-old",
      appTheme: "hig-glass",
      appColorMode: "system",
    });

    render(<Settings />);

    await waitFor(() => {
      expect(screen.getByPlaceholderText("sk-...")).toBeInTheDocument();
    });

    expect(
      screen.queryByRole("button", { name: /Save settings/i }),
    ).not.toBeInTheDocument();

    fireEvent.change(screen.getByPlaceholderText("sk-..."), {
      target: { value: "sk-new" },
    });

    await waitFor(() => {
      const savedPrefs = JSON.parse(mocked.memory.preferences);
      expect(savedPrefs.openaiApiKey).toBe("sk-new");
    });
  });
});
