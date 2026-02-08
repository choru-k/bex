import { LocalStorage } from "@raycast/api";
import { Profile } from "../llm/types";

const PROFILES_KEY = "profiles";
const ACTIVE_PROFILE_KEY = "activeProfile";

export async function loadProfiles(): Promise<Profile[]> {
  const raw = await LocalStorage.getItem<string>(PROFILES_KEY);
  if (!raw) return [];
  try {
    return JSON.parse(raw);
  } catch {
    return [];
  }
}

export async function saveProfiles(profiles: Profile[]): Promise<void> {
  await LocalStorage.setItem(PROFILES_KEY, JSON.stringify(profiles));
}

export async function getActiveProfileId(): Promise<string | undefined> {
  return await LocalStorage.getItem<string>(ACTIVE_PROFILE_KEY);
}

export async function setActiveProfileId(id: string): Promise<void> {
  await LocalStorage.setItem(ACTIVE_PROFILE_KEY, id);
}

export function getDefaultProfile(profiles: Profile[]): Profile | undefined {
  return profiles.find((p) => p.isDefault);
}
