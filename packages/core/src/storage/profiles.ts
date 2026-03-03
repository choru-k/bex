import { Profile } from "../llm/types";
import { StorageAdapter } from "./storage";

const PROFILES_KEY = "profiles";
const ACTIVE_PROFILE_KEY = "activeProfile";

export async function loadProfiles(storage: StorageAdapter): Promise<Profile[]> {
  const raw = await storage.getItem<unknown>(PROFILES_KEY);
  if (!raw) return [];

  if (Array.isArray(raw)) {
    return raw as Profile[];
  }

  if (typeof raw === "string") {
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? (parsed as Profile[]) : [];
    } catch {
      return [];
    }
  }

  return [];
}

export async function saveProfiles(storage: StorageAdapter, profiles: Profile[]): Promise<void> {
  await storage.setItem(PROFILES_KEY, JSON.stringify(profiles));
}

export async function getActiveProfileId(storage: StorageAdapter): Promise<string | undefined> {
  return await storage.getItem<string>(ACTIVE_PROFILE_KEY);
}

export async function setActiveProfileId(storage: StorageAdapter, id: string): Promise<void> {
  await storage.setItem(ACTIVE_PROFILE_KEY, id);
}

export function getDefaultProfile(profiles: Profile[]): Profile | undefined {
  return profiles.find((p) => p.isDefault);
}
