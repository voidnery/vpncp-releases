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
 *   { channel, version, releasedAt, images:{api,web}, minUpgradeFrom, changelog }
 */
import { readFileSync } from "node:fs";

function arg(name, def = "") {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : def;
}

const version = arg("version");
const channel = arg("channel", "stable");
const registry = arg("registry", "ghcr.io/voidnery").replace(/\/+$/, "");
const minUpgradeFrom = arg("min-upgrade-from", "0.0.0");
const changelogPath = arg("changelog");

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
};

process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
