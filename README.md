# Bex — Better Expression

A Raycast extension for checking and improving English grammar with AI. Supports multiple LLM providers with dynamic model selection.

## Features

- **Grammar & expression checking** — paste text, get corrected output with explanations
- **Multi-provider support** — OpenAI, Claude, Gemini, Ollama (local)
- **Dynamic model selection** — fetches available models from your provider's API
- **Diff view** — see exactly what changed with word-level highlighting
- **Paste to app** — one action to paste the corrected text back
- **History** — review past corrections for study, delete individually or clear all

## Setup

1. Install via Raycast (or clone and run `npm install && npm run dev`)
2. Open extension preferences and set your **LLM Provider** + API key
3. Run **Check Grammar** — select a model and enter text

## Providers

| Provider | API Key Required | Default Model |
|----------|-----------------|---------------|
| OpenAI | Yes | gpt-4.1-mini |
| Claude | Yes | claude-sonnet-4-5-20250929 |
| Gemini | Yes | gemini-2.5-flash |
| Ollama | No (local) | llama3.2 |

## Commands

- **Check Grammar** — main command, check and fix English text
- **Grammar History** — browse past corrections

## License

MIT
