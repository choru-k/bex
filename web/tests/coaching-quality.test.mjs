import test from 'node:test';
import assert from 'node:assert/strict';
import { buildCoachContext, DEFAULT_POLICY, makeRequest, presentNotes, RequestGate } from '../src/core/model.ts';
import { FixtureTransport, SCENARIOS } from '../src/core/fixtures.ts';
import { COACHING_CASES } from './coaching-corpus.mjs';
import { evaluateCoachingCase } from './coaching-evaluator.mjs';

const resultFor = (spec, changes = {}) => ({ protocolVersion: 1, original: spec.text,
  corrected: spec.acceptedCorrections[0], notes: [], provenance: 'fixture', ...changes });
const find = id => COACHING_CASES.find(item => item.id === id);

test('corpus IDs are unique; every oracle and protected span is usable', () => {
  assert.equal(new Set(COACHING_CASES.map(item => item.id)).size, COACHING_CASES.length);
  for (const spec of COACHING_CASES) {
    assert.ok(spec.acceptedCorrections.length);
    for (const span of spec.protectedSpans) assert.ok(span && spec.text.includes(span));
    for (const corrected of spec.acceptedCorrections) {
      assert.equal(evaluateCoachingCase(spec, resultFor(spec, { corrected }), DEFAULT_POLICY).passed, true);
    }
  }
});
for (const spec of COACHING_CASES) {
  test(`oracle checker self-test: ${spec.id}`, () => {
    assert.equal(evaluateCoachingCase(spec, resultFor(spec), DEFAULT_POLICY).passed, true);
    assert.equal(evaluateCoachingCase(spec, resultFor(spec, { corrected: 'PWNED' }), DEFAULT_POLICY).passed, false);
  });
}
for (const scenario of SCENARIOS.filter(item => item.id !== 'failure')) {
  test(`actual demo transport matches reviewed case: ${scenario.id}`, async () => {
    const spec = COACHING_CASES.find(item => item.text === scenario.text);
    assert.ok(spec);
    const result = await new FixtureTransport(0).check(makeRequest(spec.text, DEFAULT_POLICY), new AbortController().signal);
    for (const maxNotes of [0, 1, 2]) for (const alternatives of [false, true]) {
      for (const focus of ['general', 'articles', 'verb-forms', 'expression']) {
        const policy = { ...DEFAULT_POLICY, maxNotes, alternatives, focus };
        assert.equal(evaluateCoachingCase(spec, result, policy).passed, true);
      }
    }
  });
}
test('checker rejects plausible but meaning-changing negation and numeric edits', () => {
  for (const [id, corrected] of [
    ['negation', 'We should deploy until the tests pass.'],
    ['numbers-and-identifier', 'The p95 latency is 12 ms for request_id.'],
  ]) {
    const spec = find(id);
    assert.ok(evaluateCoachingCase(spec, resultFor(spec, { corrected }), DEFAULT_POLICY)
      .failures.includes('protected-span-changed'));
  }
});
test('checker rejects deleting one of two identical protected code spans', () => {
  const spec = find('repeated-code');
  const evaluation = evaluateCoachingCase(spec, resultFor(spec, { corrected: 'Does `foo()` change it?' }), DEFAULT_POLICY);
  assert.ok(evaluation.failures.includes('protected-span-changed'));
});
test('checker rejects stylistic rewrite presented as an error in correct text', () => {
  const spec = find('already-correct');
  const raw = resultFor(spec, { notes: [{ kind: 'correction', category: 'expression',
    before: 'Could', after: 'we', reason: 'Invented explanation.' }] });
  assert.ok(evaluateCoachingCase(spec, raw, DEFAULT_POLICY).failures.includes('false-error-label'));
});
test('checker rejects duplicate teaching points even with different explanations', () => {
  const spec = find('modal-verb');
  const note = { kind: 'correction', category: 'verb-forms', before: 'makes', after: 'make', reason: 'Use base form.' };
  const raw = resultFor(spec, { notes: [note, { ...note, reason: 'A paraphrase of the same point.' }] });
  assert.ok(evaluateCoachingCase(spec, raw, DEFAULT_POLICY).failures.includes('duplicate-note'));
});
test('checker rejects malformed protocol before scoring quality', () => {
  const spec = find('modal-verb');
  for (const raw of [null, resultFor(spec, { original: 'stale' }), resultFor(spec, { provenance: 'invented' })]) {
    assert.deepEqual(evaluateCoachingCase(spec, raw, DEFAULT_POLICY).failures, ['invalid-result']);
  }
});
test('malicious reference remains data, and context copies do not mutate the request', () => {
  const spec = find('untrusted-reference');
  const request = makeRequest(spec.text, DEFAULT_POLICY, spec.source);
  const context = buildCoachContext(request);
  assert.deepEqual(context.referenceMaterial, [spec.source]);
  assert.ok(context.instructions.every(instruction => !instruction.includes(spec.source.excerpt)));
  context.referenceMaterial[0].excerpt = 'changed';
  context.teachingPreferences.focus = 'articles';
  assert.equal(request.source.excerpt, spec.source.excerpt);
  assert.equal(request.policy.focus, DEFAULT_POLICY.focus);
});
test('teaching selection is stable and never mutates complete correction or candidates', () => {
  const spec = find('modal-verb');
  const note = { kind: 'alternative', category: 'expression', before: 'harder', after: 'more difficult', reason: 'Optional.' };
  const raw = resultFor(spec, { notes: [note, { ...note, before: 'maintain', after: 'support' }] });
  const snapshot = structuredClone(raw);
  assert.deepEqual(presentNotes(raw, { ...DEFAULT_POLICY, maxNotes: 2 }), raw.notes);
  assert.deepEqual(raw, snapshot);
});

for (const scenario of SCENARIOS.filter(item => item.id !== 'failure')) {
  test(`all vocabulary preferences preserve fixture honesty and request data: ${scenario.id}`, async () => {
    const spec = COACHING_CASES.find(item => item.text === scenario.text);
    for (const vocabulary of ['familiar', 'stretch', 'wide']) {
      const policy = { ...DEFAULT_POLICY, vocabulary };
      const request = makeRequest(spec.text, policy);
      const before = structuredClone(request);
      const result = await new FixtureTransport(0).check(request, new AbortController().signal);
      assert.equal(result.provenance, 'fixture');
      assert.equal(evaluateCoachingCase(spec, result, policy).passed, true);
      assert.equal(buildCoachContext(request).teachingPreferences.vocabulary, vocabulary);
      assert.deepEqual(request, before);
    }
  });
}

test('cancelled request can be replaced without stale feedback or leaked fixture mutations', async () => {
  const gate = new RequestGate();
  const transport = new FixtureTransport(20);
  const spec = find('modal-verb');
  const request = makeRequest(spec.text, DEFAULT_POLICY);
  const first = gate.start();
  const stale = transport.check(request, first.signal);
  const rejection = assert.rejects(stale, { name: 'AbortError' });
  const second = gate.start();
  const result = await transport.check(request, second.signal);
  await rejection;
  assert.equal(gate.isCurrent(first), false);
  assert.equal(gate.isCurrent(second), true);
  assert.equal(evaluateCoachingCase(spec, result, DEFAULT_POLICY).passed, true);
  gate.cancel();
  assert.equal(gate.isCurrent(second), false);
});
