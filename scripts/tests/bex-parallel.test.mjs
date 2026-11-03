import test from 'node:test';
import assert from 'node:assert/strict';
import { lanes, lanePort, validateSHA } from '../bex-parallel.mjs';
test('lanes have unique nonprivileged ports', () => {
  assert.equal(new Set(Object.values(lanes)).size, 4);
  for (const [lane, port] of Object.entries(lanes)) {
    assert.equal(lanePort(lane), port);
    assert.ok(port > 1024 && port < 65536);
  }
});
test('invalid and inherited lane names are rejected', () => {
  for (const lane of ['../escape', 'toString', '__proto__', '', undefined]) assert.throws(() => lanePort(lane));
});
test('full immutable base SHA required', () => {
  const sha = 'a'.repeat(40); assert.equal(validateSHA(sha), sha);
  for (const value of ['HEAD', 'main', '-b', '1234', undefined, 'g'.repeat(40)]) assert.throws(() => validateSHA(value));
});

import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, copyFileSync, rmSync, readFileSync, writeFileSync, readdirSync, existsSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const runner = fileURLToPath(new URL('../bex-parallel.mjs', import.meta.url));
test('integrated gate rejects non-owner before running tests', () => {
  const r = spawnSync(process.execPath, [runner, 'integrated', 'ui'], { encoding: 'utf8' });
  assert.equal(r.status, 1); assert.match(r.stderr, /Only the integration owner/);
});
test('worktree creation is reproducible and never overwrites a lane', { skip: process.platform !== 'linux' }, () => {
  const temp = mkdtempSync(path.join(tmpdir(), 'bex-worktree-test-'));
  const repo = path.join(temp, 'repo'); mkdirSync(path.join(repo, 'scripts'), { recursive: true });
  copyFileSync(runner, path.join(repo, 'scripts', 'bex-parallel.mjs'));
  const git = (...args) => {
    const r = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr); return r.stdout.trim();
  };
  try {
    git('init', '-q'); git('add', '.');
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'fixture');
    const sha = git('rev-parse', 'HEAD');
    const call = lane => spawnSync(process.execPath, [path.join(repo, 'scripts/bex-parallel.mjs'), 'create', lane, sha], { encoding: 'utf8' });
    assert.equal(call('ui').status, 0); assert.equal(call('core').status, 0);
    assert.equal(call('ui').status, 1);
    assert.equal(readFileSync(path.join(temp, 'repo-ui/scripts/bex-parallel.mjs'), 'utf8'), readFileSync(runner, 'utf8'));
    assert.match(git('worktree', 'list', '--porcelain'), /repo-core/);
  } finally { rmSync(temp, { recursive: true, force: true }); }
});

test('occupied verification lock is preserved; failed checks record evidence and release their lock', { skip: process.platform !== 'linux' }, () => {
  const temp = mkdtempSync(path.join(tmpdir(), 'bex-gate-test-'));
  const repo = path.join(temp, 'repo');
  mkdirSync(path.join(repo, 'scripts/tests'), { recursive: true });
  mkdirSync(path.join(repo, 'web/.parallel/running'), { recursive: true });
  copyFileSync(runner, path.join(repo, 'scripts/bex-parallel.mjs'));
  const git = (...args) => {
    const r = spawnSync('git', args, { cwd: repo, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
  };
  try {
    writeFileSync(path.join(repo, '.gitignore'), 'web/.parallel/\n');
    writeFileSync(path.join(repo, 'web/package-lock.json'), '{}\n');
    writeFileSync(path.join(repo, 'scripts/tests/bex-parallel.test.mjs'), '');
    writeFileSync(path.join(repo, 'scripts/bex-web.mjs'), 'process.exitCode = 2;\n');
    git('init', '-q'); git('add', '.');
    git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'fixture');
    const call = () => spawnSync(process.execPath, [path.join(repo, 'scripts/bex-parallel.mjs'), 'fast', 'core'], { encoding: 'utf8' });
    assert.equal(call().status, 1);
    assert.ok(existsSync(path.join(repo, 'web/.parallel/running')));
    rmSync(path.join(repo, 'web/.parallel/running'), { recursive: true });
    assert.equal(call().status, 1);
    assert.equal(existsSync(path.join(repo, 'web/.parallel/running')), false);
    const reports = readdirSync(path.join(repo, 'web/.parallel')).filter(file => file.startsWith('evidence-'));
    assert.equal(reports.length, 1);
    const report = JSON.parse(readFileSync(path.join(repo, 'web/.parallel', reports[0]), 'utf8'));
    assert.equal(report.status, 'failed');
    assert.deepEqual(report.stages.map(stage => stage.status), ['passed', 'failed']);
  } finally { rmSync(temp, { recursive: true, force: true }); }
});

for (const scenario of ['stable unusual paths', 'source mutation', 'temporary directory failure', 'failed test and mutation']) {
  test(`evidence handles ${scenario}`, { skip: process.platform !== 'linux' }, () => {
    const temp = mkdtempSync(path.join(tmpdir(), 'bex-evidence-test-'));
    const repo = path.join(temp, 'repo');
    mkdirSync(path.join(repo, 'scripts/tests'), { recursive: true });
    mkdirSync(path.join(repo, 'web/.parallel'), { recursive: true });
    copyFileSync(runner, path.join(repo, 'scripts/bex-parallel.mjs'));
    try {
      writeFileSync(path.join(repo, '.gitignore'), 'web/.parallel/\n');
      writeFileSync(path.join(repo, 'web/package-lock.json'), '{}\n');
      writeFileSync(path.join(repo, 'scripts/tests/bex-parallel.test.mjs'), '');
      writeFileSync(path.join(repo, 'odd "name\n.txt'), 'synthetic');
      symlinkSync('/not-present-bex-test-target', path.join(repo, 'external-link'));
      const mutates = scenario.includes('mutation');
      writeFileSync(path.join(repo, 'scripts/bex-web.mjs'), mutates
        ? "import { writeFileSync } from 'node:fs'; writeFileSync('changed.txt', 'changed');" +
          (scenario.startsWith('failed') ? 'process.exitCode = 2;' : '')
        : '');
      if (scenario === 'temporary directory failure') writeFileSync(path.join(repo, 'web/.parallel/tmp'), 'not a directory');
      for (const args of [['init', '-q'], ['add', '.'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'fixture']]) {
        const r = spawnSync('git', args, { cwd: repo, encoding: 'utf8' }); assert.equal(r.status, 0, r.stderr);
      }
      const result = spawnSync(process.execPath, [path.join(repo, 'scripts/bex-parallel.mjs'), 'fast', 'core'], { encoding: 'utf8' });
      const stable = scenario === 'stable unusual paths';
      assert.equal(result.status, stable ? 0 : 1, result.stderr);
      assert.equal(existsSync(path.join(repo, 'web/.parallel/running')), false);
      const reportFile = readdirSync(path.join(repo, 'web/.parallel')).find(file => file.startsWith('evidence-'));
      assert.ok(reportFile);
      const report = JSON.parse(readFileSync(path.join(repo, 'web/.parallel', reportFile), 'utf8'));
      assert.equal(report.sourceStable, !mutates);
      assert.equal(report.status, stable ? 'passed' : 'failed');
      assert.ok(report.sourceSHA256['odd "name\n.txt']);
      assert.ok(report.sourceSHA256['external-link']);
      if (mutates) assert.match(report.integrityError, /Source or HEAD changed/);
      if (scenario.startsWith('failed')) assert.match(report.error, /failed/);
      if (scenario === 'temporary directory failure') assert.equal(report.stages.length, 0);
    } finally { rmSync(temp, { recursive: true, force: true }); }
  });
}

for (const filename of [' hidden.txt', '\thidden.txt', '\nhidden.txt', 'data/file']) {
  test(`snapshot does not lose whitespace or traverse ancestor links: ${JSON.stringify(filename)}`, { skip: process.platform !== 'linux' }, () => {
    const temp = mkdtempSync(path.join(tmpdir(), 'bex-path-test-'));
    const repo = path.join(temp, 'repo');
    const linked = filename === 'data/file';
    mkdirSync(path.join(repo, 'scripts/tests'), { recursive: true });
    mkdirSync(path.join(repo, 'web'), { recursive: true });
    copyFileSync(runner, path.join(repo, 'scripts/bex-parallel.mjs'));
    try {
      writeFileSync(path.join(repo, '.gitignore'), 'web/.parallel/\n');
      writeFileSync(path.join(repo, 'web/package-lock.json'), '{}\n');
      writeFileSync(path.join(repo, 'scripts/tests/bex-parallel.test.mjs'), '');
      if (linked) mkdirSync(path.join(repo, 'data'));
      writeFileSync(path.join(repo, filename), 'original');
      writeFileSync(path.join(repo, 'scripts/bex-web.mjs'), linked ? '' :
        `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(filename)}, 'mutated');`);
      for (const args of [['init', '-q'], ['add', '.'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost', 'commit', '-qm', 'fixture']]) {
        const result = spawnSync('git', args, { cwd: repo, encoding: 'utf8' }); assert.equal(result.status, 0, result.stderr);
      }
      if (linked) {
        const outside = path.join(temp, 'outside'); mkdirSync(outside);
        // Synthetic, inaccessible-looking target: rejection must happen before hashing it.
        mkdirSync(path.join(outside, 'file'));
        rmSync(path.join(repo, 'data'), { recursive: true });
        symlinkSync(outside, path.join(repo, 'data'));
      }
      const result = spawnSync(process.execPath, [path.join(repo, 'scripts/bex-parallel.mjs'), 'fast', 'core'], { encoding: 'utf8' });
      assert.equal(result.status, 1);
      assert.equal(existsSync(path.join(repo, 'web/.parallel/running')), false);
      const reportFile = readdirSync(path.join(repo, 'web/.parallel')).find(file => file.startsWith('evidence-'));
      const report = JSON.parse(readFileSync(path.join(repo, 'web/.parallel', reportFile), 'utf8'));
      assert.equal(report.status, 'failed');
      if (linked) {
        assert.match(report.error, /Refusing symlink ancestor: data\/file/);
        assert.equal(report.stages.length, 0);
        assert.equal(report.sourceSHA256, undefined);
      } else {
        assert.ok(report.sourceSHA256[filename]);
        assert.equal(report.sourceStable, false);
        assert.match(report.integrityError, /Source or HEAD changed/);
      }
    } finally { rmSync(temp, { recursive: true, force: true }); }
  });
}
