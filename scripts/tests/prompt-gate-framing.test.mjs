import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

// Portable protocol oracle, NOT Swift execution or Network.framework proof. The
// same JSON vectors are consumed by the standalone production-Swift parser runner.
const root = new URL('../../', import.meta.url);
const fixtures = JSON.parse(readFileSync(new URL('tests/fixtures/prompt-gate/framing.json', root)));
const maxHeader = 16_384;
const maxBody = 1_048_576;
function oracle(wire) {
  const end = wire.indexOf('\r\n\r\n');
  if (end < 0) return wire.length >= maxHeader ? 'tooLarge' : 'incomplete';
  if (end + 4 > maxHeader) return 'tooLarge';
  const text = wire.subarray(0, end).toString('utf8');
  if (!Buffer.from(text).equals(wire.subarray(0, end))) return 'malformed';
  const [line, ...headers] = text.split('\r\n');
  const parts = line.split(' ');
  if (parts.length !== 3 || parts[0] !== 'POST' || !['HTTP/1.0', 'HTTP/1.1'].includes(parts[2])) return 'malformed';
  if (!parts[1].startsWith('/') || parts[1].startsWith('//') || /[^\x21-\x7e]|[#\\]/.test(parts[1])) return 'malformed';
  let length, host;
  for (const header of headers) {
    const colon = header.indexOf(':');
    if (colon < 1) return 'malformed';
    const name = header.slice(0, colon);
    const raw = header.slice(colon + 1);
    if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name) || /[^\t\x20-\x7e]/.test(raw)) return 'malformed';
    const value = raw.replace(/^[ \t]+|[ \t]+$/g, '');
    switch (name.toLowerCase()) {
      case 'content-length':
        if (length !== undefined || !/^[0-9]+$/.test(value)) return 'malformed';
        length = BigInt(value);
        if (length > BigInt(maxBody)) return 'tooLarge';
        break;
      case 'host':
        if (host !== undefined) return 'malformed';
        host = value.toLowerCase();
        break;
      case 'transfer-encoding': case 'expect': case 'origin': return 'malformed';
    }
  }
  if (length === undefined) return 'malformed';
  if ((parts[2] === 'HTTP/1.1' || host !== undefined) && !['localhost:4321', '127.0.0.1:4321', '[::1]:4321'].includes(host)) return 'malformed';
  const received = wire.length - end - 4;
  if (received > Number(length)) return 'malformed';
  return received === Number(length) ? 'complete' : 'incomplete';
}

for (const fixture of fixtures) {
  test(`portable oracle: ${fixture.name}`, () => {
    assert.equal(oracle(Buffer.from(fixture.wire, 'base64')), fixture.expected);
  });
}

test('source contract remains wired to the production bounded parser and transport', () => {
  const parser = readFileSync(new URL('Bex/PromptGate/PromptHTTPRequestParser.swift', root), 'utf8');
  const transport = readFileSync(new URL('Bex/PromptGate/PromptGateHTTPTransport.swift', root), 'utf8');
  const server = readFileSync(new URL('Bex/PromptGate/PromptGateIPCServer.swift', root), 'utf8');
  assert.match(parser, /static let maximumHeaderBytes = 16_384/);
  assert.match(parser, /static let maximumReceiveBytes = 16_384/);
  assert.match(parser, /parsed <= \(maximumBodyBytes - digitValue\) \/ 10/);
  assert.doesNotMatch(parser, /Int\(value\)|bodyStart\s*\.\.</);
  assert.match(transport, /parameters.requiredInterfaceType = \.loopback/);
  assert.match(transport, /static let maximumConnections = 8/);
  assert.match(transport, /!connection.dispatching, !connection.notifyingClose/);
  assert.match(transport, /connection\.parser\.append\(/);
  assert.match(server, /PromptGateAuthentication\.matches\(envelope.authenticationToken/);
  assert.match(server, /envelope\.integrationID == current\.request\.integrationID/);
  assert.match(server, /envelope\.deliveryStatus == "delivered"/);
  assert.match(server, /let clock = ContinuousClock\(\)/);
  assert.doesNotMatch(parser + transport + server, /\b(?:print|debugPrint|NSLog|Logger)\s*\(/);
});
