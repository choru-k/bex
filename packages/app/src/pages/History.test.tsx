import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";

const mocked = vi.hoisted(() => {
  const navigate = vi.fn();
  const entry = {
    id: "h1",
    original: "broken sentence",
    corrected: "Fixed sentence.",
    explanation: "Fixed grammar.",
    provider: "openai",
    model: "gpt-4o",
    timestamp: new Date("2026-03-02T00:00:00Z").toISOString(),
  };

  return {
    navigate,
    entry,
    loadHistory: vi.fn().mockResolvedValue([entry]),
    deleteHistoryEntry: vi.fn().mockResolvedValue(undefined),
    clearHistory: vi.fn().mockResolvedValue(undefined),
    computeWordDiff: vi.fn().mockReturnValue([]),
    storage: {
      getItem: vi.fn().mockResolvedValue(undefined),
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

vi.mock("react-router-dom", async () => {
  const actual = await vi.importActual<typeof import("react-router-dom")>(
    "react-router-dom",
  );
  return {
    ...actual,
    useNavigate: () => mocked.navigate,
  };
});

vi.mock("@bex/core", () => ({
  loadHistory: mocked.loadHistory,
  deleteHistoryEntry: mocked.deleteHistoryEntry,
  clearHistory: mocked.clearHistory,
  computeWordDiff: mocked.computeWordDiff,
}));

vi.mock("@/lib/tauri-storage", () => ({
  storage: mocked.storage,
}));

vi.mock("sonner", () => ({
  toast: mocked.toast,
}));

vi.mock("@/components/DiffView", () => ({
  DiffView: ({ diff }: { diff: unknown[] }) => <div>{diff.length} diffs</div>,
}));

vi.mock("@/components/ui/button", () => ({
  Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button {...props}>{children}</button>
  ),
}));

vi.mock("@/components/ui/input", () => ({
  Input: (props: React.InputHTMLAttributes<HTMLInputElement>) => <input {...props} />,
}));

vi.mock("@/components/ui/card", () => ({
  Card: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  CardHeader: ({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
    <div {...props}>{children}</div>
  ),
  CardTitle: ({ children, ...props }: React.HTMLAttributes<HTMLDivElement>) => (
    <div {...props}>{children}</div>
  ),
  CardContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("@/components/ui/select", () => ({
  Select: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectTrigger: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectValue: () => null,
  SelectContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  SelectItem: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("@/components/ui/alert-dialog", () => ({
  AlertDialog: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogTrigger: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogHeader: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogTitle: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogDescription: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogFooter: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  AlertDialogCancel: ({ children }: { children: React.ReactNode }) => <button>{children}</button>,
  AlertDialogAction: ({ children, onClick }: { children: React.ReactNode; onClick?: () => void }) => (
    <button onClick={onClick}>{children}</button>
  ),
}));

vi.mock("@/components/ui/scroll-area", () => ({
  ScrollArea: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("lucide-react", () => ({
  Trash2: () => <span data-testid="trash" />,
  ChevronDown: () => <span data-testid="down" />,
  ChevronRight: () => <span data-testid="right" />,
  Clock: () => <span data-testid="clock" />,
  Search: () => <span data-testid="search" />,
  RotateCcw: () => <span data-testid="rotate" />,
}));

import HistoryPage from "./History";

describe("History page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocked.loadHistory.mockResolvedValue([mocked.entry]);
  });

  it("loads and renders history entries", async () => {
    render(<HistoryPage />);

    await waitFor(() => {
      expect(screen.getByText("1 grammar check")).toBeInTheDocument();
    });

    expect(screen.getByText(/broken sentence/)).toBeInTheDocument();
    expect(screen.getByText(/openai\/gpt-4o/)).toBeInTheDocument();
  });

  it("navigates to check page when using entry as new input", async () => {
    render(<HistoryPage />);

    await waitFor(() => {
      expect(screen.getByText(/broken sentence/)).toBeInTheDocument();
    });

    fireEvent.click(screen.getByText(/broken sentence/));
    fireEvent.click(screen.getByRole("button", { name: /Use as new input/i }));

    expect(mocked.navigate).toHaveBeenCalledWith("/check", {
      state: { draftText: "Fixed sentence." },
    });
  });
});
