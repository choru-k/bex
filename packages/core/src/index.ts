// LLM types and interfaces
export type {
  GrammarResult,
  LlmProvider,
  Preferences,
  HistoryEntry,
  Profile,
} from "./llm/types";

// LLM provider routing
export {
  SYSTEM_PROMPT,
  checkGrammar,
  buildSystemPrompt,
  PROFILE_GENERATION_PROMPT,
  generateText,
} from "./llm/provider";

// Model fetching
export type { ModelOption } from "./llm/models";
export { DEFAULT_MODELS, fetchModels } from "./llm/models";

// Diff utilities
export type { DiffType, DiffWord } from "./lib/diff";
export { computeWordDiff, diffToMarkdown } from "./lib/diff";

// JSON parsing
export { parseGrammarResponse } from "./lib/parse-json";

// Storage
export type { StorageAdapter } from "./storage/storage";

// Portable profiles
export {
  loadProfiles,
  saveProfiles,
  getActiveProfileId,
  setActiveProfileId,
  getDefaultProfile,
} from "./storage/profiles";

// Portable history
export {
  loadHistory,
  saveToHistory,
  deleteHistoryEntry,
  clearHistory,
} from "./storage/history";
