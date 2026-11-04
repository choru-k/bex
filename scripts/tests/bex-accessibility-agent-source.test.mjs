// Portable source/build-graph guards only. They do not compile Swift, run NSXPC/AX,
// register a service, request TCC, validate signatures or prove permission persistence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read = path => fs.readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8');
const shared = name => read(`BexAccessibilityShared/${name}.swift`);
const wire = shared('AccessibilityAgentProtocol');
const identity = shared('AccessibilityAgentIdentity');
const store = shared('AccessibilityCaptureStore');
const observer = shared('AccessibilitySystemObserver');
const server = shared('AccessibilityAgentServer');
const client = read('Bex/Application/AccessibilityAgentClient.swift');
const adapter = read('Bex/Application/IndependentAccessibilityTargetService.swift');
const host = read('BexAccessibilityHost/BexAccessibilityMain.swift');

// Minimal strict OpenStep dictionary/array reader; validates graph, not Xcode semantics.
function parseProject(text) {
  const tokens = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\/\/.*$/gm, '')
    .match(/"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+/g);
  let at = 0;
  const take = expected => { assert.equal(tokens[at++], expected); };
  function value() {
    const token = tokens[at++];
    assert.notEqual(token, undefined);
    if (token === '{') {
      const result = {};
      while (tokens[at] !== '}') {
        const key = value(); take('=');
        assert.equal(Object.hasOwn(result, key), false, `Duplicate key ${key}`);
        result[key] = value(); take(';');
      }
      take('}'); return result;
    }
    if (token === '(') {
      const result = [];
      while (tokens[at] !== ')') { result.push(value()); if (tokens[at] !== ')') take(','); }
      take(')'); return result;
    }
    return token.startsWith('"') ? JSON.parse(token) : token;
  }
  const result = value(); assert.equal(at, tokens.length); return result;
}

test('standalone host is independent of Bex app build, embedding and native host defaults', () => {
  const project = parseProject(read('Bex.xcodeproj/project.pbxproj'));
  const objects = project.objects;
  const app = objects.A00000000000000000000011;
  const helper = objects.C70000000000000000000013;
  assert.equal(helper.name, 'BexAccessibility');
  assert.deepEqual(helper.dependencies, []);
  assert.ok(app.fileSystemSynchronizedGroups.includes('C70000000000000000000010'));
  assert.ok(!app.fileSystemSynchronizedGroups.includes('C70000000000000000000011'));
  assert.ok(app.dependencies.every(id => objects[id].target !== 'C70000000000000000000013'));
  assert.ok(!app.buildPhases.includes('C70000000000000000000016'));
  assert.ok(helper.buildPhases.includes('C70000000000000000000016'));
  assert.equal(objects.C70000000000000000000016.dstPath, 'Contents/Library/LaunchAgents');
  for (const id of objects.C70000000000000000000014.buildConfigurations) {
    const settings = objects[id].buildSettings;
    assert.equal(settings.PRODUCT_BUNDLE_IDENTIFIER, 'com.bex.accessibility');
    assert.equal(settings.DEVELOPMENT_TEAM, 'ESURPGU29C');
    assert.equal(settings.ENABLE_HARDENED_RUNTIME, 'YES');
    assert.equal(settings.INFOPLIST_FILE, 'Config/AccessibilityHost-Info.plist');
    assert.equal(settings.MACOSX_DEPLOYMENT_TARGET, '13.0');
  }
  for (const id of objects.A00000000000000000000101.buildConfigurations) {
    assert.equal(objects[id].buildSettings.BEX_EMBED_NATIVE_WEB_RESOURCES, 'NO');
  }
  const scheme = read('Bex.xcodeproj/xcshareddata/xcschemes/BexAccessibility.xcscheme');
  assert.match(scheme, /BlueprintIdentifier="C70000000000000000000013"/);
  assert.doesNotMatch(scheme, /TestAction|--agent|A00000000000000000000011/);
});

test('registration and permission changes exist only behind explicit signed stable-host buttons', () => {
  const launch = read('Config/com.bex.accessibility.agent.plist');
  assert.match(launch, /<key>BundleProgram<\/key><string>Contents\/MacOS\/BexAccessibility<\/string>/);
  assert.match(launch, /<key>AssociatedBundleIdentifiers<\/key><array><string>com.bex.accessibility<\/string>/);
  assert.doesNotMatch(launch, /RunAtLoad|KeepAlive|\/bin\/|Bex.app/);
  assert.match(host, /requireReviewedInstallation\(\)[\s\S]*verifyOwnIdentity\(as: \.helper\)/);
  assert.match(host, /resolvingSymlinksInPath\(\)\.path == "\/Applications\/BexAccessibility.app"/);
  assert.match(host, /@objc private func enableService\(\)[\s\S]*try requireReviewedInstallation\(\)[\s\S]*try service.register\(\)/);
  assert.match(host, /@objc private func requestTrust\(\)[\s\S]*try requireReviewedInstallation\(\)[\s\S]*AXIsProcessTrustedWithOptions/);
  const init = host.slice(host.indexOf('override init()'), host.indexOf('func show()'));
  assert.doesNotMatch(init, /service.register\(|AXIsProcessTrustedWithOptions\(/);
  for (const source of [wire, identity, store, observer, server, client, adapter]) {
    assert.doesNotMatch(source, /AXIsProcessTrustedWithOptions|\.register\(|SMAppService|\.unregister\(/);
  }
});

test('both IPC peers use exact configured Apple/team/identifier identity before resume', () => {
  assert.match(wire, /appIdentifier = "com.bex.desktop"/);
  assert.match(wire, /helperIdentifier = "com.bex.accessibility"/);
  assert.match(wire, /teamIdentifier = "ESURPGU29C"/);
  assert.match(identity, /anchor apple generic and identifier/);
  assert.match(identity, /certificate leaf\[subject.OU\]/);
  assert.match(identity, /SecRequirementCreateWithString/);
  assert.match(identity, /SecCodeCheckValidity\(code, \[\], requirement\)/);
  assert.ok(client.indexOf('candidate.setCodeSigningRequirement') < client.indexOf('candidate.resume()'));
  assert.ok(server.indexOf('connection.setCodeSigningRequirement') < server.indexOf('connection.resume()'));
  assert.match(client, /NSXPCConnection\(machServiceName: AccessibilityAgentContract.serviceName, options: \[\]\)/);
  assert.doesNotMatch(client, /\.privileged/);
  assert.match(server, /connection.effectiveUserIdentifier == getuid\(\), getuid\(\) != 0/);
  assert.match(client, /operation: \.hello, challenge: challenge/);
  assert.match(client, /response.challenge == challenge,[\s\S]*let session = response.session/);
  const hello = store.slice(store.indexOf('if request.operation == .hello'), store.indexOf('guard let session'));
  assert.doesNotMatch(hello, /observer\.|\.original|\.capture\(/);
});

test('wire and service are read-only, bounded and contain no target mutation transport', () => {
  assert.match(wire, /case hello, status, capture, validate, consume, discard/);
  for (const source of [wire, store, observer, server, client, adapter]) {
    assert.doesNotMatch(source, /AXUIElementSetAttributeValue|CGEvent|\.activate\(|postPaste|postReturn|CGEventTap/);
  }
  assert.match(wire, /maximumMessageBytes = 524_288/);
  assert.match(wire, /maximumDraftBytes = 262_144/);
  assert.match(wire, /maximumConnections = 4/);
  assert.match(wire, /maximumPendingRequests = 8/);
  assert.match(wire, /maximumCaptures = 64/);
  assert.match(server, /deadline.schedule\(deadline: \.now\(\) \+ 5\)/);
  assert.match(server, /AccessibilityObservationDeadline\(end: acceptedAt \+ 3_000_000_000\)/);
  assert.match(store, /observer.capture\(excluding: callerProcessID, before: deadline\)/);
  assert.match(store, /field.revalidate\(before: deadline\)/);
  assert.match(observer, /AXUIElementSetMessagingTimeout\(application, 0.5\)/);
  assert.match(observer, /AXUIElementSetMessagingTimeout\(element, 0.5\)/);
  assert.match(observer, /current.utf8.elementsEqual\(original.utf8\)/);
});

test('session ownership, connection invalidation and queued AX work drain fail closed', () => {
  assert.match(server, /return control.sync \{/);
  assert.match(server, /session.close \{ \[weak self\] in self\?\.release\(id\) \}/);
  assert.match(server, /guard closed, storeClosed, pending == 0/);
  assert.match(client, /func stop\(\) async \{\s+stopped = true\s+invalidateCurrent\(\)/);
  assert.match(client, /guard !stopped else/);
  assert.match(client, /deinit \{ connections.values.forEach \{ \$0.invalidate\(\) \} \}/);
  assert.match(client, /AccessibilityAgentCapturedResult\(capture: capture, session: session\)/);
  assert.match(adapter, /let session = result.session/);
  assert.match(adapter, /client.currentSession == session else \{\s+Task \{ @MainActor \[client\] in await client.discard\(capture.token, session: session\)/);
  assert.match(store, /captures.removeAll\(\)/);
  assert.match(store, /guard session == nil else/);
});

test('manual Copy consumes and checks exact identity after suspension before one side effect', () => {
  const delivery = adapter.slice(adapter.indexOf('  func deliver('), adapter.indexOf('  func discard('));
  assert.ok(delivery.indexOf('consuming[target.id] = entry') < delivery.indexOf('try await client.consume('));
  const afterReply = delivery.slice(delivery.indexOf('try await client.consume('));
  assert.match(afterReply, /reserved.target.matchesDeliveryIdentity\(target\)/);
  assert.match(afterReply, /reserved.expiresAt > now\(\), client.currentSession == reserved.session/);
  assert.match(afterReply, /Task.checkCancellation\(\)/);
  assert.ok(afterReply.indexOf('consuming.removeValue') < afterReply.indexOf('pasteboard.write'));
  assert.equal((delivery.match(/pasteboard.write\(/g) ?? []).length, 1);
  assert.match(afterReply, /PromptDeliveryFailure\(effect: \.unknown/);
  assert.match(adapter, /action == \.copyCorrection/);
  for (const path of ['Bex/Application/AppServices.swift', 'Bex/Application/PromptTargetService.swift']) {
    assert.doesNotMatch(read(path), /IndependentAccessibilityTargetService|AccessibilityAgentClient/);
  }
  // Existing classes accept optional immutable injection, but no production caller selects it.
  assert.match(read('Bex/Application/AppDelegate.swift'), /let coordinator = WindowCoordinator\(services: services\)/);
  for (const path of ['Bex/Application/WindowCoordinator.swift', 'Bex/PromptGate/PromptGateViewModel.swift', 'Bex/Settings/SettingsViewModel.swift']) {
    assert.match(read(path), /independentTargetService: IndependentAccessibilityTargetService\? = nil/);
    assert.doesNotMatch(read(path), /IndependentAccessibilityTargetService\(/);
  }
});

test('native mock tests exist for lifecycle races and shared request budget, but are not run here', () => {
  const cases = read('BexTests/IndependentAccessibilityTargetServiceTests.swift');
  for (const name of ['testLateCaptureCannotBindToReplacementConnectionSession',
    'testLateCancelledCaptureReleasesTokenWithoutIssuingTarget',
    'testConcurrentApprovalsReserveOneLocalConsumption',
    'testDiscardDuringConsumptionSuppressesLateClipboardWrite',
    'testCancellationDuringConsumptionSuppressesLateClipboardWrite',
    'testStopDuringConsumptionIsTerminalAndNeverCopies',
    'testExpiredCaptureCannotCopyAndUncertainClipboardWriteIsNeverRetried']) assert.ok(cases.includes(name));
  const storeCases = read('BexTests/AccessibilityCaptureStoreTests.swift');
  assert.match(storeCases, /testCaptureAndFinalRevalidationShareOneBudgetAndExpiredRequestsNeverObserve/);
  assert.match(storeCases, /testRevokedPermissionDoesNotReviveOldCaptureAfterRegrant/);
  assert.doesNotMatch(cases + storeCases, /\.register\(|AXIsProcessTrustedWithOptions|NSXPCConnection\(/);
});

test('compile regression: authenticated server initialization never overrides NSObject init', () => {
  assert.match(server, /init\(validatingIdentity: Void\) throws \{/);
  assert.doesNotMatch(server, /(?:override\s+)?init\(\)\s+throws/);
  const initializer = server.slice(server.indexOf('  init(validatingIdentity: Void) throws {'), server.indexOf('  func start()'));
  const own = initializer.indexOf('try AccessibilityAgentIdentity.verifyOwnIdentity(as: .helper)');
  const peer = initializer.indexOf('try AccessibilityAgentIdentity.requirement(for: .app)');
  const listener = initializer.indexOf('NSXPCListener(machServiceName: AccessibilityAgentContract.serviceName)');
  const base = initializer.indexOf('super.init()');
  assert.ok(own >= 0 && own < peer && peer < listener && listener < base);
  assert.doesNotMatch(initializer, /try\?|try!|catch|if\s|guard\s/);
  assert.match(host, /let server = try AccessibilityAgentServer\(validatingIdentity: \(\)\)/);
  assert.doesNotMatch(host, /AccessibilityAgentServer\(\)/);
});

test('compile regression: outbound confirmation is a pure context decision, not a backing-store read', () => {
  const preferences = read('Bex/Storage/PreferencesStore.swift');
  const context = preferences.slice(preferences.indexOf('extension OutboundConfirmationContext {'), preferences.indexOf('\nactor PreferencesStore {'));
  assert.doesNotMatch(context, /backing|withLock|UserDefaults/);
  assert.match(context, /guard hasAcceptedDisclosure else \{ return true \}/);
  assert.match(context, /case \.standaloneFixAndSend, \.manualCapturedField:\s+return false/);
  assert.match(context, /case \.hook:\s+return confirmsHookOutboundPayloads/);
  assert.match(read('BexTests/PreferencesContractTests.swift'), /func testOutboundConfirmationAllInputCombinations\(\)/);
});
