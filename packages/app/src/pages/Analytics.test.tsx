import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import Analytics from "./Analytics";

describe("Analytics page", () => {
  it("renders placeholder heading and description", () => {
    render(<Analytics />);

    expect(
      screen.getByRole("heading", { name: "Analytics", level: 2 }),
    ).toBeInTheDocument();
    expect(screen.getByText("Analytics page coming soon.")).toBeInTheDocument();
  });
});
