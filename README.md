# Bex — Better Expression

Bex is a native macOS menubar app for checking English grammar and expression with the AI provider you choose. It opens only when needed, has no Dock icon, and uses native AppKit and SwiftUI controls throughout.

- [Requirements](#requirements)
- [Install](#install)
- [Use Bex](#use-bex)
- [Providers](#providers)
- [Prompt Gate](#prompt-gate)
- [Prompt Gate integrations](#prompt-gate-integrations)
- [Data and credentials](#data-and-credentials)
- [Uninstall](#uninstall)
- [Build and test](#build-and-test)
- [Project structure](#project-structure)
- [License](#license)

## Requirements

- macOS 13 Ventura or later
- Access to at least one provider:
  - OpenAI — API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys)
  - OpenAI Codex — a ChatGPT account (OAuth, no key)
  - Claude — API key from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys)
  - Gemini — API key from [aistudio.google.com/apikey](https://aistudio.google.com/apikey)
  - Ollama — a local install with a model pulled, e.g. `ollama pull llama3.3`

## Install

### Homebrew

```sh
brew install --cask choru-k/tap/bex
```

### Direct download

Download `Bex.zip` from [GitHub Releases](https://github.com/choru-k/bex/releases), extract it, and move `Bex.app` to `/Applications`.

If macOS blocks the first launch, right-click `Bex.app` → **Open**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Bex.app
```

Launch Bex from Applications or with:

```sh
open -a Bex
```

Bex runs as a small icon in the macOS menu bar rather than in the Dock.

## Use Bex

1. Open **Settings** from the Bex menu and select a provider and model.
2. Add the provider credential, connect OpenAI Codex, or configure the local Ollama URL.
3. Press `⌘⇧G` from any app to open Quick Check.
4. Enter text, run **Check**, review the word-level diff and explanation, then copy the result.

Quick Check also supports three in-place rewrites:

- **More Formal** (`⌘1`)
- **Friendlier** (`⌘2`)
- **Shorter** (`⌘3`)

The Bex menu opens the management windows only when needed:

- **History** — search and filter prior checks, inspect their diffs, reuse an input, or delete entries
- **Profiles** — a profile is a saved writing-context prompt (tone, audience, house style) that Quick Check applies automatically while active; you can maintain profiles by hand or generate one with an AI wizard
- **Settings** — choose providers, models, and reasoning effort (see [Providers](#providers)), manage credentials, validate Ollama, and select system, light, or dark appearance

### Troubleshooting

- **No icon in the menu bar:** the bar may be full. Check the overflow area (`⌘`-drag icons) or a menu-bar manager like Bartender/Ice.
- **`⌘⇧G` does nothing:** macOS or another app may have claimed the shortcut. Choose a different one under **Settings → General → Shortcuts**.
- **Credential rejected or empty model list:** re-check the key in **Settings**, and for Ollama confirm the local URL is reachable and a model is pulled.

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

Reasoning-capable providers use the Settings **effort** control (reasoning depth). Medium is the default: OpenAI and OpenAI Codex send medium reasoning effort, current Claude models use adaptive thinking with medium effort, Gemini 3 uses medium thinking without sampling overrides, supported legacy Claude and Gemini models use token budgets, and Ollama enables `think` for supported local thinking models unless effort is Low.

## Prompt Gate

Prompt Gate corrects an English prompt while leaving protected technical text untouched. It shows you the full before/after diff and delivers only the correction you explicitly approve.

### Focused app flow

1. Focus the original text in its destination app and press `⌘⇧P`.
2. If macOS asks, grant Bex Accessibility access. Review the target and provider disclosure, then continue.
3. Review every change. You can edit the correction; Bex recomputes the diff before approval.
4. Choose **Send Corrected**, **Paste Corrected**, or **Copy** (see the table below). Bex never sends the original.

Delivery depends on the captured target:

| Target | How you provide the text | Delivery after approval |
| --- | --- | --- |
| Standard, editable macOS text field or text area | Bex captures and later revalidates the exact field | **Send Corrected** replaces the field with the correction. With **Send after approval** enabled, Bex presses Return only after confirming the field still holds the exact correction. |
| Browser, terminal, rich composer, or unsupported field | Type or paste the original into Bex | **Paste Corrected** pastes the correction; you press Return in the destination. |
| Accessibility unavailable or target cannot be revalidated | Type or paste the original into Bex | **Copy** places the correction on the clipboard for manual replacement. |

Before correction, Bex masks technical-looking spans: fenced and inline code, templates (`${…}`, `{{…}}`), tags (`<…>`), URLs, paths, command flags, variables (`$VAR`), and mentions (`@name`). Every masked token must reappear exactly once, in order, in the correction; if any is missing, duplicated, or reordered, Prompt Gate refuses delivery.

## Prompt Gate integrations

Integrations are optional and only relevant if you use one of these terminal AI clients (Oh My Pi, abbreviated OMP, is one such client). The focused-app `⌘⇧P` flow works without any of them.

> **Security note:** Claude Code and Codex own their hook runtimes and can fail open if they terminate the helper or exceed its ~one-hour timeout, so those two integrations are a review aid rather than a security boundary. OMP's `prompt-gate-v1` path fails closed.

To add review to a supported terminal client:

1. Open **Settings → Integrations**.
2. For Claude Code or Codex, choose **Install**. For OMP, enter the exact executable, profile, and working directory, then choose **Resolve and Review OMP Installation**.
3. Review every proposed change — path, mode, SHA-256 digest, configuration diff, signer, and host-specific limitation. Bex changes nothing until you choose **Apply**.
4. Complete any client-specific approval (see the table below).
5. Keep Bex running and submit a test prompt. Bex reports **Active** only after a matching post-install heartbeat.

The three clients differ only in setup and delivery:

| Client | Approval after Apply | Delivery after approval | On helper failure |
| --- | --- | --- | --- |
| Claude Code | None — `/hooks` is inspection-only | Bex pastes → focus the composer and press Return; or Bex copies → replace the retained original with the correction, then press Return | May fail open |
| Codex | Open `/hooks` and trust the Bex handler | Same as Claude Code | May fail open |
| OMP | None — uses the reviewed native prompt gate, no marketplace extension | Bex resubmits the correction once through the native gate | Fails closed |

By default, Bex asks you to confirm each hook prompt before sending it to the configured provider. To skip that per-prompt screen, turn off **Settings → Integrations → Confirm each hook payload before sending**. The first disclosure for each provider still requires approval, and ambiguous manual focused-app captures remain gated.

Bex resolves these exact host-owned targets:

- Claude Code: `${CLAUDE_CONFIG_DIR}/settings.json` when that variable is inherited by Bex, otherwise `~/.claude/settings.json`
- Codex: `${CODEX_HOME}/hooks.json` when that variable is inherited by Bex, otherwise `~/.codex/hooks.json`
- OMP: the absolute gate directory returned by `omp capabilities --json` for the selected profile and working directory

OMP must advertise the `prompt-gate-v1` capability. Builds without it — including OMP 17.0.6 — remain unavailable: Bex will not fall back to an unreviewed OMP `input` extension, and a project's own `.omp` extension cannot substitute for the native gate.

Bex preserves unrelated JSON and file permissions. **Uninstall** removes only Bex-owned artifacts. Drift produces **Update available** or **Needs repair**, never an automatic overwrite; the signed helper is replaced only through an explicit reviewed Update or Repair.

The integration blocks the first prompt before the client model receives it and opens Prompt Gate. After approval:

- OMP stages the corrected text, acknowledges the exact delivery token, and resubmits it once through the native gate. The matching single-use receipt allows only that exact corrected replay.
- For Claude Code or Codex, deliver as shown in the table above.
- Never submit or manually replay the original after cancellation or an error. Remove any original retained by the host, resolve the reported problem, and retry through Prompt Gate.

If a prompt is blocked with a helper or IPC error, keep Bex running, repair the integration if offered, and retry. OMP's `prompt-gate-v1` path blocks on malformed output, timeout, cancellation, helper failure, acknowledgment failure, or replay mismatch, and Bex returns a valid blocking response for every recoverable helper, IPC, correction, cancellation, and delivery failure. **Never bypass a block by submitting the original text.**

### Integration troubleshooting

- **Installed — waiting for first prompt:** restart the client if it was already open, keep Bex running, and submit a test prompt.
- **Installed — approve Bex in `/hooks`:** open `/hooks` in Codex, trust the handler, then submit a test prompt.
- **OMP unavailable:** install an OMP build that advertises `prompt-gate-v1`, then resolve the target again.
- **Update available / Needs repair:** open a fresh review, verify the new baseline, and Apply.
- **Nothing changed:** the reviewed file or an ancestor changed identity. Choose **Review Latest Changes**; Bex will not apply a stale review.
- **Partial failure:** inspect the completed, restored, and retained paths shown in the review sheet before retrying.
- **Still inactive:** verify the exact target, profile, and working directory displayed by Bex.

## Data and credentials

API keys and the OpenAI Codex session are stored in macOS Keychain. Profiles and correction history stay on the Mac at:

```text
~/Library/Application Support/Bex/data.json
```

Bex keeps at most 500 Quick Check history entries and writes its data atomically. Prompt Gate reviews are not added to that history. For Prompt Gate, cloud correction sends the prompt prose—with recognized technical spans replaced by placeholders—directly to the selected provider; Quick Check sends the text as entered. Ollama processes requests at the configured local URL.

Masking is best-effort and covers only recognized spans. Unrecognized sensitive text in ordinary prose—secrets, personal data, or tokens that match no known pattern—is sent to the provider as written. When Bex delivers a correction by copying it, the corrected text stays on the system clipboard, where other apps and Universal Clipboard can read it until it is replaced.

Prompt Gate receipts at `~/Library/Application Support/Bex/PromptGate/receipts` bind the exact text, client, integration, and session, and contain a SHA-256 digest and routing metadata, not prompt text. They are mode `0600`, are consumed once, and expire after two minutes; cancellation and delivery failure revoke them. The local IPC (inter-process communication) rendezvous and integration heartbeat files live under `~/Library/Application Support/Bex/PromptGate`.

Prompt Gate corrections you approve are also appended to a local learning log at `~/Library/Application Support/Bex/LearningLog/learning-log.jsonl` (directory `0700`, file `0600`). Unlike receipts, this log stores the full prompt prose you wrote—the original text, the correction, and the explanation—in cleartext, including technical spans that are masked before being sent to a provider. It is append-only, owner-only, and never leaves the Mac. It is not part of Quick Check history. Deleting `~/Library/Application Support/Bex` removes it (see [Uninstall](#uninstall)).

Prompt Gate installs its immutable signed helper at `~/Library/Application Support/Bex/bin/<sha256>/bex-hook`. Legacy shared-helper installations remain removable and migrate only through an explicit reviewed Update or Repair.

## Uninstall

Remove any installed integrations first from **Settings → Integrations → Uninstall** (this removes only Bex-owned hook artifacts), then remove the app:

```sh
brew uninstall --cask bex   # if installed via Homebrew
```

Or drag `Bex.app` from `/Applications` to the Trash. To also erase local data, delete `~/Library/Application Support/Bex` and remove the Bex entries from Keychain Access.

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

CI runs only the unit suite (`-only-testing:BexTests`); the command above also runs the UI tests locally.

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
Bex/           Native application source and resources
BexHook/       Signed helper binary for the Claude Code/Codex/OMP hooks
BexHookShared/ Prompt Gate receipt store and IPC shared by app and helper
BexTests/      Provider, parser, diff, storage, and view-model tests
BexUITests/    End-to-end native UI tests
Config/        Application and distribution property lists
Bex.xcodeproj  Shared Xcode project and scheme
```

## License

MIT — see [LICENSE](LICENSE).
