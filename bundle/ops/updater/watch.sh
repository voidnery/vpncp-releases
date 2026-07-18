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
#
# Progress is reported back to the panel by writing state.json into the SAME
# shared volume; the api serves it at GET /updates/progress and the UI animates
# the real phases (pull per service, recreate, done/failed) instead of guessing
# on a timer. A failed pull therefore shows the operator WHY it failed.
#
# Two traps this script is written to avoid:
#   1. `docker compose up -d` recreates EVERY service — including this sidecar,
#      which would kill the very shell running the update. We therefore recreate
#      every service EXCEPT ourselves.
#   2. The api container is recreated mid-update, so it cannot be the thing that
#      records progress. The state file lives in the shared volume and survives.
# =============================================================================
set -u

TRIGGER_DIR=/run/vpncp-update
TRIGGER="$TRIGGER_DIR/trigger"
STATE="$TRIGGER_DIR/state.json"
LOG="$TRIGGER_DIR/last-update.log"
DIR="${VPNCP_PROJECT_DIR:-/compose}"
FILE="${VPNCP_COMPOSE_FILE:-docker-compose.dist.yml}"
SELF_SERVICE="${VPNCP_UPDATER_SERVICE:-updater}"

mkdir -p "$TRIGGER_DIR" 2>/dev/null || true
chmod 0777 "$TRIGGER_DIR" 2>/dev/null || true

# --- state helpers ----------------------------------------------------------
json_escape() {
  # Control characters (newlines/tabs from docker output) become spaces rather
  # than vanishing, so words in an error message stay separated.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\000-\037' ' '
}

# write_state <phase> <done> <total> <detail> [error]
write_state() {
  _phase="$1"; _done="$2"; _total="$3"; _detail="$(json_escape "$4")"; _err="$(json_escape "${5:-}")"
  _ts="$(date +%s)"
  {
    printf '{"phase":"%s","done":%s,"total":%s,"detail":"%s","updatedAt":%s' \
      "$_phase" "$_done" "$_total" "$_detail" "$_ts"
    [ -n "$_err" ] && printf ',"error":"%s"' "$_err"
    printf '}\n'
  } > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null
  chmod 0666 "$STATE" 2>/dev/null || true
}

cd "$DIR" || { echo "[updater] FATAL: project dir $DIR not mounted"; exit 1; }

if ! docker compose version >/dev/null 2>&1; then
  echo "[updater] compose plugin missing — attempting install"
  apk add --no-cache docker-cli-compose >/dev/null 2>&1 || \
    echo "[updater] WARN: could not install compose plugin; updates will fail"
fi

PROJECT="$(docker inspect "$(hostname)" \
  --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
if [ -n "$PROJECT" ]; then PROJ="-p $PROJECT"; else PROJ=""; fi

echo "[updater] watching $TRIGGER (dir=$DIR file=$FILE project=${PROJECT:-<default>})"

# --- the update itself ------------------------------------------------------
run_update() {
  : > "$LOG"

  # Every service except ourselves. Recreating the updater would kill this shell
  # mid-update (trap #1 above), so it is deliberately excluded and keeps running
  # the OLD image until the operator recreates it by hand.
  SERVICES="$(docker compose $PROJ -f "$FILE" config --services 2>>"$LOG" \
    | grep -v "^${SELF_SERVICE}$" | tr '\n' ' ')"
  if [ -z "$SERVICES" ]; then
    write_state failed 0 0 "" "could not read service list from $FILE"
    echo "[updater] FAILED: empty service list"
    return 1
  fi

  TOTAL=0
  for s in $SERVICES; do TOTAL=$((TOTAL + 1)); done

  # Pull one service at a time so the reported percentage is real, not a guess.
  DONE=0
  write_state pulling "$DONE" "$TOTAL" ""
  for s in $SERVICES; do
    write_state pulling "$DONE" "$TOTAL" "$s"
    if ! docker compose $PROJ -f "$FILE" pull "$s" >>"$LOG" 2>&1; then
      ERR="$(tail -n 3 "$LOG" 2>/dev/null | tr '\n' ' ')"
      write_state failed "$DONE" "$TOTAL" "$s" "pull failed: $ERR"
      echo "[updater] FAILED pulling $s"
      return 1
    fi
    DONE=$((DONE + 1))
    write_state pulling "$DONE" "$TOTAL" "$s"
  done

  # Recreate everything but ourselves. The api goes down here, which is why the
  # UI must tolerate connection loss from this point on.
  write_state recreating "$TOTAL" "$TOTAL" ""
  # shellcheck disable=SC2086
  if ! docker compose $PROJ -f "$FILE" up -d $SERVICES >>"$LOG" 2>&1; then
    ERR="$(tail -n 3 "$LOG" 2>/dev/null | tr '\n' ' ')"
    write_state failed "$TOTAL" "$TOTAL" "" "recreate failed: $ERR"
    echo "[updater] FAILED recreating"
    return 1
  fi

  write_state applied "$TOTAL" "$TOTAL" ""
  echo "[updater] update applied"
  return 0
}

LAST=""
[ -f "$TRIGGER" ] && LAST="$(cat "$TRIGGER" 2>/dev/null || echo seed)"

while true; do
  if [ -f "$TRIGGER" ]; then
    NOW="$(cat "$TRIGGER" 2>/dev/null || echo x)"
    if [ "$NOW" != "$LAST" ]; then
      LAST="$NOW"
      echo "[updater] trigger=$NOW — pull + recreate"
      run_update || true
    fi
  fi
  sleep 3
done
