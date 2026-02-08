import { GrammarResult, Preferences } from "./types";
import { checkWithOpenAI } from "./openai";
import { checkWithClaude } from "./claude";
import { checkWithGemini } from "./gemini";
import { checkWithOllama } from "./ollama";

export const SYSTEM_PROMPT = `You are a grammar and expression checker for English text.
Given the user's input text, correct any grammar mistakes, improve awkward phrasing, and make the expression more natural while preserving the original meaning and tone.

Respond ONLY with a JSON object in this exact format (no markdown, no code fences):
{"corrected": "<corrected text>", "explanation": "<brief note on what was changed>"}

If the text is already correct, return it unchanged with explanation "No changes needed."`;

export async function checkGrammar(
  text: string,
  prefs: Preferences,
  signal?: AbortSignal,
): Promise<GrammarResult> {
  switch (prefs.provider) {
    case "openai":
      return checkWithOpenAI(text, prefs, signal);
    case "claude":
      return checkWithClaude(text, prefs, signal);
    case "gemini":
      return checkWithGemini(text, prefs, signal);
    case "ollama":
      return checkWithOllama(text, prefs, signal);
    default:
      throw new Error(`Unknown provider: ${prefs.provider}`);
  }
}
