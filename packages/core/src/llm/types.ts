export interface GrammarResult {
  corrected: string;
  explanation: string;
}

export type LlmProvider =
  | "openai"
  | "openai-codex"
  | "claude"
  | "gemini"
  | "ollama";

export interface Preferences {
  provider: LlmProvider;
  openaiApiKey?: string;
  openaiCodexAccessToken?: string;
  openaiCodexRefreshToken?: string;
  openaiCodexExpiresAt?: number;
  openaiCodexAccountId?: string;
  claudeApiKey?: string;
  geminiApiKey?: string;
  ollamaUrl?: string;
  model?: string;
  appTheme?: "hig-glass" | "hig-solid";
  appColorMode?: "light" | "black" | "system";
}

export interface HistoryEntry {
  id: string;
  original: string;
  corrected: string;
  explanation: string;
  provider: string;
  model: string;
  timestamp: string;
  profileName?: string;
}

export interface Profile {
  id: string;
  name: string;
  prompt: string;
  isDefault?: boolean;
}
