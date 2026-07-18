#!/usr/bin/env bash
# =============================================================================
# Enables in-panel self-update on an EXISTING install — run once, on the host.
#
#   ./scripts/enable-self-update.sh            # interactive (shows a diff first)
#   ./scripts/enable-self-update.sh --yes      # no prompt (for automation)
#
# Why this exists at all, and why it cannot be done from the panel:
#   Enabling self-update means granting a container access to the Docker socket,
#   i.e. root on this host. Nothing already running inside Docker may hand itself
#   that privilege — if the panel could, a compromised panel could root the host.
#   So exactly one deliberate act by someone with host access is required. After
#   this, the updater keeps the deploy files in sync with every release on its
#   own; this script is never needed again.
#
# What it does: downloads the deploy files for the release you run, verifies each
# against the sha256 in that release's manifest, backs up what you have, shows a
# diff, and recreates the stack. Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

FILE="${VPNCP_COMPOSE_FILE:-docker-compose.dist.yml}"
BASE="${VPNCP_RELEASES_BASE_URL:-https://raw.githubusercontent.com/voidnery/vpncp-releases/main}"
ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

c_blue()  { printf '\033[1;34m%s\033[0m\n' "$1"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$1"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$1"; }
c_yell()  { printf '\033[1;33m%s\033[0m\n' "$1"; }

need() { command -v "$1" >/dev/null 2>&1 || { c_red "missing required tool: $1"; exit 1; }; }
need curl; need sha256sum; need docker

[ -f "$FILE" ] || { c_red "$FILE not found — run this from your install folder (e.g. /opt/vpncp)."; exit 1; }

c_blue "=== Enable in-panel self-update ==="
echo

# --- 1. Which version is this install running? -------------------------------
# Ask the running api rather than guessing, so the deploy files match the images.
VERSION="$(docker compose -f "$FILE" exec -T api sh -c 'echo "$APP_VERSION"' 2>/dev/null | tr -cd 'A-Za-z0-9._-' || true)"
if [ -z "$VERSION" ]; then
  c_yell "Could not read APP_VERSION from the running api; falling back to the stable channel."
  VERSION="$(curl -fsSL --max-time 20 "$BASE/stable.json" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
fi
[ -n "$VERSION" ] || { c_red "Could not determine a release version. Is the panel running?"; exit 1; }
c_blue "Target release: $VERSION"

MANIFEST="$(curl -fsSL --max-time 20 "$BASE/versions/$VERSION.json")" || {
  c_red "No manifest for $VERSION at $BASE/versions/$VERSION.json"; exit 1; }

# --- 2. Fetch + verify each deploy file --------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PAIRS="$(printf '%s' "$MANIFEST" | tr -d ' \n' \
  | grep -o '"path":"[^"]*","sha256":"[0-9a-f]*"' \
  | sed -e 's/"path":"//' -e 's/","sha256":"/ /' -e 's/"$//')"

if [ -z "$PAIRS" ]; then
  c_red "Release $VERSION predates deploy-file sync (no 'deploy' section in its manifest)."
  c_yell "Cut a newer release first, then re-run this script."
  exit 1
fi

CHANGED=0
while read -r path sha; do
  [ -n "$path" ] || continue
  case "$path" in
    docker-compose.dist.yml|ops/updater/watch.sh) ;;
    *) c_yell "skipping unexpected path in manifest: $path"; continue ;;
  esac
  mkdir -p "$TMP/$(dirname "$path")"
  curl -fsSL --max-time 60 "$BASE/bundle/$path" -o "$TMP/$path" || { c_red "download failed: $path"; exit 1; }
  got="$(sha256sum "$TMP/$path" | cut -d' ' -f1)"
  [ "$got" = "$sha" ] || { c_red "checksum mismatch for $path (want $sha, got $got) — aborting."; exit 1; }
  if [ -f "$path" ] && cmp -s "$TMP/$path" "$path"; then
    echo "  = $path (already current)"
  else
    echo "  + $path (will be updated)"
    CHANGED=1
  fi
done <<EOF
$PAIRS
EOF

if [ "$CHANGED" = "0" ]; then
  c_green "Deploy files are already up to date."
else
  echo
  c_blue "--- changes to be applied ---"
  while read -r path sha; do
    [ -n "$path" ] || continue
    [ -f "$path" ] && diff -u "$path" "$TMP/$path" || true
  done <<EOF
$PAIRS
EOF
  echo
  c_yell "Review the diff above. Local edits (ports, domains, extra services) will be LOST"
  c_yell "unless you re-apply them afterwards. Backups are written as <file>.bak."
  if [ "$ASSUME_YES" = "0" ]; then
    printf 'Apply and recreate the stack? [y/N] '
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) c_yell "Aborted. Nothing was changed."; exit 0 ;; esac
  fi
  while read -r path sha; do
    [ -n "$path" ] || continue
    mkdir -p "$(dirname "$path")"
    [ -f "$path" ] && cp -f "$path" "$path.bak"
    cp -f "$TMP/$path" "$path"
  done <<EOF
$PAIRS
EOF
  c_green "Deploy files updated (backups: *.bak)."
fi

# --- 3. Recreate so the api picks up VPNCP_UPDATE_COMMAND --------------------
c_blue ""
c_blue "Recreating the stack…"
docker compose -f "$FILE" up -d

# --- 4. Verify the thing we actually care about ------------------------------
sleep 3
CMD="$(docker compose -f "$FILE" exec -T api sh -c 'echo "$VPNCP_UPDATE_COMMAND"' 2>/dev/null | tr -d '\r' || true)"
echo
if [ -n "$CMD" ]; then
  c_green "Self-update is ENABLED (api sees: $CMD)"
  c_green "The panel now shows 'Обновить сейчас' whenever a newer release exists."
  c_green "From here on, deploy files update themselves with each release."
else
  c_red "VPNCP_UPDATE_COMMAND is still empty in the api container."
  c_yell "Try: docker compose -f $FILE up -d --force-recreate api"
  c_yell "Then re-run ./scripts/check-self-update.sh"
  exit 1
fi
