import { GrammarResult } from "../llm/types";

export function parseGrammarResponse(raw: string): GrammarResult {
  const trimmed = raw.trim();

  // Try direct parse
  try {
    return validateResult(JSON.parse(trimmed));
  } catch {
    // continue
  }

  // Strip markdown code fences
  const stripped = trimmed
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();
  try {
    return validateResult(JSON.parse(stripped));
  } catch {
    // continue
  }

  // Find first { and last }
  const start = stripped.indexOf("{");
  const end = stripped.lastIndexOf("}");
  if (start !== -1 && end > start) {
    try {
      return validateResult(JSON.parse(stripped.slice(start, end + 1)));
    } catch {
      // continue
    }
  }

  throw new Error(`Could not parse LLM response as JSON: ${raw.slice(0, 200)}`);
}

function validateResult(obj: unknown): GrammarResult {
  if (
    typeof obj === "object" &&
    obj !== null &&
    "corrected" in obj &&
    typeof (obj as GrammarResult).corrected === "string"
  ) {
    return {
      corrected: (obj as GrammarResult).corrected,
      explanation:
        (obj as GrammarResult).explanation || "No explanation provided.",
    };
  }
  throw new Error("Response missing 'corrected' field");
}
