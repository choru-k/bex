// Source-regression checks only. These do NOT compile Swift, execute AppKit/AX,
// validate native permissions, prove atomic external UI operations, or activate Bex.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read = path => fs.readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const service = read('Bex/Application/PromptTargetService.swift');
const models = read('Bex/PromptGate/PromptGateModels.swift');
const vm = read('Bex/PromptGate/PromptGateViewModel.swift');
const windows = read('Bex/Application/WindowCoordinator.swift');
const fixtures = read('Bex/Application/UITestingServices.swift');
function body(source, start, end) {
  const left = source.indexOf(start), right = source.indexOf(end, left + start.length);
  assert.ok(left >= 0 && right > left, `Expected source boundaries ${start} / ${end}`);
  return source.slice(left, right);
}
const concrete = service.slice(service.indexOf('final class PromptTargetService:'));
const delivery = body(concrete, '  func deliver(', '  func discard(');
const validate = body(concrete, '  func validateDelivery(', '  func deliver(');

test('production generic AX adapter has no mutation or global event implementation', () => {
  assert.doesNotMatch(service, /CGEvent|postPaste|postReturn|AXUIElementSetAttributeValue|selectAll|activateIgnoringOtherApps|\.activate\(|pasteboardTransaction|Carbon\.HIToolbox/);
  const reader = body(service, 'protocol PromptAccessibilityServicing:', '@MainActor\nfinal class SystemPromptAccessibilityService');
  assert.doesNotMatch(reader, /func (focus|set|select|paste|submit)\b/);
  assert.match(service, /not a transactional compare-and-replace/);
});

test('all concrete targets are issued and clipboard extension keeps exact target identity', () => {
  const extension = body(service, 'extension PromptTargetServicing {', 'struct PromptApplicationSnapshot:');
  assert.doesNotMatch(extension, /PromptTarget\(|makeStandaloneTarget\(|validateDelivery\(/);
  assert.match(extension, /case \.copyCorrection:\s+return try await deliver\(correctedText, to: target, pressReturn: false\)/);
  assert.equal((concrete.match(/PromptTarget\(/g) ?? []).length, 5);
  assert.equal((concrete.match(/try issue\(PromptTarget\(/g) ?? []).length, 5);
  assert.match(windows, /target = try services\.promptTarget\.makeStandaloneTarget\(\)/);
  assert.doesNotMatch(windows, /target: PromptTarget\(/);
});

test('unknown, mutated, expired and consumed capabilities cannot regain authority', () => {
  assert.match(validate, /guard let issued = issuedTargets\[target\.id\], issued\.expiresAt > now\(\)/);
  assert.match(validate, /issuedTargets\.removeValue\(forKey: target\.id\)/);
  assert.match(validate, /effect: \.unknown/);
  assert.match(validate, /guard issued\.target\.matchesDeliveryIdentity\(target\)/);
  assert.match(concrete, /issuedTargets\.count < maximumPendingTargets/);
  assert.match(concrete, /maximumPendingTargets: Int = 64/);
  assert.match(concrete, /expiresAt: date\.addingTimeInterval\(3600\)/);
  assert.match(concrete, /func discard\(_ target: PromptTarget\) \{\s+issuedTargets\.removeValue\(forKey: target\.id\)/);
});

test('clipboard capability is consumed before one synchronous side effect and uncertainty is terminal', () => {
  const check = delivery.indexOf('try validateDelivery(to: target, action: action)');
  const consume = delivery.indexOf('issuedTargets.removeValue(forKey: target.id)');
  const write = delivery.indexOf('try pasteboardWriter.write(correctedText)');
  assert.ok(check >= 0 && check < consume && consume < write);
  assert.doesNotMatch(delivery, /\bawait\b/);
  assert.equal((delivery.match(/pasteboardWriter\.write\(/g) ?? []).length, 1);
  assert.match(delivery, /guard !pressReturn else/);
  assert.match(delivery, /if target\.kind == \.managedDraft \{ return \.staged \}/);
  assert.match(delivery.slice(write), /catch \{[\s\S]*PromptDeliveryFailure\(effect: \.unknown/);
});

test('capture rechecks exact process, launch, focus, security role and original UTF8 bytes', () => {
  const revalidate = concrete.slice(concrete.indexOf('  private func revalidate('));
  for (const expected of ['application.processID == captured.application.processID',
    'application.bundleID == captured.application.bundleID',
    'application.launchDate == captured.application.launchDate',
    'accessibility.isSameElement(focused, captured.element)',
    'accessibility.subrole(of: focused) != kAXSecureTextFieldSubrole',
    'accessibility.stringValue(of: focused).utf8.elementsEqual(captured.original.utf8)']) {
    assert.ok(revalidate.includes(expected), expected);
  }
  assert.match(concrete, /guard application\.launchDate != nil/);
  assert.match(concrete, /try revalidate\(captured\)\s+guard applications\.frontmostApplication/);
  assert.match(service, /CFGetTypeID\(value\) == AXUIElementGetTypeID\(\)/);
  assert.match(service, /guard result == \.success, let subrole = value as\? String else/);
});

test('legacy generic kinds expose only Copy while host managed Stage survives', () => {
  assert.match(models, /supportsAutomaticSubmit: Bool \{ false \}/);
  assert.match(models, /case \.copyOnly, \.composerPaste, \.capturedField:\s+\[\.copyCorrection\]/);
  assert.match(models, /case \.managedDraft:\s+\[\.pasteInDestination\]/);
  assert.match(models, /kind == \.managedDraft \? applicationName : "Clipboard"/);
  assert.match(concrete, /if hookRequest\.client == \.ohMyPi \{\s+return try issue\(PromptTarget\(\s+kind: \.managedDraft/);
  assert.doesNotMatch(concrete, /kind: \.composerPaste/);
});

test('host acknowledgement is exact-context checked and post-ack failures never offer retry', () => {
  const flow = body(vm, '  func performDelivery(', '  func finishAfterPartialDelivery()');
  const firstCheck = flow.indexOf('try targetService.validateDelivery(');
  const receipt = flow.indexOf('issuedReceipt = try await approvalStore.issue(');
  const uncertain = flow.indexOf('hookDeliveryMayHaveCommitted = true');
  const complete = flow.indexOf('try await hookResponder.complete(');
  assert.ok(firstCheck >= 0 && firstCheck < receipt && receipt < uncertain && uncertain < complete);
  assert.equal((flow.match(/try targetService\.validateDelivery\(/g) ?? []).length, 3);
  assert.match(flow, /context\.requestID == session\.hookRequestID, context\.client == client/);
  assert.match(flow, /catch is CancellationError where !hookDeliveryMayHaveCommitted/);
  assert.match(flow, /let failure = hookDeliveryMayHaveCommitted\s+\? PromptDeliveryFailure\(effect: \.unknown/);
  assert.match(flow, /if outcome == \.submitted \{ deliveredCallback\(deliveredTo\) \}/);
});

test('invalidation and rejected/replaced sessions release exact live capabilities', () => {
  const invalidate = body(vm, '  func invalidateHookRequest(', '  func waitForCurrentWork()');
  assert.match(invalidate, /targetService\.discard\(session\.target\)/);
  assert.doesNotMatch(invalidate, /original prompt remained blocked/);
  assert.match(windows, /if !began \{ services\.promptTarget\.discard\(session\.target\) \}/);
  assert.match(windows, /guard confirmFixAndSendReplacement\(\) else \{\s+services\.promptTarget\.discard\(session\.target\)/);
  assert.equal((windows.match(/if let pendingPromptGateSession \{ services\.promptTarget\.discard\(pendingPromptGateSession\.target\) \}/g) ?? []).length, 2);
});

test('native UI fixtures and visible descriptions match copy-only semantics', () => {
  assert.match(fixtures, /helperPID: hookRequest\.helperPID,\s+client: hookRequest\.client,\s+integrationID: hookRequest\.integrationID/);
  assert.match(fixtures, /\? PromptTargetService\(pasteboardWriter: pasteboard\)/);
  const fake = body(fixtures, '    func deliver(\n      _ correctedText:', '    func discard(_ target: PromptTarget)');
  assert.match(fake, /if target\.kind == \.managedDraft \{\s+outcome = \.staged/);
  assert.match(fake, /try pasteboard\.write\(correctedText\)\s+outcome = \.copied/);
  assert.doesNotMatch(read('Bex/PromptGate/PromptGateView.swift'), /⌘⏎ sends as-is/);
  assert.match(read('README.md'), /generic Accessibility capture no longer offers automatic paste or Return/);
  assert.doesNotMatch(read('Bex/Settings/SettingsView.swift'), /capture the focused editable field and deliver a correction/);
});

test('native test sources cover adversarial binding, one-shot, cancellation and unchanged destination', () => {
  const tests = read('BexTests/PromptTargetServiceTests.swift');
  for (const name of ['testUnknownDiscardedAndDowngradedTargetIDsNeverAuthorizeCopy',
    'testEveryCapturedTargetPropertyRemainsBoundToIssuedIdentity',
    'testCanonicallyEquivalentButDifferentBytesAreAChangedRevision',
    'testUncertainClipboardWriteConsumesCapabilityAndCannotRetry',
    'testCancellationBeforeWriteLeavesCapabilityUnconsumed',
    'testHostManagedOMPStagingRemainsSingleUseAndNeverUsesClipboard']) assert.ok(tests.includes(name));
  assert.match(read('BexTests/PromptGateViewModelTests.swift'), /testPostAcknowledgementCopyFailureOrCancellationNeverAllowsRetry/);
  const ui = read('BexUITests/BexUITests.swift');
  assert.match(ui, /XCTAssertEqual\(editor\.value as\? String, source\)/);
  assert.match(ui, /XCTAssertEqual\(try String\(contentsOf: copySink, encoding: \.utf8\), expected\)/);
  assert.doesNotMatch(ui, /buttons\["prompt-gate-delivery-pasteAndSubmit"\]\.click\(\)|buttons\["prompt-gate-delivery-pasteInDestination"\]\.click\(\)/);
});

// The fake's scenario contract is a native XCTest too, not executed by this source guard.
test('scenario-contract expectations preserve explicit Copy and unchanged fake destination', () => {
  const contract = read('BexTests/UITestScenarioContractTests.swift');
  assert.doesNotMatch(contract, /pastedNotSubmitted/);
  assert.match(contract, /action: \.copyCorrection/);
  assert.match(contract, /XCTAssertFalse\(FileManager\.default\.fileExists\(atPath: sinkURL\.path\)\)/);
  assert.match(contract, /XCTAssertEqual\(try String\(contentsOf: copyURL, encoding: \.utf8\), "Corrected text"\)/);
});
