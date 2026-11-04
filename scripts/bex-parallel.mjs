#!/usr/bin/env node
/** Cloud-only parallel worktrees and verification. Never starts native Bex. */
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync, lstatSync, readlinkSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const lanes = Object.freeze({ ui: 5271, core: 5272, helper: 5273, integration: 5274 });
export function lanePort(lane) {
  if (!Object.hasOwn(lanes, lane)) throw new Error(`Unknown lane: ${lane}`);
  return lanes[lane];
}
export function validateSHA(sha) {
  if (!/^[a-f0-9]{40}$/.test(sha ?? '')) throw new Error('Use a full 40-character base commit SHA.');
  return sha;
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} ${args.join(' ')} failed (${result.signal ?? result.status})`);
  return result.stdout;
}
function git(args, raw = false) {
  const output = run('git', args, { stdio: ['ignore', 'pipe', 'pipe'], encoding: 'utf8' });
  return raw ? output : output.trim();
}
const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex');
function rejectSymlinkAncestors(file) {
  let ancestor = root;
  for (const component of file.split('/').slice(0, -1)) {
    ancestor = path.join(ancestor, component);
    try {
      if (lstatSync(ancestor).isSymbolicLink()) throw new Error(`Refusing symlink ancestor: ${file}`);
    } catch (error) { if (error.code === 'ENOENT') return; throw error; }
  }
}
function sourceSnapshot() {
  // NUL delimiters preserve spaces, quotes and newlines in Git filenames.
  return Object.fromEntries(git(['ls-files', '-z', '--cached', '--others', '--exclude-standard'], true)
    .split('\0').filter(Boolean).sort().map(file => {
      rejectSymlinkAncestors(file);
      const absolute = path.join(root, file);
      let stat;
      try { stat = lstatSync(absolute); }
      catch (error) { if (error.code === 'ENOENT') return [file, null]; throw error; }
      // Hash link identity, never follow it into private files outside the checkout.
      const digest = stat.isSymbolicLink()
        ? createHash('sha256').update('symlink\0' + readlinkSync(absolute)).digest('hex')
        : stat.isFile() ? hash(absolute) : null;
      return [file, digest];
    }));
}
export function main(args = process.argv.slice(2)) {
  const [command, lane, value] = args;
  if (command === 'help' || !command) {
    console.log('Cloud Linux only:\n  node scripts/bex-parallel.mjs create <ui|core|helper|integration> <full-base-SHA>\n  node scripts/bex-parallel.mjs fast <lane>\n  node scripts/bex-parallel.mjs integrated integration\nRun checks inside each lane worktree. integrated runs npm ci, check, then Chromium + WebKit.');
    return;
  }
  if (process.platform !== 'linux') throw new Error('This workflow is cloud Linux only. Native/Mac testing requires separate user permission.');
  const port = lanePort(lane);
  if (command === 'create') {
    validateSHA(value);
    git(['cat-file', '-e', `${value}^{commit}`]);
    const target = path.join(path.dirname(root), `${path.basename(root)}-${lane}`);
    if (existsSync(target)) throw new Error(`Worktree already exists: ${target}`);
    run('git', ['worktree', 'add', '-b', `work/${lane}-${value.slice(0, 12)}`, target, value]);
    console.log(`Lane ${lane}: ${target}; loopback port ${port}. One owner per lane.`);
    return;
  }
  if (!['fast', 'integrated'].includes(command)) throw new Error(`Unknown command: ${command}`);
  if (command === 'integrated' && lane !== 'integration') throw new Error('Only the integration owner runs the integrated gate.');
  const web = path.join(root, 'web');
  const state = path.join(web, '.parallel');
  rejectSymlinkAncestors('web/.parallel/running');
  mkdirSync(state, { recursive: true });
  // One active check per worktree, including across lanes. Never remove somebody else's lock.
  const lock = path.join(state, 'running');
  mkdirSync(lock);
  let lockHash, head, dirty, sourceSHA256, sourceStable, integrityError;
  const started = new Date().toISOString();
  const stages = [];
  let failure;
  const env = { ...process.env, BEX_WEB_PORT: String(port), BEX_PARALLEL: '1',
    npm_config_cache: path.join(state, 'npm-cache'), PLAYWRIGHT_BROWSERS_PATH: path.join(state, 'browsers'),
    TMPDIR: path.join(state, 'tmp') };
  const step = (name, executable, argv, cwd = root) => {
    const entry = { name, status: 'running' }; stages.push(entry);
    try { run(executable, argv, { cwd, env }); entry.status = 'passed'; }
    catch (error) { entry.status = 'failed'; throw error; }
  };
  try {
    head = git(['rev-parse', 'HEAD']);
    dirty = git(['status', '--porcelain']);
    sourceSHA256 = sourceSnapshot();
    if (!lstatSync(path.join(web, 'package-lock.json')).isFile()) throw new Error('Lockfile must be a regular file.');
    lockHash = sourceSHA256['web/package-lock.json'];
    mkdirSync(env.TMPDIR, { recursive: true });
    step('runner tests', process.execPath, ['--test', 'scripts/tests/bex-parallel.test.mjs']);
    step('domain tests', process.execPath, ['scripts/bex-web.mjs', 'test']);
    if (command === 'integrated') {
      step('locked dependency install', 'npm', ['ci', '--no-audit', '--no-fund'], web);
      step('typecheck, domain tests, build', 'npm', ['run', 'check'], web);
      step('Chromium and WebKit', 'npm', ['run', 'test:e2e'], web);
    }
  } catch (error) { failure = error; }
  finally {
    // Check even when a test fails: evidence must never silently describe older bytes.
    if (sourceSHA256) {
      try {
        sourceStable = JSON.stringify(sourceSnapshot()) === JSON.stringify(sourceSHA256)
          && git(['rev-parse', 'HEAD']) === head;
        if (!sourceStable) throw new Error('Source or HEAD changed during verification. Rerun on a stable tree.');
      } catch (error) { sourceStable = false; integrityError = error.message; failure ??= error; }
    }
    const report = { started, finished: new Date().toISOString(), lane, command, port,
      head, dirty, sourceSHA256, sourceStable, integrityError,
      node: process.version, platform: process.platform, packageLockSHA256: lockHash,
      stages, status: failure ? 'failed' : 'passed', error: failure?.message,
      nativeTests: 'not run; separate explicit permission required' };
    const filename = path.join(state, `evidence-${Date.now()}.json`);
    try { writeFileSync(filename, JSON.stringify(report, null, 2) + '\n'); }
    finally { rmSync(lock, { recursive: true }); }
    console.log(`Evidence: ${filename}`);
  }
  if (failure) throw failure;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(`Bex parallel: ${error.message}`); process.exitCode = 1; }
}
