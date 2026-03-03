import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";

const mocked = vi.hoisted(() => {
  const profiles = [
    { id: "p1", name: "Email", prompt: "Keep it professional.", isDefault: false },
    { id: "p2", name: "Slack", prompt: "Keep it casual.", isDefault: false },
  ];

  return {
    profiles,
    loadProfiles: vi.fn().mockResolvedValue([]),
    saveProfiles: vi.fn().mockResolvedValue(undefined),
    generateText: vi.fn().mockResolvedValue("Generated prompt"),
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

vi.mock("@bex/core", () => ({
  loadProfiles: mocked.loadProfiles,
  saveProfiles: mocked.saveProfiles,
  generateText: mocked.generateText,
  PROFILE_GENERATION_PROMPT: "profile-prompt",
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

vi.mock("@/components/ui/button", () => ({
  Button: ({ children, ...props }: React.ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button {...props}>{children}</button>
  ),
}));

vi.mock("@/components/ui/input", () => ({
  Input: (props: React.InputHTMLAttributes<HTMLInputElement>) => <input {...props} />,
}));

vi.mock("@/components/ui/textarea", () => ({
  Textarea: (props: React.TextareaHTMLAttributes<HTMLTextAreaElement>) => (
    <textarea {...props} />
  ),
}));

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
  CardContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("@/components/ui/dialog", () => ({
  Dialog: ({ open, children }: { open: boolean; children: React.ReactNode }) =>
    open ? <div>{children}</div> : null,
  DialogContent: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  DialogHeader: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  DialogTitle: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
  DialogFooter: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
}));

vi.mock("@/components/ui/alert-dialog", () => ({
  AlertDialog: ({ children }: { children: React.ReactNode }) => <div>{children}</div>,
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
  Plus: () => <span data-testid="plus" />,
  Pencil: () => <span data-testid="pencil" />,
  Trash2: () => <span data-testid="trash" />,
  Star: () => <span data-testid="star" />,
  Wand2: () => <span data-testid="wand" />,
  Loader2: () => <span data-testid="loader" />,
}));

import ProfilesPage from "./Profiles";

describe("Profiles page", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("creates a new profile and persists it", async () => {
    mocked.loadProfiles.mockResolvedValue([]);

    render(<ProfilesPage />);

    await waitFor(() => {
      expect(screen.getByText(/No profiles yet/i)).toBeInTheDocument();
    });

    fireEvent.click(screen.getByRole("button", { name: /New Profile/i }));

    fireEvent.change(
      screen.getByPlaceholderText(/e.g., Professional Emails/i),
      { target: { value: "Status Updates" } },
    );
    fireEvent.change(
      screen.getByPlaceholderText(/Instructions for the grammar checker/i),
      { target: { value: "Be concise and clear." } },
    );

    fireEvent.click(screen.getByRole("button", { name: /^Create$/i }));

    await waitFor(() => {
      expect(mocked.saveProfiles).toHaveBeenCalledWith(
        mocked.storage,
        [
          expect.objectContaining({
            name: "Status Updates",
            prompt: "Be concise and clear.",
            isDefault: false,
          }),
        ],
      );
    });
  });

  it("sets selected profile as default", async () => {
    mocked.loadProfiles.mockResolvedValue(mocked.profiles);

    render(<ProfilesPage />);

    await waitFor(() => {
      expect(screen.getByText("Email")).toBeInTheDocument();
      expect(screen.getByText("Slack")).toBeInTheDocument();
    });

    fireEvent.click(screen.getAllByTitle("Set as default")[0]);

    await waitFor(() => {
      expect(mocked.saveProfiles).toHaveBeenCalledWith(
        mocked.storage,
        [
          expect.objectContaining({ id: "p1", isDefault: true }),
          expect.objectContaining({ id: "p2", isDefault: false }),
        ],
      );
    });
  });
});
