import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

const mocked = vi.hoisted(() => {
  const prefs = {
    provider: "openai",
    model: "gpt-4o",
    openaiApiKey: "sk-test",
  };

  return {
    prefs,
    checkGrammar: vi.fn(),
    buildSystemPrompt: vi.fn().mockReturnValue("system-prompt"),
    fetchModels: vi.fn().mockResolvedValue([{ id: "gpt-4o", name: "GPT-4o" }]),
    computeWordDiff: vi.fn().mockReturnValue([]),
    loadProfiles: vi.fn().mockResolvedValue([]),
    getActiveProfileId: vi.fn().mockResolvedValue(""),
    setActiveProfileId: vi.fn().mockResolvedValue(undefined),
    getDefaultProfile: vi.fn().mockReturnValue(undefined),
    saveToHistory: vi.fn().mockResolvedValue(undefined),
    generateText: vi.fn(),
    storage: {
      getItem: vi.fn(async (key: string) => {
        if (key === "preferences") return JSON.stringify(prefs);
        return undefined;
      }),
      setItem: vi.fn().mockResolvedValue(undefined),
      removeItem: vi.fn().mockResolvedValue(undefined),
      getAllKeys: vi.fn().mockResolvedValue([]),
    },
    toast: {
      success: vi.fn(),
      error: vi.fn(),
      message: vi.fn(),
    },
  };
});

vi.mock("@bex/core", () => ({
  checkGrammar: mocked.checkGrammar,
  buildSystemPrompt: mocked.buildSystemPrompt,
  fetchModels: mocked.fetchModels,
  DEFAULT_MODELS: {
    openai: "gpt-4o",
    "openai-codex": "gpt-5.1-codex-mini",
    claude: "claude-sonnet-4-5-20250929",
    gemini: "gemini-2.5-flash",
    ollama: "llama3.2",
  },
  computeWordDiff: mocked.computeWordDiff,
  loadProfiles: mocked.loadProfiles,
  getActiveProfileId: mocked.getActiveProfileId,
  setActiveProfileId: mocked.setActiveProfileId,
  getDefaultProfile: mocked.getDefaultProfile,
  saveToHistory: mocked.saveToHistory,
  generateText: mocked.generateText,
}));

vi.mock("@/lib/tauri-storage", () => ({
  storage: mocked.storage,
}));

vi.mock("@/lib/app-theme", () => ({
  parsePreferences: vi.fn((raw: unknown) => {
    if (!raw) return null;
    if (typeof raw === "string") return JSON.parse(raw);
    return raw;
  }),
}));

vi.mock("sonner", () => ({
  toast: mocked.toast,
}));

vi.mock("@/components/DiffView", () => ({
  DiffView: ({ diff }: { diff: unknown[] }) => (
    <div data-testid="diff-view">{diff.length} diffs</div>
  ),
}));

vi.mock("@/components/ui/button", () => ({
  Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button {...props}>{children}</button>
  ),
}));

vi.mock("@/components/ui/textarea", async () => {
  const { forwardRef } = await import("react");
  return {
    Textarea: forwardRef<
      HTMLTextAreaElement,
      React.TextareaHTMLAttributes<HTMLTextAreaElement>
    >((props, ref) => <textarea ref={ref} {...props} />),
  };
});

vi.mock("@/components/ui/label", () => ({
  Label: ({ children, ...props }: React.LabelHTMLAttributes<HTMLLabelElement>) => (
    <label {...props}>{children}</label>
  ),
}));

vi.mock("@/components/ui/card", () => ({
  Card: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardHeader: ({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
    <div {...props}>{children}</div>
  ),
  CardTitle: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardContent: ({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
    <div {...props}>{children}</div>
  ),
}));

vi.mock("@/components/ui/select", () => ({
  Select: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectTrigger: ({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
    <div {...props}>{children}</div>
  ),
  SelectValue: ({ placeholder }: { placeholder?: string }) => <span>{placeholder}</span>,
  SelectContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectItem: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("lucide-react", () => ({
  Loader2: () => <span data-testid="loader" />,
  SpellCheck: () => <span data-testid="spellcheck" />,
  Copy: () => <span data-testid="copy" />,
  Check: () => <span data-testid="check" />,
  Sparkles: () => <span data-testid="sparkles" />,
  RotateCcw: () => <span data-testid="rotate" />,
  Settings2: () => <span data-testid="settings" />,
}));

import { checkGrammar, saveToHistory } from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import CheckGrammarPage from "./CheckGrammar";

function renderPage() {
  return render(
    <MemoryRouter>
      <CheckGrammarPage />
    </MemoryRouter>,
  );
}

describe("CheckGrammar page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocked.storage.getItem.mockImplementation(async (key: string) => {
      if (key === "preferences") return JSON.stringify(mocked.prefs);
      return undefined;
    });
    mocked.fetchModels.mockResolvedValue([{ id: "gpt-4o", name: "GPT-4o" }]);
    mocked.loadProfiles.mockResolvedValue([]);
  });

  it("saves history entry after successful check", async () => {
    vi.mocked(checkGrammar).mockResolvedValue({
      corrected: "Fixed text.",
      explanation: "Fixed grammar.",
    });

    renderPage();

    await waitFor(() => {
      expect(screen.queryByText("Setup required")).not.toBeInTheDocument();
    });

    fireEvent.change(screen.getByPlaceholderText(/Type or paste your text here/i), {
      target: { value: "broken text" },
    });

    fireEvent.click(screen.getByRole("button", { name: /check/i }));

    await waitFor(() => {
      expect(saveToHistory).toHaveBeenCalledWith(
        storage,
        expect.objectContaining({
          original: "broken text",
          corrected: "Fixed text.",
          explanation: "Fixed grammar.",
          provider: "openai",
          model: "gpt-4o",
        }),
      );
    });
  });

  it("keeps success flow even when history persistence fails", async () => {
    vi.mocked(checkGrammar).mockResolvedValue({
      corrected: "Fixed text.",
      explanation: "Fixed grammar.",
    });
    vi.mocked(saveToHistory).mockRejectedValueOnce(new Error("disk full"));

    renderPage();

    await waitFor(() => {
      expect(screen.queryByText("Setup required")).not.toBeInTheDocument();
    });

    fireEvent.change(screen.getByPlaceholderText(/Type or paste your text here/i), {
      target: { value: "broken text" },
    });

    fireEvent.click(screen.getByRole("button", { name: /check/i }));

    await waitFor(() => {
      expect(screen.getByText("Corrected Text")).toBeInTheDocument();
      expect(screen.getByText("Fixed text.")).toBeInTheDocument();
    });

    expect(mocked.toast.error).not.toHaveBeenCalledWith(
      expect.stringContaining("Check failed"),
    );
  });
});
