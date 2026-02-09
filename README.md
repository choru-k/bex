# Bex — Better Expression

AI-powered grammar and expression checker. Available as a Raycast extension and a desktop companion app, both sharing the same core engine and data.

## Install

### Homebrew (macOS)

```bash
brew install --cask choru-k/tap/bex
```

### Direct Download

Download the latest `.zip` from [GitHub Releases](https://github.com/choru-k/bex/releases).

## Packages

| Package | Description |
|---------|-------------|
| `@bex/core` | Shared LLM providers, storage, diff utilities, profiles |
| `@bex/raycast` | Raycast extension |
| `@bex/app` | Tauri v2 desktop companion app |

## Features

- **Grammar & expression checking** — paste text, get corrected output with explanations
- **Multi-provider support** — OpenAI, Claude, Gemini, Ollama (local)
- **Dynamic model selection** — fetches available models from your provider's API
- **Diff view** — word-level highlighting of changes
- **Writing profiles** — custom prompts for different contexts (emails, code reviews, etc.)
- **AI profile wizard** — generate profile prompts from role/audience/tone inputs
- **History** — review past corrections, shared across Raycast and desktop app
- **Cross-app data** — both apps read/write `~/.bex/data.json`

## Providers

| Provider | API Key Required | Default Model |
|----------|-----------------|---------------|
| OpenAI | Yes | gpt-4.1-mini |
| Claude | Yes | claude-sonnet-4-5-20250929 |
| Gemini | Yes | gemini-2.5-flash |
| Ollama | No (local) | llama3.2 |

## Getting Started

### Prerequisites

- Node.js 20+
- pnpm 10+
- Rust toolchain (for desktop app)

### Install

```sh
pnpm install
```

### Development

```sh
# Build all packages
pnpm build

# Desktop app
pnpm dev:app

# Raycast extension
pnpm dev:raycast

# Core library (watch mode)
pnpm dev:core
```

### Desktop App

The companion app is built with Tauri v2 + React + Tailwind CSS. It provides:

- **Check Grammar** — split-pane editor with diff output
- **History** — expandable list of past corrections with diffs
- **Profiles** — create, edit, delete writing profiles with AI wizard
- **Settings** — configure provider, API keys, and default model

```sh
# Dev mode (opens app window with hot reload)
pnpm dev:app

# Production build (generates .app and .dmg)
pnpm build:app
```

### Raycast Extension

```sh
pnpm dev:raycast
```

Open Raycast, configure the extension preferences (provider + API key), then use the **Check Grammar** command.

## Project Structure

```
packages/
  core/       — @bex/core: LLM providers, storage adapter, diff, profiles
  raycast/    — @bex/raycast: Raycast extension consuming @bex/core
  app/        — @bex/app: Tauri v2 desktop app consuming @bex/core
```

## License

MIT
