import { access, chmod, copyFile, mkdir } from "node:fs/promises";
import { constants } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(scriptDir);

const cliDist = join(repoRoot, "packages", "cli", "dist", "index.js");
const wrapper = join(repoRoot, "packages", "app", "src-tauri", "resources", "bex");
const targetDir = join(
  repoRoot,
  "packages",
  "app",
  "src-tauri",
  "resources",
  "bex-cli",
);
const targetCli = join(targetDir, "index.js");

async function ensureExists(path, label) {
  try {
    await access(path, constants.F_OK);
  } catch {
    throw new Error(`${label} not found: ${path}`);
  }
}

async function main() {
  await ensureExists(
    cliDist,
    "Built CLI artifact",
  );
  await ensureExists(wrapper, "CLI wrapper script");

  await mkdir(targetDir, { recursive: true });
  await copyFile(cliDist, targetCli);

  await chmod(wrapper, 0o755);
  await chmod(targetCli, 0o644);

  process.stdout.write(`Prepared CLI bundle resources:\n- ${wrapper}\n- ${targetCli}\n`);
}

void main().catch((err) => {
  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`Failed to prepare CLI resources: ${message}\n`);
  process.exit(1);
});
