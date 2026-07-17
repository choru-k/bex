# Bex — Better Expression

Bex is a native macOS menubar app for checking English grammar and expression with the AI provider you choose. It opens only when needed, has no Dock icon, and uses native AppKit and SwiftUI controls throughout.

## Requirements

- macOS 13 Ventura or later
- A credential for OpenAI, Claude, or Gemini; a ChatGPT account for OpenAI Codex; or a local Ollama installation

## Install

### Homebrew

```sh
brew install --cask choru-k/tap/bex
```

### Direct download

Download `Bex.zip` from [GitHub Releases](https://github.com/choru-k/bex/releases), extract it, and move `Bex.app` to `/Applications`.

Launch Bex from Applications or with:

```sh
open -a Bex
```

Bex appears in the macOS menu bar rather than the Dock.

## Use Bex

1. Open **Settings** from the Bex menu and select a provider and model.
2. Add the provider credential, connect OpenAI Codex, or configure the local Ollama URL.
3. Press **⌘⇧G** from any app to open Quick Check.
4. Enter text, run **Check**, review the word-level diff and explanation, then copy the result.

Quick Check also supports three in-place rewrites:

- **More Formal** (`⌘1`)
- **More Friendly** (`⌘2`)
- **Shorter** (`⌘3`)

The Bex menu opens the management windows only when needed:

- **History** — search and filter prior checks, inspect their diffs, reuse an input, or delete entries
- **Profiles** — maintain writing-context prompts and generate a profile with the AI wizard
- **Settings** — choose providers, models, and effort, manage credentials, validate Ollama, and select system, light, or dark appearance

## Providers

| Provider | Authentication | Default model |
| --- | --- | --- |
| OpenAI | API key | `gpt-5.6-sol` |
| OpenAI Codex | ChatGPT OAuth | `gpt-5.6-sol` |
| Claude | API key | `claude-opus-4-8` |
| Gemini | API key | `gemini-3.5-flash` |
| Ollama | Local service | `llama3.3` |

Available model lists are fetched on demand from every provider. After a successful refresh, Bex uses only models reported by that account or Ollama installation; if a saved model is no longer available, Bex selects the current default when possible, then the first available model.
Reasoning-capable providers use the Settings effort control. Medium is the default: OpenAI and OpenAI Codex send medium reasoning effort, current Claude models use adaptive thinking with medium effort, Gemini 3 uses medium thinking without sampling overrides, supported legacy Claude and Gemini models use token budgets, and Ollama enables `think` for supported local thinking models unless effort is Low.

## Data and credentials

API keys and the OpenAI Codex session are stored in macOS Keychain. Profiles and correction history stay on the Mac at:

```text
~/Library/Application Support/Bex/data.json
```

Bex keeps at most 500 history entries and writes its data atomically. Provider requests go directly from the app to the selected provider; Ollama uses the configured local URL.

## Build and test

Open `Bex.xcodeproj` in Xcode 26 or build from the repository root.

Run the deterministic unit and UI test suites:

```sh
xcodebuild \
  -project Bex.xcodeproj \
  -scheme Bex \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData.noindex \
  test
```

Build an unsigned Release app:

```sh
xcodebuild \
  -project Bex.xcodeproj \
  -scheme Bex \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData.noindex \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The resulting app is at `build/DerivedData.noindex/Build/Products/Release/Bex.app`. The `.noindex` suffix prevents Spotlight from listing Debug, Release, and UI-test build bundles as installed applications.

## Project structure

```text
Bex/          Native application source and resources
BexTests/     Provider, parser, diff, storage, and view-model tests
BexUITests/   End-to-end native UI tests
Config/       Application and distribution property lists
Bex.xcodeproj Shared Xcode project and scheme
```

## License

MIT
