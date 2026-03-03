#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import {
  checkGrammar,
  DEFAULT_MODELS,
  saveToHistory,
  type GrammarResult,
  type HistoryEntry,
  type LlmProvider,
  type Preferences,
} from "@bex/core";
import { JsonFileStorage } from "@bex/core/node";

const PREFS_KEY = "preferences";

type HelpTopic = "global" | "check";

class CliError extends Error {
  exitCode: number;
  helpTopic?: HelpTopic;

  constructor(message: string, exitCode = 1, helpTopic?: HelpTopic) {
    super(message);
    this.exitCode = exitCode;
    this.helpTopic = helpTopic;
  }
}

interface CheckOptions {
  text?: string;
  file?: string;
  provider?: LlmProvider;
  model?: string;
  json: boolean;
  help: boolean;
}

interface CheckOutput {
  original: string;
  corrected: string;
  explanation: string;
  provider: LlmProvider;
  model: string;
  timestamp: string;
  savedToHistory: boolean;
}

function printGlobalHelp(): void {
  process.stdout.write(`Bex CLI

Usage:
  bex <command> [options]

Commands:
  check     Check and improve grammar for input text

Global options:
  -h, --help  Show help

Run \`bex check --help\` for command details.
`);
}

function printCheckHelp(): void {
  process.stdout.write(`Usage:
  bex check --text "<text>" [--provider <provider>] [--model <model>] [--json]
  bex check --file <path> [--provider <provider>] [--model <model>] [--json]

Options:
  --text <text>         Input text to check (required if --file is not used)
  --file <path>         Path to text file to check (required if --text is not used)
  --provider <name>     Override provider for this run
                        openai | openai-codex | claude | gemini | ollama
  --model <id>          Override model for this run
  --json                Output JSON
  -h, --help            Show this help

Notes:
  - Exactly one of --text or --file is required.
  - Preferences are loaded from ~/.bex/data.json.
  - Successful checks are saved to shared history.
`);
}

function isProvider(value: string): value is LlmProvider {
  return (
    value === "openai" ||
    value === "openai-codex" ||
    value === "claude" ||
    value === "gemini" ||
    value === "ollama"
  );
}

function parsePreferences(raw: unknown): Preferences | null {
  if (!raw) return null;

  if (typeof raw === "string") {
    try {
      const parsed = JSON.parse(raw);
      if (parsed && typeof parsed === "object") {
        const provider = (parsed as { provider?: unknown }).provider;
        return typeof provider === "string" && isProvider(provider)
          ? (parsed as Preferences)
          : null;
      }
      return null;
    } catch {
      return null;
    }
  }

  if (typeof raw === "object") {
    const provider = (raw as { provider?: unknown }).provider;
    return typeof provider === "string" && isProvider(provider)
      ? (raw as Preferences)
      : null;
  }

  return null;
}

function validatePreferences(prefs: Preferences): string | null {
  switch (prefs.provider) {
    case "openai":
      return prefs.openaiApiKey
        ? null
        : "OpenAI API key is missing. Configure it in the desktop app Settings.";
    case "openai-codex":
      return prefs.openaiCodexRefreshToken
        ? null
        : "OpenAI Codex is not connected. Connect ChatGPT in the desktop app Settings.";
    case "claude":
      return prefs.claudeApiKey
        ? null
        : "Claude API key is missing. Configure it in the desktop app Settings.";
    case "gemini":
      return prefs.geminiApiKey
        ? null
        : "Gemini API key is missing. Configure it in the desktop app Settings.";
    case "ollama":
      return null;
  }
}

function readOptionValue(argv: string[], index: number, option: string): [string, number] {
  const token = argv[index];
  const prefix = `${option}=`;

  if (token.startsWith(prefix)) {
    const value = token.slice(prefix.length);
    if (!value) {
      throw new CliError(`Missing value for ${option}.`, 2, "check");
    }
    return [value, index];
  }

  const next = argv[index + 1];
  if (!next || next.startsWith("-")) {
    throw new CliError(`Missing value for ${option}.`, 2, "check");
  }

  return [next, index + 1];
}

function parseCheckArgs(argv: string[]): CheckOptions {
  const options: CheckOptions = { json: false, help: false };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === "--help" || arg === "-h") {
      options.help = true;
      continue;
    }

    if (arg === "--json") {
      options.json = true;
      continue;
    }

    if (arg === "--text" || arg.startsWith("--text=")) {
      const [value, nextIndex] = readOptionValue(argv, i, "--text");
      options.text = value;
      i = nextIndex;
      continue;
    }

    if (arg === "--file" || arg.startsWith("--file=")) {
      const [value, nextIndex] = readOptionValue(argv, i, "--file");
      options.file = value;
      i = nextIndex;
      continue;
    }

    if (arg === "--provider" || arg.startsWith("--provider=")) {
      const [value, nextIndex] = readOptionValue(argv, i, "--provider");
      if (!isProvider(value)) {
        throw new CliError(
          `Invalid provider: ${value}. Expected one of openai, openai-codex, claude, gemini, ollama.`,
          2,
          "check",
        );
      }
      options.provider = value;
      i = nextIndex;
      continue;
    }

    if (arg === "--model" || arg.startsWith("--model=")) {
      const [value, nextIndex] = readOptionValue(argv, i, "--model");
      options.model = value;
      i = nextIndex;
      continue;
    }

    if (arg.startsWith("-")) {
      throw new CliError(`Unknown option: ${arg}`, 2, "check");
    }

    throw new CliError(`Unexpected argument: ${arg}`, 2, "check");
  }

  if (!options.help) {
    if (!!options.text === !!options.file) {
      throw new CliError(
        "Exactly one of --text or --file is required.",
        2,
        "check",
      );
    }
  }

  return options;
}

async function resolveInput(options: CheckOptions): Promise<string> {
  if (typeof options.text === "string") {
    const trimmed = options.text.trim();
    if (!trimmed) {
      throw new CliError("Input text is empty.", 2, "check");
    }
    return options.text;
  }

  if (!options.file) {
    throw new CliError("Missing input. Provide --text or --file.", 2, "check");
  }

  try {
    const content = await readFile(options.file, "utf-8");
    if (!content.trim()) {
      throw new CliError("Input file is empty.", 2, "check");
    }
    return content;
  } catch (err) {
    if (err instanceof CliError) throw err;
    const message = err instanceof Error ? err.message : "Unknown file read error";
    throw new CliError(`Failed to read file '${options.file}': ${message}`);
  }
}

async function persistCodexSessionIfUpdated(
  storage: JsonFileStorage,
  basePrefs: Preferences,
  workingPrefs: Preferences,
): Promise<void> {
  if (workingPrefs.provider !== "openai-codex") return;

  const changed =
    basePrefs.openaiCodexAccessToken !== workingPrefs.openaiCodexAccessToken ||
    basePrefs.openaiCodexRefreshToken !== workingPrefs.openaiCodexRefreshToken ||
    basePrefs.openaiCodexExpiresAt !== workingPrefs.openaiCodexExpiresAt ||
    basePrefs.openaiCodexAccountId !== workingPrefs.openaiCodexAccountId;

  if (!changed) return;

  const nextPrefs: Preferences = {
    ...basePrefs,
    openaiCodexAccessToken: workingPrefs.openaiCodexAccessToken,
    openaiCodexRefreshToken: workingPrefs.openaiCodexRefreshToken,
    openaiCodexExpiresAt: workingPrefs.openaiCodexExpiresAt,
    openaiCodexAccountId: workingPrefs.openaiCodexAccountId,
  };

  await storage.setItem(PREFS_KEY, JSON.stringify(nextPrefs));
}

function formatHumanOutput(output: CheckOutput): string {
  return `Corrected:\n${output.corrected}\n\nExplanation:\n${output.explanation}\n\nProvider: ${output.provider}\nModel: ${output.model}\nTimestamp: ${output.timestamp}\nSaved to history: ${output.savedToHistory ? "yes" : "no"}`;
}

async function runCheck(options: CheckOptions): Promise<void> {
  const input = await resolveInput(options);
  const storage = new JsonFileStorage();

  const rawPrefs = await storage.getItem<unknown>(PREFS_KEY);
  const basePrefs = parsePreferences(rawPrefs);

  if (!basePrefs) {
    throw new CliError(
      "Preferences are missing in ~/.bex/data.json. Configure provider settings in the desktop app first.",
    );
  }

  const provider = options.provider ?? basePrefs.provider;
  const model = options.model ?? basePrefs.model ?? DEFAULT_MODELS[provider];

  const workingPrefs: Preferences = {
    ...basePrefs,
    provider,
    model,
  };

  const prefError = validatePreferences(workingPrefs);
  if (prefError) {
    throw new CliError(prefError);
  }

  const result: GrammarResult = await checkGrammar(input, workingPrefs);

  const timestamp = new Date().toISOString();
  const historyEntry: HistoryEntry = {
    id: randomUUID(),
    original: input,
    corrected: result.corrected,
    explanation: result.explanation,
    provider,
    model,
    timestamp,
  };

  await saveToHistory(storage, historyEntry);

  try {
    await persistCodexSessionIfUpdated(storage, basePrefs, workingPrefs);
  } catch (err) {
    const message = err instanceof Error ? err.message : "Unknown error";
    process.stderr.write(`Warning: could not persist refreshed Codex session: ${message}\n`);
  }

  const output: CheckOutput = {
    original: input,
    corrected: result.corrected,
    explanation: result.explanation,
    provider,
    model,
    timestamp,
    savedToHistory: true,
  };

  if (options.json) {
    process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
    return;
  }

  process.stdout.write(`${formatHumanOutput(output)}\n`);
}

async function run(argv: string[]): Promise<void> {
  const normalized = argv[0] === "--" ? argv.slice(1) : argv;

  if (
    normalized.length === 0 ||
    normalized[0] === "--help" ||
    normalized[0] === "-h"
  ) {
    printGlobalHelp();
    return;
  }

  const [command, ...rest] = normalized;

  switch (command) {
    case "check": {
      const options = parseCheckArgs(rest);
      if (options.help) {
        printCheckHelp();
        return;
      }
      await runCheck(options);
      return;
    }
    default:
      throw new CliError(`Unknown command: ${command}`, 2, "global");
  }
}

void run(process.argv.slice(2)).catch((err) => {
  if (err instanceof CliError) {
    process.stderr.write(`Error: ${err.message}\n`);
    if (err.exitCode === 2) {
      process.stderr.write("\n");
      if (err.helpTopic === "check") {
        printCheckHelp();
      } else {
        printGlobalHelp();
      }
    }
    process.exit(err.exitCode);
  }

  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`Error: ${message}\n`);
  process.exit(1);
});
