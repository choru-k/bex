import { describe, it, expect } from "vitest";
import { Profile } from "../llm/types";
import { createMockStorage } from "../__test__/mock-storage";
import {
  getDefaultProfile,
  loadProfiles,
  saveProfiles,
  getActiveProfileId,
  setActiveProfileId,
} from "./profiles";

// --- Pure function tests (Phase 1) ---

describe("getDefaultProfile", () => {
  it("finds profile with isDefault: true", () => {
    const profiles: Profile[] = [
      { id: "1", name: "A", prompt: "a" },
      { id: "2", name: "B", prompt: "b", isDefault: true },
    ];
    expect(getDefaultProfile(profiles)).toEqual(profiles[1]);
  });

  it("returns undefined when none is default", () => {
    const profiles: Profile[] = [
      { id: "1", name: "A", prompt: "a" },
      { id: "2", name: "B", prompt: "b" },
    ];
    expect(getDefaultProfile(profiles)).toBeUndefined();
  });

  it("returns undefined for empty array", () => {
    expect(getDefaultProfile([])).toBeUndefined();
  });

  it("returns first default if multiple exist", () => {
    const profiles: Profile[] = [
      { id: "1", name: "A", prompt: "a", isDefault: true },
      { id: "2", name: "B", prompt: "b", isDefault: true },
    ];
    expect(getDefaultProfile(profiles)).toEqual(profiles[0]);
  });
});

// --- Async storage tests (Phase 2) ---

describe("loadProfiles", () => {
  it("returns empty array when storage is empty", async () => {
    const storage = createMockStorage();
    expect(await loadProfiles(storage)).toEqual([]);
  });

  it("parses valid JSON from storage", async () => {
    const storage = createMockStorage();
    const profiles: Profile[] = [{ id: "1", name: "A", prompt: "a" }];
    await storage.setItem("profiles", JSON.stringify(profiles));
    expect(await loadProfiles(storage)).toEqual(profiles);
  });

  it("returns empty array for corrupt JSON", async () => {
    const storage = createMockStorage();
    await storage.setItem("profiles", "not-json");
    expect(await loadProfiles(storage)).toEqual([]);
  });
});

describe("saveProfiles", () => {
  it("round-trips profiles through storage", async () => {
    const storage = createMockStorage();
    const profiles: Profile[] = [
      { id: "1", name: "A", prompt: "a" },
      { id: "2", name: "B", prompt: "b", isDefault: true },
    ];
    await saveProfiles(storage, profiles);
    expect(await loadProfiles(storage)).toEqual(profiles);
  });
});

describe("getActiveProfileId / setActiveProfileId", () => {
  it("returns undefined when unset", async () => {
    const storage = createMockStorage();
    expect(await getActiveProfileId(storage)).toBeUndefined();
  });

  it("round-trips active profile id", async () => {
    const storage = createMockStorage();
    await setActiveProfileId(storage, "profile-42");
    expect(await getActiveProfileId(storage)).toBe("profile-42");
  });
});
