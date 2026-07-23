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

### Claude Code, Codex, and Oh My Pi integrations

Integrations are optional. The focused-app **⌘⇧P** flow works without them. To add review to a supported terminal client:

1. Open **Settings → Integrations**.
2. For Claude Code or Codex, choose **Install**. For Oh My Pi (OMP), enter the exact executable, profile, and working directory, then choose **Resolve and Review OMP Installation**.
3. Review every proposed path, mode, SHA-256 digest, configuration diff, signer, and host-specific limitation. Bex changes nothing until **Apply**.
4. For Codex, open `/hooks` and explicitly trust the Bex handler. Claude Code `/hooks` is inspection-only and needs no separate approval. OMP uses its reviewed native prompt gate and needs no marketplace extension.
5. Keep Bex running and submit a test prompt. Bex reports **Active** only after a matching post-install heartbeat.

By default, Bex asks you to confirm each hook prompt before sending it to the configured provider. To skip that per-prompt screen, turn off **Settings → Integrations → Confirm each hook payload before sending**. The first disclosure for each provider still requires approval, and ambiguous manual **Fix & Send** captures remain gated.

Bex resolves these exact host-owned targets:

- Claude Code: `${CLAUDE_CONFIG_DIR}/settings.json` when that variable is inherited by Bex, otherwise `~/.claude/settings.json`
- Codex: `${CODEX_HOME}/hooks.json` when that variable is inherited by Bex, otherwise `~/.codex/hooks.json`
- OMP: the absolute gate directory returned by `omp capabilities --json` for the selected profile and working directory

OMP must advertise `prompt-gate-v1`. OMP 17.0.6 and other builds without that capability remain unavailable; Bex does not install a best-effort `input` extension. Project-local `.omp` extensions cannot replace the native gate.

Bex preserves unrelated JSON and file permissions. New reviews install an immutable signed helper at `~/Library/Application Support/Bex/bin/<sha256>/bex-hook`; legacy shared-helper installations remain removable and migrate only through an explicit reviewed Update or Repair. **Uninstall** removes only Bex-owned artifacts. Drift produces **Update available** or **Needs repair**, never an automatic overwrite.

The integration blocks the first prompt before the client model receives it and opens Prompt Gate. After approval:

- OMP stages the corrected text, acknowledges the exact delivery token, and resubmits it once through the native gate. The matching one-use receipt allows only that exact corrected replay.
- For Claude Code or Codex, if Bex pastes the correction, focus the client composer and press Return. If Bex copies it, replace the retained original with the copied correction, then press Return.
- Never submit or manually replay the original after cancellation or an error. Remove any original retained by the host, resolve the reported problem, and retry through Prompt Gate.

Receipts bind the exact text, client, integration, and session. They are consumed once and expire after two minutes; cancellation and delivery failure revoke them.

Troubleshooting:

- **Installed — waiting for first prompt:** restart the client if it was already open, keep Bex running, and submit a test prompt.
- **Installed — approve Bex in `/hooks`:** open `/hooks` in Codex, trust the handler, then submit a test prompt.
- **OMP unavailable:** install an OMP build that advertises `prompt-gate-v1`, then resolve the target again.
- **Update available / Needs repair:** open a fresh review, verify the new baseline, and Apply.
- **Nothing changed:** the reviewed file or an ancestor changed identity. Choose **Review Latest Changes**; Bex will not apply a stale review.
- **Partial failure:** inspect the completed, restored, and retained paths shown in the review sheet before retrying.
- **Still inactive:** verify the exact target, profile, and working directory displayed by Bex.
- **Prompt blocked with a helper or IPC error:** keep Bex running, repair the integration if offered, and retry. Never bypass the block by submitting the original text.

Claude Code and Codex own their hook runtimes and can fail open if they terminate the helper or exceed its one-hour timeout, so those hooks are a review aid rather than a security boundary. OMP's `prompt-gate-v1` path blocks on malformed output, timeout, cancellation, helper failure, acknowledgment failure, or replay mismatch. Bex returns a valid blocking response for every recoverable helper, IPC, correction, cancellation, and delivery failure.

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
