#!/bin/sh
# =============================================================================
# NET-Control sidecar updater.
#
# Watches a trigger file written by the (unprivileged) api container and, when
# it changes, pulls the new images and recreates the stack via the host Docker
# socket. This keeps the api container WITHOUT Docker access — only this tiny
# sidecar is privileged.
#
# The api writes the trigger via VPNCP_UPDATE_COMMAND (set in compose):
#   date +%s > /run/vpncp-update/trigger
# The panel's UpdateProgress UI then polls /updates/status until the new
# version is live and reloads — the in-panel animated update flow.
# =============================================================================
set -u

TRIGGER_DIR=/run/vpncp-update
TRIGGER="$TRIGGER_DIR/trigger"
DIR="${VPNCP_PROJECT_DIR:-/compose}"
FILE="${VPNCP_COMPOSE_FILE:-docker-compose.dist.yml}"

# Make the shared trigger dir writable by the non-root api (uid 1000).
mkdir -p "$TRIGGER_DIR" 2>/dev/null || true
chmod 0777 "$TRIGGER_DIR" 2>/dev/null || true

cd "$DIR" || { echo "[updater] FATAL: project dir $DIR not mounted"; exit 1; }

# Ensure the compose plugin is available (most docker:*-cli tags bundle it).
if ! docker compose version >/dev/null 2>&1; then
  echo "[updater] compose plugin missing — attempting install"
  apk add --no-cache docker-cli-compose >/dev/null 2>&1 || \
    echo "[updater] WARN: could not install compose plugin; updates will fail"
fi

# Detect the real compose project name from our own container labels, so the
# recreate targets the SAME project regardless of the host folder name.
PROJECT="$(docker inspect "$(hostname)" \
  --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
if [ -n "$PROJECT" ]; then PROJ="-p $PROJECT"; else PROJ=""; fi

echo "[updater] watching $TRIGGER (dir=$DIR file=$FILE project=${PROJECT:-<default>})"

LAST=""
# Seed LAST with the current trigger so we don't fire on a stale file at boot.
[ -f "$TRIGGER" ] && LAST="$(cat "$TRIGGER" 2>/dev/null || echo seed)"

while true; do
  if [ -f "$TRIGGER" ]; then
    NOW="$(cat "$TRIGGER" 2>/dev/null || echo x)"
    if [ "$NOW" != "$LAST" ]; then
      LAST="$NOW"
      echo "[updater] trigger=$NOW — docker compose pull + up -d"
      if docker compose $PROJ -f "$FILE" pull && docker compose $PROJ -f "$FILE" up -d; then
        echo "[updater] update applied"
      else
        echo "[updater] update FAILED — see output above"
      fi
    fi
  fi
  sleep 3
done
