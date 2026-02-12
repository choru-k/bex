# Bex - Grammar Checker

## Purpose
Bex is a grammar checking tool that uses various LLM providers (OpenAI, Claude, Gemini, Ollama) to correct text. It's a monorepo with shared core logic.

## Tech Stack
- **Monorepo**: pnpm workspaces
- **Language**: TypeScript (ES2022, strict mode)
- **Packages**:
  - `@bex/core` — shared LLM, storage, diff, profile logic
  - `@bex/raycast` — Raycast extension
  - `@bex/app` (planned) — Tauri v2 desktop app

## Code Style
- ESM (`"type": "module"`)
- Functional style (no classes except `JsonFileStorage`)
- Explicit types, interfaces in separate files
- No semicolons preferred in some places, but generally present
- camelCase for functions/variables, PascalCase for types/interfaces

## Core API Surface
- `StorageAdapter` interface: `getItem<T>`, `setItem`, `removeItem`, `getAllKeys`
- `checkGrammar(text, prefs, signal?, systemPrompt?)` → `GrammarResult`
- `generateText(systemPrompt, userMessage, prefs, signal?)` → string
- `fetchModels(provider, prefs)` → `ModelOption[]`
- `computeWordDiff(original, corrected)` → `DiffWord[]`
- History: `loadHistory`, `saveToHistory`, `deleteHistoryEntry`, `clearHistory`
- Profiles: `loadProfiles`, `saveProfiles`, `getActiveProfileId`, `setActiveProfileId`, `getDefaultProfile`

## Storage
- All data in `~/.bex/data.json`
- `JsonFileStorage` uses `node:fs/promises` (Node.js only)
- Keys: `history`, `profiles`, `activeProfile`, `preferences`
