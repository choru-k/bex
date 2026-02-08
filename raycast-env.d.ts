/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** LLM Provider - Which AI to use for grammar checking */
  "provider": "openai" | "claude" | "gemini" | "ollama",
  /** OpenAI API Key - Your OpenAI API key */
  "openaiApiKey"?: string,
  /** Claude API Key - Your Anthropic API key */
  "claudeApiKey"?: string,
  /** Gemini API Key - Your Google Gemini API key */
  "geminiApiKey"?: string,
  /** Ollama URL - Local Ollama server URL */
  "ollamaUrl": string,
  /** Model Name - Model to use (leave empty for default) */
  "model"?: string
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `check-grammar` command */
  export type CheckGrammar = ExtensionPreferences & {}
  /** Preferences accessible in the `history` command */
  export type History = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `check-grammar` command */
  export type CheckGrammar = {}
  /** Arguments passed to the `history` command */
  export type History = {}
}

