// Source evidence only: this does not compile Swift or exercise native UI, AX, XPC or TCC.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
const read = path => fs.readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const window = read('Bex/Application/WindowCoordinator.swift');
const vm = read('Bex/PromptGate/PromptGateViewModel.swift');
const settings = read('Bex/Settings/SettingsViewModel.swift');
const adapter = read('Bex/Application/IndependentAccessibilityTargetService.swift');
const delegate = read('Bex/Application/AppDelegate.swift');
function method(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, signature);
  const end = source.indexOf('\n  }', start) + 4;
  assert.ok(end > start);
  return source.slice(start, end);
}

// Legacy source slices pinned to published 50b1d3d / local 99a7313.
const legacySlices = [
  [
    "Bex/Application/WindowCoordinator.swift",
    "  func showPromptGate() {",
    "    if pendingManualFixAndSendDraft != nil {",
    "582ab5c300187947b5c1739c5f0c4888074138c8c839ace7de427a0565deb2cb"
  ],
  [
    "Bex/Application/WindowCoordinator.swift",
    "  private func reinvokeManualFixAndSend() {",
    null,
    "ed6437c6e6fcda3c42cba1b85809900ced0cf9872168b7c770a6182f77ecb5e3"
  ],
  [
    "Bex/Application/WindowCoordinator.swift",
    "  private func handleSettingsRoute(_ intent: SettingsRouteIntent) {",
    "    mainWindowController?.close()\n    switch intent {",
    "a01e077767b3cf0d96619010e445f9d21aee7853f3be17b1f7c65fc17657a975"
  ],
  [
    "Bex/Application/AppDelegate.swift",
    "  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {",
    "    guard let owner = services?.packagedCorrectionWindows",
    "f3fb6de28d4e2ae1a031f599dcae9f61c935984e23b5f6a9527b5a675641a503"
  ],
  [
    "Bex/PromptGate/PromptGateViewModel.swift",
    "  func requestAccessibility() {",
    "    let wasTrusted = isAccessibilityTrusted",
    "48b62b21a5e9c2f185e3ce8fde0c62cb35a287b69baa75c164f35fb0112ef2dd"
  ],
  [
    "Bex/PromptGate/PromptGateViewModel.swift",
    "  func refreshAccessibilityState() {",
    "    let wasTrusted = isAccessibilityTrusted",
    "0736fa7a45efe2a3135419a46d3d596dc74793a626df796cd03b00f3408cf4bc"
  ],
  [
    "Bex/Settings/SettingsViewModel.swift",
    "  func requestAccessibility() {",
    "    let trusted = promptTarget.requestAccessibilityTrust()",
    "4e14448f1f102ca5662ac7443c02d31e81c4646a30b4f0e7b06095c990051e06"
  ],
  [
    "Bex/Settings/SettingsViewModel.swift",
    "  func refreshAccessibilityState() {",
    "    let wasTrusted = accessibilityTrusted",
    "024d729a63f05225c26b4d087d0d9e2c46e54abe3ed3105e6a15f74ff670f2cc"
  ]
];

test('legacy capture, recovery and permission branches retain source apart from injected activation edge', () => {
  for (const [path, signature, anchor, expected] of legacySlices) {
    let body = method(read(path), signature);
    if (anchor) { const offset = body.indexOf(anchor); assert.ok(offset >= 0); body = body.slice(offset); }
    // Only this reviewed edge moved into a production-default effect. Keep the old
    // route hash and require exactly one substitution, rather than rebaselining it.
    if (signature === '  private func handleSettingsRoute(_ intent: SettingsRouteIntent) {') {
      const injected = 'services.runtimeEffects.activateExternalApplication(processID)';
      const original = 'NSRunningApplication(processIdentifier: processID)?.activate()';
      assert.equal(body.split(injected).length - 1, 1);
      assert.equal(body.split(original).length - 1, 0);
      body = body.replace(injected, original);
    }
    const normalized = body.split('\n').map(line => line.trim()).filter(Boolean).join('\n');
    assert.equal(crypto.createHash('sha256').update(normalized).digest('hex'), expected, signature);
  }
});

test('helper injection is immutable, optional and never selected by production construction', () => {
  assert.match(delegate, /let coordinator = WindowCoordinator\(services: services\)/);
  assert.doesNotMatch(read('Bex/Application/AppServices.swift'), /IndependentAccessibilityTargetService|AccessibilityAgentClient/);
  for (const source of [window, vm, settings]) {
    assert.match(source, /private let independentTargetService: IndependentAccessibilityTargetService\?/);
    assert.match(source, /independentTargetService: IndependentAccessibilityTargetService\? = nil/);
    assert.equal((source.match(/self.independentTargetService = independentTargetService/g) ?? []).length, 1);
    assert.doesNotMatch(source, /IndependentAccessibilityTargetService\(|AccessibilityAgentClient\(|UserDefaults.*independent|#if.*INDEPENDENT/);
  }
  assert.equal((window.match(/independentTargetService: independentTargetService,/g) ?? []).length, 2);
});

test('helper capture coalesces and binds generation, review and exact user draft before presentation', () => {
  const capture = method(window, '  private func captureIndependentPromptGate() {');
  assert.ok(capture.indexOf('guard independentCaptureTasks.isEmpty') < capture.indexOf('retireIndependentCaptures()'));
  for (const evidence of ['!Task.isCancelled', '!self.independentStopped',
    'self.independentCaptureGeneration == generation', 'self.promptGateViewModel?.session?.id == previousSession',
    'Self.sameDraft(self.promptGateViewModel?.draft, previousDraft)',
    'Self.sameDraft(self.pendingManualFixAndSendDraft, pendingDraft)', 'helper.discard(capture.target)']) assert.ok(capture.includes(evidence));
  assert.equal((capture.match(/self.promptGateViewModel\?\.session\?\.id == previousSession/g) ?? []).length, 2);
  assert.match(capture, /if self.showPromptGate\(session: session\) \{ self.pendingManualFixAndSendDraft = nil \}/);
  assert.doesNotMatch(capture, /services.promptTarget|requestAccessibilityTrust|\.activate\(/);
  for (const signature of ['  func closePromptGate() {', '  func showPromptGate(hookRequest: HookReviewRequest) -> Bool {',
    '  func showSettings(origin: SettingsSetupOrigin? = nil) {', '  func windowWillClose(_ notification: Notification) {']) {
    assert.match(method(window, signature), /retireIndependentCaptures\(\)/);
  }
  const route = method(window, '  private func handleSettingsRoute(_ intent: SettingsRouteIntent) {');
  const helper = route.slice(route.indexOf('if independentTargetService != nil'), route.indexOf('    mainWindowController?.close()\n    switch intent'));
  assert.doesNotMatch(helper, /\.activate\(|captureFrontmostTarget\(|pendingManualFixAndSendDraft =/);
});

test('each helper validation await has current-session cancellation guards before receipt or acknowledgement', () => {
  const flow = method(vm, '  func performDelivery(_ action: PromptDeliveryAction) {');
  assert.equal((flow.match(/try targetService.validateDelivery\(/g) ?? []).length, 3);
  const asyncChecks = [...flow.matchAll(/try await independentTargetService.validateDelivery\([\s\S]*?\} else \{/g)];
  assert.equal(asyncChecks.length, 3);
  for (const [check] of asyncChecks) {
    assert.match(check, /Task.checkCancellation\(\)/);
    assert.match(check, /self.isCurrent\(sessionID: session.id, generation: sessionGeneration\), phase == \.delivering/);
  }
  assert.match(flow, /hookDeliveryMayHaveCommitted = true[\s\S]*hookResponder.complete/);
  assert.match(flow, /let failure = hookDeliveryMayHaveCommitted[\s\S]*effect: \.unknown/);
});

test('helper status is fresh and observer cancellation cannot own shared transport lifetime', () => {
  const status = method(adapter, '  func accessibilityStatus() async throws -> Bool {');
  assert.match(status, /if let statusRequest \{ request = statusRequest \}/);
  assert.match(status, /Task \{ @MainActor \[client\] in try await client.status\(\) \}/);
  assert.match(status, /let trusted = try await request.task.value\s+try Task.checkCancellation\(\)/);
  assert.doesNotMatch(status, /withTaskCancellationHandler|\.cancel\(\)/);
  for (const source of [vm, settings]) {
    const refresh = method(source, '  private func refreshIndependentAccessibilityStatus() {');
    assert.match(refresh, /!Task.isCancelled/);
    assert.match(refresh, /independentStatusGeneration ==/);
    assert.match(refresh, /unavailable or not enabled/);
    assert.doesNotMatch(refresh, /requestAccessibilityTrust|AXIsProcessTrusted/);
    assert.match(method(source, '  func requestAccessibility() {'), /if independentTargetService != nil \{ refreshIndependentAccessibilityStatus\(\); return \}/);
  }
});

test('shutdown closes helper admission synchronously, clears pending presentation and drains', () => {
  const termination = method(delegate, '  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {');
  assert.ok(termination.indexOf('windowCoordinator.closeIndependentAccessibilityAdmission()') < termination.indexOf('packagedTerminationTask = Task'));
  const invoke = method(window, '  func showPromptGate() {');
  assert.ok(invoke.indexOf('guard !independentStopped else { return }') < invoke.indexOf('promptGatePanelController?.show()'));
  assert.match(invoke, /if independentTargetService != nil \{\s+guard !independentStopped else \{ return \}/);
  const hook = method(window, '  func showPromptGate(hookRequest: HookReviewRequest) -> Bool {');
  assert.match(hook, /if independentTargetService != nil, independentStopped \{ return false \}/);
  assert.ok(hook.indexOf('independentStopped { return false }') < hook.indexOf('independentTargetService.target(for: hookRequest)'));
  const close = method(window, '  func closeIndependentAccessibilityAdmission() {');
  assert.match(close, /independentStopped = true/);
  assert.match(close, /pendingPromptGateSession = nil/);
  assert.match(close, /promptGateViewModel\?\.invalidateIndependentSession\(\)/);
  assert.match(close, /independentTargetService.closeAdmission\(\)/);
  const present = method(window, '  private func showPromptGate(session: PromptGateSession) -> Bool {');
  assert.match(present, /if let independentTargetService, independentStopped \{\s+independentTargetService.discard\(session.target\)\s+return false/);
  assert.match(method(window, '  func shutdownIndependentAccessibility() async {'), /await independentTargetService.stop\(\)[\s\S]*await task.value[\s\S]*waitForCurrentWork/);
});


test('native mock sources cover coordinator, view-model and Settings integration without real activation', () => {
  const coordinator = read('BexTests/IndependentCaptureCompositionTests.swift');
  for (const name of ['testSecondHotKeyCoalescesWhileFirstCaptureIsPending',
    'testCloseDuringPendingCaptureDiscardsLateResultWithoutOpeningReview',
    'testShutdownDrainsLateCaptureAndRejectsLaterInvocations',
    'testSynchronousAdmissionCloseRejectsQueuedCaptureBeforeAsyncDrain',
    'testCancellingOneStatusObserverKeepsSharedTransportAndCapturedSessionAlive']) assert.ok(coordinator.includes(name));
  const viewModel = read('BexTests/PromptGateViewModelTests.swift');
  for (const name of ['testInjectedHelperDeliversThroughExistingViewModelWithoutLegacyDelivery',
    'testInjectedHelperHookUsesSameManualAuthorityAndKeepsAcknowledgementSemantics',
    'testInjectedHelperRechecksInvalidationAfterAwaitedValidation',
    'testInjectedHelperUnavailableStatusNeverRequestsMainAppPermissionOrChangesDraft',
    'testInjectedHelperLateStatusCannotPublishIntoClosedSession',
    'testInjectedHelperDoesNotAcceptLegacyIssuedTargetAsManualFallback']) assert.ok(viewModel.includes(name));
  const settings = read('BexTests/SettingsNavigationTests.swift');
  assert.match(settings, /testInjectedSettingsChecksOnlyHelperAndNeverRequestsMainAppAccess/);
  assert.match(settings, /testClosedSettingsRejectsLateHelperStatusWithoutCancellingSharedTransport/);
  assert.doesNotMatch(coordinator, /AppServices.production|NSXPCConnection\(|AXIsProcessTrustedWithOptions|\.register\(/);
});
