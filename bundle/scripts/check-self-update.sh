#!/usr/bin/env bash
# =============================================================================
# Diagnoses why in-panel self-update is (not) available on this host.
# Read-only: inspects containers and files, changes nothing.
#
# Usage:  ./scripts/check-self-update.sh [compose-file]
# =============================================================================
set -uo pipefail

FILE="${1:-docker-compose.dist.yml}"
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[1;34m·\033[0m %s\n' "$1"; }

echo "=== NET-Control self-update diagnostics ==="
echo "compose file: $FILE  (cwd: $(pwd))"
echo

echo "1. Compose file on THIS host"
if [ ! -f "$FILE" ]; then
  bad "$FILE not found — run this from your install folder (e.g. /opt/vpncp)"
  exit 1
fi
grep -q "VPNCP_UPDATE_COMMAND" "$FILE" \
  && ok "VPNCP_UPDATE_COMMAND present in the file" \
  || bad "VPNCP_UPDATE_COMMAND MISSING — this compose file predates the sidecar"
grep -q "^  updater:" "$FILE" \
  && ok "updater service defined" \
  || bad "updater service MISSING from the file"
[ -f ops/updater/watch.sh ] \
  && ok "ops/updater/watch.sh present" \
  || bad "ops/updater/watch.sh MISSING — the sidecar has no script to run"
echo

echo "2. What the RUNNING api container actually sees"
# This is the decisive check: the panel enables the button purely on this env.
CMD="$(docker compose -f "$FILE" exec -T api sh -c 'echo "$VPNCP_UPDATE_COMMAND"' 2>/dev/null | tr -d '\r')"
if [ -n "$CMD" ]; then
  ok "VPNCP_UPDATE_COMMAND = $CMD"
else
  bad "VPNCP_UPDATE_COMMAND is EMPTY in the running container"
  info "The file may be fixed but the container was never recreated:"
  info "  docker compose -f $FILE up -d api"
fi
echo

echo "3. Updater sidecar"
if docker compose -f "$FILE" ps updater 2>/dev/null | grep -qi "up\|running"; then
  ok "updater container is running"
  info "recent log:"
  docker compose -f "$FILE" logs --tail=10 updater 2>/dev/null | sed 's/^/      /'
else
  bad "updater container is NOT running"
fi
echo

echo "4. Shared trigger volume + last reported state"
docker compose -f "$FILE" exec -T api sh -c 'ls -la /run/vpncp-update 2>/dev/null' 2>/dev/null | sed 's/^/      /' \
  || bad "api cannot see /run/vpncp-update (volume not mounted)"
STATE="$(docker compose -f "$FILE" exec -T api sh -c 'cat /run/vpncp-update/state.json 2>/dev/null' 2>/dev/null)"
[ -n "$STATE" ] && { ok "state.json:"; echo "      $STATE"; } || info "no state.json yet (no update has run through the sidecar)"
echo

echo "=== Verdict ==="
if [ -n "$CMD" ]; then
  echo "Self-update is ENABLED. The panel should show the 'Обновить сейчас' button."
else
  echo "Self-update is DISABLED — the panel will keep offering the manual command."
  echo "See docs/SELF-UPDATE.md → 'Enabling it on an existing install'."
fi
