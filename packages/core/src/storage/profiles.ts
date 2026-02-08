import { Profile } from "../llm/types";
import { StorageAdapter } from "./storage";

const PROFILES_KEY = "profiles";
const ACTIVE_PROFILE_KEY = "activeProfile";

export async function loadProfiles(storage: StorageAdapter): Promise<Profile[]> {
  const raw = await storage.getItem<string>(PROFILES_KEY);
  if (!raw) return [];
  try {
    return JSON.parse(raw);
  } catch {
    return [];
  }
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
