import { describe, expect, it } from "vitest";
import { cn } from "./utils";

describe("cn", () => {
  it("combines class names", () => {
    expect(cn("px-2", "py-1", "text-sm")).toBe("px-2 py-1 text-sm");
  });

  it("supports conditional and falsy values", () => {
    expect(cn("base", false && "hidden", undefined, "visible")).toBe(
      "base visible",
    );
  });

  it("merges tailwind conflicts keeping the latest", () => {
    expect(cn("px-2", "px-4", "text-sm", "text-lg")).toBe("px-4 text-lg");
  });
});
