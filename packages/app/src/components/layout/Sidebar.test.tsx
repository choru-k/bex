import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { Sidebar } from "./Sidebar";

describe("Sidebar", () => {
  it("renders all primary nav items and excludes analytics", () => {
    render(
      <MemoryRouter initialEntries={["/check"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    expect(screen.getByRole("link", { name: /Check Grammar/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /^History$/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /^Profiles$/i })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /^Settings$/i })).toBeInTheDocument();
    expect(screen.queryByRole("link", { name: /Analytics/i })).not.toBeInTheDocument();
  });

  it("marks current route as active", () => {
    render(
      <MemoryRouter initialEntries={["/history"]}>
        <Sidebar />
      </MemoryRouter>,
    );

    const historyLink = screen.getByRole("link", { name: /^History$/i });
    const checkLink = screen.getByRole("link", { name: /Check Grammar/i });

    expect(historyLink).toHaveAttribute("aria-current", "page");
    expect(checkLink).not.toHaveAttribute("aria-current", "page");
    expect(historyLink.className).toContain("bg-sidebar-accent");
  });
});
