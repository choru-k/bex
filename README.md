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

## Prompt Gate: Fix & Send

Prompt Gate corrects an English prompt, preserves protected technical text, shows the complete original-to-corrected diff, and delivers only the correction you explicitly approve.

### Focused app flow

1. Focus the draft in its destination app and press **⌘⇧P**.
2. If macOS asks, grant Bex Accessibility access. Review the target and provider disclosure, then continue.
3. Review every change. You can edit the correction; Bex recomputes the diff before approval.
4. Choose **Send Corrected** or **Paste Corrected**. Bex never sends the original draft.

Delivery depends on the captured target:

| Target | Capture | Approved delivery |
| --- | --- | --- |
| Standard, editable macOS text field or text area | Bex captures and later revalidates the exact field | Exact replacement; **Send after approval** may press Return only after Bex observes the exact corrected value |
| Browser, terminal, rich composer, or unsupported field | Type or paste the draft into Bex | Paste the correction; you press Return in the destination |
| Accessibility unavailable or target cannot be revalidated | Type or paste the draft into Bex | Copy the correction for manual replacement |

Bex masks technical-looking spans before correction—including fenced and inline code, URLs, paths, command flags, identifiers, and structured literals—and requires every protected token to return exactly once and in order. If that check fails, Prompt Gate refuses delivery.

### Claude Code and Codex hooks

Hooks are optional. The focused-app **⌘⇧P** flow works without them. To add fail-closed review to a supported terminal client:

1. Open **Settings → Prompt Gate** and choose **Install** for Claude Code or Codex.
2. Check the exact configuration path shown by Bex:
   - Claude Code: `${CLAUDE_CONFIG_DIR}/settings.json` when `CLAUDE_CONFIG_DIR` is inherited by Bex, otherwise `~/.claude/settings.json`
   - Codex: `${CODEX_HOME}/hooks.json` when `CODEX_HOME` is inherited by Bex, otherwise `~/.codex/hooks.json`
3. For Codex, open `/hooks` and explicitly trust the Bex handler.
4. Keep Bex running and submit a test prompt. Bex reports **Active** only after the installed helper records a heartbeat.

Bex preserves unrelated JSON and file permissions and installs a stable helper at `~/Library/Application Support/Bex/bin/bex-hook`. **Uninstall** removes only the Bex-owned hook entry. If the entry or helper has drifted, Settings reports **Needs repair** and offers **Repair**.

The hook blocks the first prompt before the client model receives it and opens Prompt Gate. After approval:

- If Bex pastes the correction, focus the client composer and press Return.
- If Bex copies the correction, replace the original composer text with the copied correction, then press Return.
- Do not submit or manually replay the original prompt after cancellation or an error. Remove any original text retained by the host, resolve the reported problem, and retry through Prompt Gate.

The corrected replay is authorized by a one-use receipt for the exact text, client, and session. The receipt expires after two minutes; cancellation and delivery failure revoke it.

Troubleshooting:

- **Installed — waiting for first prompt:** restart the client if it was already open, keep Bex running, and submit a test prompt.
- **Installed — approve Bex in `/hooks`:** open `/hooks` in Codex, trust the handler, then submit a test prompt.
- **Needs repair:** choose **Repair**, then restart the client.
- **Still inactive:** verify the exact configuration path displayed by Bex. Bex uses only `CLAUDE_CONFIG_DIR` or `CODEX_HOME` inherited by its own process; otherwise it uses the default paths above.
- **Prompt blocked with a helper or IPC error:** keep Bex running, repair the integration if offered, and retry. Do not bypass the block by submitting the original text.

Claude Code and Codex own their hook runtimes. They can fail open if they terminate the helper or exceed its one-hour timeout, so hooks are a review aid rather than a security enforcement boundary. Bex itself returns a valid blocking response for recoverable helper, IPC, correction, cancellation, and delivery failures.

## Providers

| Provider | Authentication | Default model |
| --- | --- | --- |
| OpenAI | API key | `gpt-5.6-sol` |
| OpenAI Codex | ChatGPT OAuth | `gpt-5.6-sol` |
| Claude | API key | `claude-opus-4-8` |
| Gemini | API key | `gemini-3.5-flash` |
| Ollama | Local service | `llama3.3` |

Available model lists are fetched on demand from every provider. After a successful refresh, Bex uses only models reported by that account or Ollama installation; if a saved model is no longer available, Bex selects the current default when possible, then the first available model.

Small local models may be unable to reproduce protected tokens exactly. Prompt Gate then refuses delivery; select a more capable Ollama model and retry.

Reasoning-capable providers use the Settings effort control. Medium is the default: OpenAI and OpenAI Codex send medium reasoning effort, current Claude models use adaptive thinking with medium effort, Gemini 3 uses medium thinking without sampling overrides, supported legacy Claude and Gemini models use token budgets, and Ollama enables `think` for supported local thinking models unless effort is Low.

## Data and credentials

API keys and the OpenAI Codex session are stored in macOS Keychain. Profiles and correction history stay on the Mac at:

```text
~/Library/Application Support/Bex/data.json
```

Bex keeps at most 500 Quick Check history entries and writes its data atomically. Prompt Gate reviews are not added to that history. Cloud correction sends the prompt prose—with protected technical spans replaced by placeholders—directly to the selected provider; Ollama processes the request at the configured local URL.

Prompt Gate receipts at `~/Library/Application Support/Bex/PromptGate/receipts` contain a SHA-256 digest and routing metadata, not prompt text. They are mode `0600`, are consumed once, and expire after two minutes. The local IPC rendezvous and integration heartbeat files live under `~/Library/Application Support/Bex/PromptGate`.

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
