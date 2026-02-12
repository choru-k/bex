import { describe, it, expect } from "vitest";
import { render } from "@testing-library/react";
import type { DiffWord } from "@bex/core";
import { DiffView } from "./DiffView";

describe("DiffView", () => {
  it("renders unchanged text as plain spans", () => {
    const diff: DiffWord[] = [
      { text: "hello", type: "unchanged" },
      { text: " ", type: "unchanged" },
      { text: "world", type: "unchanged" },
    ];
    const { container } = render(<DiffView diff={diff} />);
    const spans = container.querySelectorAll("span");
    expect(spans).toHaveLength(3);
    spans.forEach((span) => {
      expect(span.className).toBe("");
    });
  });

  it("renders added text with green background class", () => {
    const diff: DiffWord[] = [{ text: "new", type: "added" }];
    const { container } = render(<DiffView diff={diff} />);
    const span = container.querySelector("span")!;
    expect(span.textContent).toBe("new");
    expect(span.className).toContain("bg-green");
  });

  it("renders removed text with red background and line-through", () => {
    const diff: DiffWord[] = [{ text: "old", type: "removed" }];
    const { container } = render(<DiffView diff={diff} />);
    const span = container.querySelector("span")!;
    expect(span.textContent).toBe("old");
    expect(span.className).toContain("bg-red");
    expect(span.className).toContain("line-through");
  });

  it("renders correct number of spans for mixed diff", () => {
    const diff: DiffWord[] = [
      { text: "the", type: "unchanged" },
      { text: " ", type: "unchanged" },
      { text: "cat", type: "removed" },
      { text: "dog", type: "added" },
    ];
    const { container } = render(<DiffView diff={diff} />);
    const spans = container.querySelectorAll("span");
    expect(spans).toHaveLength(4);
  });

  it("renders empty diff without crashing", () => {
    const { container } = render(<DiffView diff={[]} />);
    const spans = container.querySelectorAll("span");
    expect(spans).toHaveLength(0);
  });

  it("passes custom className through", () => {
    const diff: DiffWord[] = [{ text: "hello", type: "unchanged" }];
    const { container } = render(
      <DiffView diff={diff} className="custom-class" />,
    );
    const wrapper = container.firstElementChild!;
    expect(wrapper.className).toContain("custom-class");
  });
});
