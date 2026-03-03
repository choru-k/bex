import { describe, it, expect } from "vitest";
import { parseGrammarResponse } from "./parse-json";

describe("parseGrammarResponse", () => {
  it("parses clean JSON directly", () => {
    const result = parseGrammarResponse(
      '{"corrected": "Hello world.", "explanation": "Capitalized."}',
    );
    expect(result).toEqual({
      corrected: "Hello world.",
      explanation: "Capitalized.",
    });
  });

  it("strips ```json fences", () => {
    const result = parseGrammarResponse(
      '```json\n{"corrected": "Hello.", "explanation": "Fixed."}\n```',
    );
    expect(result).toEqual({ corrected: "Hello.", explanation: "Fixed." });
  });

  it("strips bare ``` fences", () => {
    const result = parseGrammarResponse(
      '```\n{"corrected": "Hello.", "explanation": "Fixed."}\n```',
    );
    expect(result).toEqual({ corrected: "Hello.", explanation: "Fixed." });
  });

  it("extracts JSON from surrounding text (first { to last })", () => {
    const result = parseGrammarResponse(
      'Here is the result: {"corrected": "Hi.", "explanation": "Short."} done.',
    );
    expect(result).toEqual({ corrected: "Hi.", explanation: "Short." });
  });

  it("defaults explanation to 'No explanation provided.' when missing", () => {
    const result = parseGrammarResponse('{"corrected": "Hello."}');
    expect(result).toEqual({
      corrected: "Hello.",
      explanation: "No explanation provided.",
    });
  });

  it("throws on completely invalid input", () => {
    expect(() => parseGrammarResponse("this is not json at all")).toThrow(
      "Could not parse LLM response",
    );
  });

  it("throws when corrected field is missing", () => {
    expect(() =>
      parseGrammarResponse('{"explanation": "Something."}'),
    ).toThrow("Could not parse LLM response");
  });

  it("parses first JSON object when multiple objects are concatenated", () => {
    const result = parseGrammarResponse(
      '{"corrected":"First.","explanation":"One."}{"corrected":"Second.","explanation":"Two."}',
    );

    expect(result).toEqual({
      corrected: "First.",
      explanation: "One.",
    });
  });

  it("parses balanced object even when trailing text has braces", () => {
    const result = parseGrammarResponse(
      '{"corrected":"Hello.","explanation":"Done."} trailing {debug}',
    );

    expect(result).toEqual({
      corrected: "Hello.",
      explanation: "Done.",
    });
  });
});
