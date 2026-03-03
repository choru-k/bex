import { beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen, waitFor } from "@testing-library/react";
import { Outlet } from "react-router-dom";

const mocked = vi.hoisted(() => {
  const renderRoot = vi.fn();
  const createRoot = vi.fn(() => ({ render: renderRoot }));

  return {
    renderRoot,
    createRoot,
  };
});

vi.mock("react-dom/client", () => ({
  default: { createRoot: mocked.createRoot },
  createRoot: mocked.createRoot,
}));

vi.mock("./App", () => ({
  default: () => (
    <div>
      <div>App Shell</div>
      <Outlet />
    </div>
  ),
}));

vi.mock("./pages/CheckGrammar", () => ({
  default: () => <div>Check Page</div>,
}));
vi.mock("./pages/History", () => ({
  default: () => <div>History Page</div>,
}));
vi.mock("./pages/Profiles", () => ({
  default: () => <div>Profiles Page</div>,
}));
vi.mock("./pages/Analytics", () => ({
  default: () => <div>Analytics Page</div>,
}));
vi.mock("./pages/Settings", () => ({
  default: () => <div>Settings Page</div>,
}));
vi.mock("./pages/Popup", () => ({
  default: () => <div>Popup Page</div>,
}));

async function renderMainAt(path: string) {
  window.history.pushState({}, "", path);
  await import("./main");

  const app = mocked.renderRoot.mock.calls.at(-1)?.[0];
  if (!app) throw new Error("main.tsx did not render app root");
  render(app);
}

describe("main routes", () => {
  beforeEach(() => {
    vi.resetModules();
    mocked.createRoot.mockClear();
    mocked.renderRoot.mockClear();
    cleanup();
    document.body.innerHTML = '<div id="root"></div>';
  });

  it("renders popup route outside app shell", async () => {
    await renderMainAt("/popup");

    expect(screen.getByText("Popup Page")).toBeInTheDocument();
    expect(screen.queryByText("App Shell")).not.toBeInTheDocument();
  });

  it("renders check route inside app shell", async () => {
    await renderMainAt("/check");

    expect(screen.getByText("App Shell")).toBeInTheDocument();
    expect(screen.getByText("Check Page")).toBeInTheDocument();
  });

  it("redirects unknown routes to /check", async () => {
    await renderMainAt("/does-not-exist");

    await waitFor(() => {
      expect(screen.getByText("Check Page")).toBeInTheDocument();
    });
    expect(window.location.pathname).toBe("/check");
  });
});
