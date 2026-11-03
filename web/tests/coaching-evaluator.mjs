import { parseResult, presentNotes } from '../src/core/model.ts';

const occurrences = (text, span) => text.split(span).length - 1;
/** Pure, offline checks against a finite curated oracle. Never calls a provider. */
export function evaluateCoachingCase(spec, raw, policy) {
  let result;
  try { result = parseResult(raw, spec.text); }
  catch { return { passed: false, failures: ['invalid-result'], notes: [] }; }
  const failures = [];
  if (!spec.acceptedCorrections.includes(result.corrected)) failures.push('outside-reviewed-corrections');
  if (spec.unchanged && result.corrected !== spec.text) failures.push('overcorrection');
  if (spec.unchanged && result.notes.some(note => note.kind === 'correction')) failures.push('false-error-label');
  for (const span of spec.protectedSpans) {
    if (!span || occurrences(spec.text, span) !== occurrences(result.corrected, span)) {
      failures.push('protected-span-changed');
    }
  }
  const seen = new Set();
  for (const note of result.notes) {
    // Same teaching point repeated with a paraphrased reason still consumes attention twice.
    const key = JSON.stringify([note.kind, note.category, note.before, note.after]);
    if (seen.has(key)) failures.push('duplicate-note');
    seen.add(key);
  }
  const notes = presentNotes(result, policy);
  if (notes.length > policy.maxNotes) failures.push('note-budget');
  if (!policy.alternatives && notes.some(note => note.kind === 'alternative')) failures.push('alternatives-disabled');
  return { passed: failures.length === 0, failures: [...new Set(failures)], notes };
}
