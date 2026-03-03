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

  // Extract first balanced JSON object (helps when model emits duplicated JSON)
  const balanced = extractFirstBalancedJsonObject(stripped);
  if (balanced) {
    try {
      return validateResult(JSON.parse(balanced));
    } catch {
      // continue
    }
  }

  throw new Error(`Could not parse LLM response as JSON: ${raw.slice(0, 200)}`);
}

function extractFirstBalancedJsonObject(input: string): string | null {
  const start = input.indexOf("{");
  if (start === -1) return null;

  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let i = start; i < input.length; i += 1) {
    const ch = input[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (ch === "\\") {
        escaped = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === "{") {
      depth += 1;
      continue;
    }

    if (ch === "}") {
      depth -= 1;
      if (depth === 0) {
        return input.slice(start, i + 1);
      }
    }
  }

  return null;
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
