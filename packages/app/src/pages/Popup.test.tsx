import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

// ── Mocks ───────────────────────────────────────────────────────────

vi.mock("@bex/core", () => ({
  checkGrammar: vi.fn(),
  buildSystemPrompt: vi.fn().mockReturnValue("system-prompt"),
  computeWordDiff: vi.fn().mockReturnValue([]),
  loadProfiles: vi.fn().mockResolvedValue([]),
  getActiveProfileId: vi.fn().mockResolvedValue(null),
  getDefaultProfile: vi.fn().mockReturnValue(null),
  saveToHistory: vi.fn().mockResolvedValue(undefined),
  generateText: vi.fn(),
  DEFAULT_MODELS: { openai: "gpt-4o" },
}));

vi.mock("@/lib/tauri-storage", () => ({
  storage: {
    getItem: vi.fn().mockResolvedValue(undefined),
    setItem: vi.fn().mockResolvedValue(undefined),
    removeItem: vi.fn().mockResolvedValue(undefined),
    getAllKeys: vi.fn().mockResolvedValue([]),
  },
}));

vi.mock("@/components/DiffView", () => ({
  DiffView: ({ diff }: { diff: unknown[] }) => (
    <div data-testid="diff-view">{diff.length} diffs</div>
  ),
}));

vi.mock("@/components/ui/button", () => ({
  Button: ({
    children,
    ...props
  }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
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

vi.mock("lucide-react", () => ({
  Loader2: () => <span data-testid="loader" />,
  SpellCheck: () => <span data-testid="spellcheck-icon" />,
  Copy: () => <span data-testid="copy-icon" />,
  Check: () => <span data-testid="check-icon" />,
  Sparkles: () => <span data-testid="sparkles-icon" />,
  Settings2: () => <span data-testid="settings-icon" />,
}));

import { checkGrammar, saveToHistory } from "@bex/core";
import { storage } from "@/lib/tauri-storage";
import { getCurrentWindow } from "@tauri-apps/api/window";
import Popup from "./Popup";

const PREFS = {
  provider: "openai",
  model: "gpt-4o",
  openaiApiKey: "sk-test",
};

function setupPrefsLoaded() {
  vi.mocked(storage.getItem).mockImplementation(async (key: string) => {
    if (key === "preferences") return JSON.stringify(PREFS);
    return undefined;
  });
}

function renderPopup() {
  return render(
    <MemoryRouter>
      <Popup />
    </MemoryRouter>,
  );
}

async function waitForConfiguredState() {
  await waitFor(() => {
    expect(screen.queryByText("Setup required")).not.toBeInTheDocument();
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(storage.getItem).mockResolvedValue(undefined);
});

// ── Tests ───────────────────────────────────────────────────────────

describe("Popup", () => {
  it("renders initial UI", () => {
    renderPopup();

    expect(screen.getByText("Quick Check")).toBeInTheDocument();
    expect(
      screen.getByPlaceholderText(/Type or paste text here/),
    ).toBeInTheDocument();
    expect(screen.getByText("Check")).toBeInTheDocument();
    expect(screen.getByText("Results will appear here")).toBeInTheDocument();
  });

  it("check button is disabled when input is empty", () => {
    renderPopup();

    const btn = screen.getByText("Check").closest("button")!;
    expect(btn).toBeDisabled();
  });

  it("check button is enabled when input has text and prefs are configured", async () => {
    setupPrefsLoaded();
    renderPopup();
    await waitForConfiguredState();

    const textarea = screen.getByPlaceholderText(/Type or paste text here/);
    fireEvent.change(textarea, { target: { value: "hello world" } });

    const btn = screen.getByText("Check").closest("button")!;
    expect(btn).not.toBeDisabled();
  });

  it("Escape key calls window.close()", () => {
    renderPopup();

    fireEvent.keyDown(window, { key: "Escape" });
    expect(getCurrentWindow().close).toHaveBeenCalled();
  });

  it("shows results after successful grammar check", async () => {
    setupPrefsLoaded();
    vi.mocked(checkGrammar).mockResolvedValue({
      corrected: "Hello, world!",
      explanation: "Capitalized and added punctuation.",
    });

    renderPopup();
    await waitForConfiguredState();

    const textarea = screen.getByPlaceholderText(/Type or paste text here/);
    fireEvent.change(textarea, { target: { value: "hello world" } });

    const btn = screen.getByText("Check").closest("button")!;
    fireEvent.click(btn);

    await waitFor(() => {
      expect(screen.getByText("Diff")).toBeInTheDocument();
      expect(screen.getByText("Corrected")).toBeInTheDocument();
      expect(screen.getByText("Hello, world!")).toBeInTheDocument();
      expect(screen.getByText("Explanation")).toBeInTheDocument();
      expect(
        screen.getByText("Capitalized and added punctuation."),
      ).toBeInTheDocument();
    });
  });

  it("saves to history after successful check", async () => {
    setupPrefsLoaded();
    vi.mocked(checkGrammar).mockResolvedValue({
      corrected: "Fixed text.",
      explanation: "Fixed it.",
    });

    renderPopup();
    await waitForConfiguredState();

    const textarea = screen.getByPlaceholderText(/Type or paste text here/);
    fireEvent.change(textarea, { target: { value: "broken text" } });

    fireEvent.click(screen.getByText("Check").closest("button")!);

    await waitFor(() => {
      expect(saveToHistory).toHaveBeenCalledWith(
        storage,
        expect.objectContaining({
          original: "broken text",
          corrected: "Fixed text.",
          explanation: "Fixed it.",
          provider: "openai",
          model: "gpt-4o",
        }),
      );
    });
  });

  it("shows setup guardrail when no prefs configured", async () => {
    // storage.getItem returns undefined (no prefs)
    renderPopup();

    await waitFor(() => {
      expect(screen.getByText("Setup required")).toBeInTheDocument();
    });

    expect(
      screen.getByText(/Configure your provider and API key in Settings/),
    ).toBeInTheDocument();
  });

  it("copy button copies corrected text to clipboard", async () => {
    setupPrefsLoaded();
    vi.mocked(checkGrammar).mockResolvedValue({
      corrected: "Corrected text here.",
      explanation: "Explanation.",
    });

    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, {
      clipboard: { writeText },
    });

    renderPopup();
    await waitForConfiguredState();

    const textarea = screen.getByPlaceholderText(/Type or paste text here/);
    fireEvent.change(textarea, { target: { value: "wrong text" } });

    fireEvent.click(screen.getByText("Check").closest("button")!);

    await waitFor(() => {
      expect(screen.getByText("Copy")).toBeInTheDocument();
    });

    fireEvent.click(screen.getByText("Copy").closest("button")!);

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith("Corrected text here.");
    });
  });
});
