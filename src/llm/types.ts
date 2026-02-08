export interface GrammarResult {
  corrected: string;
  explanation: string;
}

export type LlmProvider = "openai" | "claude" | "gemini" | "ollama";

export interface Preferences {
  provider: LlmProvider;
  openaiApiKey?: string;
  claudeApiKey?: string;
  geminiApiKey?: string;
  ollamaUrl?: string;
  model?: string;
}

export interface HistoryEntry {
  id: string;
  original: string;
  corrected: string;
  explanation: string;
  provider: string;
  model: string;
  timestamp: string;
}
