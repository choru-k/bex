import { GrammarResult, Preferences } from "./types";
import { checkWithOpenAI, generateWithOpenAI } from "./openai";
import { checkWithClaude, generateWithClaude } from "./claude";
import { checkWithGemini, generateWithGemini } from "./gemini";
import { checkWithOllama, generateWithOllama } from "./ollama";

export const SYSTEM_PROMPT = `You are a grammar and expression checker for English text.
Given the user's input text, correct any grammar mistakes, improve awkward phrasing, and make the expression more natural while preserving the original meaning and tone.

Respond ONLY with a JSON object in this exact format (no markdown, no code fences):
{"corrected": "<corrected text>", "explanation": "<brief note on what was changed>"}

If the text is already correct, return it unchanged with explanation "No changes needed."`;

export async function checkGrammar(
  text: string,
  prefs: Preferences,
  signal?: AbortSignal,
  systemPrompt?: string,
): Promise<GrammarResult> {
  const prompt = systemPrompt || SYSTEM_PROMPT;
  switch (prefs.provider) {
    case "openai":
      return checkWithOpenAI(text, prefs, prompt, signal);
    case "claude":
      return checkWithClaude(text, prefs, prompt, signal);
    case "gemini":
      return checkWithGemini(text, prefs, prompt, signal);
    case "ollama":
      return checkWithOllama(text, prefs, prompt, signal);
    default:
      throw new Error(`Unknown provider: ${prefs.provider}`);
  }
}

export function buildSystemPrompt(profilePrompt?: string): string {
  if (!profilePrompt) return SYSTEM_PROMPT;
  return `${SYSTEM_PROMPT}\n\nAdditional context from the user:\n${profilePrompt}`;
}

export const PROFILE_GENERATION_PROMPT = `You are helping a user create a profile for a grammar checker. Based on the user's writing context, generate a concise prompt (2-4 sentences) that will guide the grammar checker to correct text appropriately.

Write the prompt as instructions (e.g., "Keep the tone professional..."). Be specific but not restrictive. Respond with ONLY the prompt text, nothing else.`;

export async function generateText(
  systemPrompt: string,
  userMessage: string,
  prefs: Preferences,
  signal?: AbortSignal,
): Promise<string> {
  switch (prefs.provider) {
    case "openai":
      return generateWithOpenAI(userMessage, prefs, systemPrompt, signal);
    case "claude":
      return generateWithClaude(userMessage, prefs, systemPrompt, signal);
    case "gemini":
      return generateWithGemini(userMessage, prefs, systemPrompt, signal);
    case "ollama":
      return generateWithOllama(userMessage, prefs, systemPrompt, signal);
    default:
      throw new Error(`Unknown provider: ${prefs.provider}`);
  }
}
