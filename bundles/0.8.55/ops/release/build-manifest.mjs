#!/usr/bin/env node
/*
 * Build a release channel manifest (consumed later by the in-panel Updates page).
 *
 *   node ops/release/build-manifest.mjs \
 *     --version 0.1.0 --channel stable \
 *     --registry ghcr.io/voidnery \
 *     --changelog /tmp/changelog.md \
 *     --min-upgrade-from 0.0.0 > stable.json
 *
 * Output shape:
 *   { channel, version, releasedAt, images:{api,web}, minUpgradeFrom, changelog,
 *     deploy:{ files:[{path,sha256}] } }
 *
 * `deploy` lets an installed panel keep its ON-HOST deploy files (compose file,
 * updater script) in sync with the release automatically. Hashes are computed
 * from the repo copies that are published to bundle/ in the same run, so the
 * updater can verify what it downloads.
 */
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

function arg(name, def = "") {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : def;
}

const version = arg("version");
const channel = arg("channel", "stable");
const registry = arg("registry", "ghcr.io/voidnery").replace(/\/+$/, "");
const minUpgradeFrom = arg("min-upgrade-from", "0.0.0");
const changelogPath = arg("changelog");
// Repo root the deploy files are read from (defaults to cwd = repo checkout).
const deployRoot = arg("deploy-root", ".").replace(/\/+$/, "");

// Kept in step with SYNCABLE_DEPLOY_FILES in packages/shared/src/updates.ts.
// The updater enforces its own copy of this list regardless of what we emit.
const DEPLOY_FILES = ["docker-compose.dist.yml", "ops/updater/watch.sh"];

if (!version) {
  console.error("error: --version is required");
  process.exit(1);
}

let changelog = "";
if (changelogPath) {
  try {
    changelog = readFileSync(changelogPath, "utf-8").trim();
  } catch {
    changelog = "";
  }
}

const deployFiles = [];
for (const rel of DEPLOY_FILES) {
  try {
    const buf = readFileSync(`${deployRoot}/${rel}`);
    deployFiles.push({ path: rel, sha256: createHash("sha256").update(buf).digest("hex") });
  } catch {
    console.error(`warn: deploy file missing, skipping: ${rel}`);
  }
}

const manifest = {
  channel,
  version,
  releasedAt: new Date().toISOString(),
  images: {
    api: `${registry}/vpncp-api:${version}`,
    web: `${registry}/vpncp-web:${version}`,
  },
  minUpgradeFrom,
  changelog,
  ...(deployFiles.length > 0 ? { deploy: { files: deployFiles } } : {}),
};

process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
