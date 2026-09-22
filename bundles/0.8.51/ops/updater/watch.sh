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
DIR="${VPNCP_PROJECT_DIR:-/compose}"   # must match the host path (see compose)
FILE="${VPNCP_COMPOSE_FILE:-docker-compose.dist.yml}"
SELF_SERVICE="${VPNCP_UPDATER_SERVICE:-updater}"
REQUEST="$TRIGGER_DIR/request.json"
INCIDENTS="$TRIGGER_DIR/incidents.log"
RELEASES_BASE="${VPNCP_RELEASES_BASE_URL:-https://raw.githubusercontent.com/voidnery/vpncp-releases/main}"

# The ONLY on-host files an update may overwrite. Enforced HERE, not taken from
# the manifest or from the api: this sidecar is root-capable, so it must not let
# a tampered manifest or a compromised api choose which paths to write.
# Mirrors SYNCABLE_DEPLOY_FILES in packages/shared/src/updates.ts.
# `.env` is deliberately absent — it holds secrets and belongs to the operator.
ALLOWED_FILES="docker-compose.dist.yml ops/updater/watch.sh"

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

# HTTPS is required to read release manifests. busybox wget delegates TLS to
# ssl_client, which fails with a bare "ssl_client: SSL_connect" when the CA
# bundle is missing — exactly what silently disabled deploy-file sync on a live
# install. curl gives real error messages, so prefer it and fall back to wget.
if ! command -v curl >/dev/null 2>&1; then
  apk add --no-cache curl ca-certificates >/dev/null 2>&1 || \
    apk add --no-cache ca-certificates >/dev/null 2>&1 || \
    echo "[updater] WARN: could not install curl/ca-certificates"
fi

# fetch_url <url> <dest> -> 0 on success. Writes the real error to $LOG.
fetch_url() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 60 "$1" -o "$2" 2>>"$LOG"
  else
    wget -q -T 60 -O "$2" "$1" 2>>"$LOG"
  fi
}

# Self-test so a broken TLS stack is visible in the log at startup instead of
# only when an update silently skips its sync.
if fetch_url "${VPNCP_RELEASES_BASE_URL:-https://raw.githubusercontent.com/voidnery/vpncp-releases/main}/stable.json" /tmp/.tlscheck 2>/dev/null; then
  echo "[updater] HTTPS to the release repo OK"
  rm -f /tmp/.tlscheck
else
  echo "[updater] WARN: cannot reach the release repo over HTTPS — deploy-file sync will be skipped"
fi

PROJECT="$(docker inspect "$(hostname)" \
  --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
if [ -n "$PROJECT" ]; then PROJ="-p $PROJECT"; else PROJ=""; fi

echo "[updater] watching $TRIGGER (dir=$DIR file=$FILE project=${PROJECT:-<default>})"

# --- deploy-file sync -------------------------------------------------------
# Keeps the compose file and this script in step with the release, so upgrading
# an install never again requires hand-copying files over SSH.
#
# Trust model: the version comes from the api (sanitised there, re-sanitised
# here), but the manifest, the hashes and the download URLs are resolved by THIS
# script from its own configured base URL. Every file is verified against the
# sha256 in the manifest before it is allowed anywhere near the project dir.
is_allowed() {
  case " $ALLOWED_FILES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

sync_deploy_files() {
  _version="$1"
  [ -n "$_version" ] || return 0

  _mf="$TRIGGER_DIR/manifest.json"
  if ! fetch_url "$RELEASES_BASE/versions/$_version.json" "$_mf"; then
    # Not fatal (images can still be pulled), but it must never be silent again:
    # a failing fetch here is what stopped compose/watch.sh updates from ever
    # reaching a live install.
    echo "[updater] WARN: could not fetch manifest for $_version — deploy files NOT synced"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') sync skipped: manifest fetch failed for $_version" >> "$INCIDENTS"
    return 0
  fi

  # Extract path/sha pairs without a JSON parser (busybox shell only).
  _pairs="$(tr -d ' \n' < "$_mf" \
    | grep -o '"path":"[^"]*","sha256":"[0-9a-f]*"' \
    | sed -e 's/"path":"//' -e 's/","sha256":"/ /' -e 's/"$//')"
  [ -n "$_pairs" ] || { echo "[updater] manifest has no deploy files — skipping sync"; return 0; }

  _changed=""
  echo "$_pairs" | while read -r _path _sha; do
    [ -n "$_path" ] || continue
    if ! is_allowed "$_path"; then
      echo "[updater] REFUSED non-allowlisted deploy path: $_path"
      continue
    fi
    # Already identical? Nothing to do.
    if [ -f "$DIR/$_path" ] && [ "$(sha256sum "$DIR/$_path" | cut -d" " -f1)" = "$_sha" ]; then
      continue
    fi
    _tmp="$TRIGGER_DIR/dl.tmp"
    # Prefer the immutable per-version copy: `bundle/` is overwritten by every
    # release, so it matches only the newest one and its bytes will not match an
    # older manifest's hash. Fall back to bundle/ for releases cut before
    # bundles/<version>/ existed.
    if ! fetch_url "$RELEASES_BASE/bundles/$_version/$_path" "$_tmp"; then
      if ! fetch_url "$RELEASES_BASE/bundle/$_path" "$_tmp"; then
        echo "[updater] WARN: could not download $_path — keeping current file"
        continue
      fi
    fi
    _got="$(sha256sum "$_tmp" | cut -d" " -f1)"
    if [ "$_got" != "$_sha" ]; then
      echo "[updater] REFUSED $_path: sha256 mismatch (want $_sha got $_got)"
      rm -f "$_tmp"
      continue
    fi
    mkdir -p "$DIR/$(dirname "$_path")" 2>/dev/null || true
    # Keep one backup so a bad deploy file can be restored by hand.
    [ -f "$DIR/$_path" ] && cp -f "$DIR/$_path" "$DIR/$_path.bak" 2>/dev/null || true
    if cp -f "$_tmp" "$DIR/$_path" 2>>"$LOG"; then
      echo "[updater] synced $_path"
      echo "$_path" >> "$TRIGGER_DIR/.changed"
    else
      echo "[updater] WARN: project dir not writable — cannot sync $_path"
    fi
    rm -f "$_tmp"
  done
  return 0
}

# --- version pinning --------------------------------------------------------
# The manifest names an EXACT image (…/vpncp-api:0.4.7), but the compose file
# defaults to the floating :stable tag. Pulling :stable is not the same thing as
# pulling what the panel showed the operator: if the tag lags, the update
# "succeeds" while nothing actually changes, and the panel keeps offering the
# same release forever. Pinning makes an update deterministic, and makes rollback
# a one-line edit of .env.
#
# .env holds secrets and belongs to the operator, so exactly ONE key is touched
# and the file is rewritten in place (not replaced) to preserve its ownership and
# permissions. The version was already sanitised by the api and again below.
pin_version() {
  _v="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  [ -n "$_v" ] || return 0
  # Only ever pin something that looks like a real release (1.2.3 / 1.2.3-beta.1).
  # Stripping dangerous characters is not enough on its own: the leftovers would
  # be written as a version that simply cannot be pulled, breaking every future
  # update until someone edits .env by hand.
  if ! printf '%s' "$_v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.]+)?$'; then
    echo "[updater] REFUSED to pin implausible version: $_v"
    return 0
  fi
  _env="$DIR/.env"
  if [ ! -f "$_env" ]; then
    echo "[updater] no .env in $DIR — cannot pin version, using the floating tag"
    return 0
  fi
  _cur="$(grep '^VPNCP_VERSION=' "$_env" 2>/dev/null | head -1 | cut -d= -f2-)"
  [ "$_cur" = "$_v" ] && return 0

  _tmp="$TRIGGER_DIR/env.tmp"
  if [ -n "$_cur" ]; then
    sed "s|^VPNCP_VERSION=.*|VPNCP_VERSION=$_v|" "$_env" > "$_tmp" 2>>"$LOG" || return 0
  else
    { cat "$_env"; echo "VPNCP_VERSION=$_v"; } > "$_tmp" 2>>"$LOG" || return 0
  fi
  # Truncate-and-write keeps the original inode, owner and mode.
  if cat "$_tmp" > "$_env" 2>>"$LOG"; then
    echo "[updater] pinned VPNCP_VERSION=$_v (was ${_cur:-unset})"
  else
    echo "[updater] WARN: .env not writable — keeping the floating tag"
  fi
  rm -f "$_tmp"
}

# --- the update itself ------------------------------------------------------
# Refuses to run when the project directory is not visible at its real host path.
#
# compose resolves relative bind sources against the CALLER's working directory.
# If ours differs from the host's, Docker invents empty directories for every
# relative mount — which is how an update once left nginx with no config and no
# listening socket. Better to skip the update loudly than to break the panel.
paths_sane() {
  [ -f "$DIR/$FILE" ] || { echo "[updater] FATAL: $DIR/$FILE not visible"; return 1; }
  # A relative bind source that must exist for nginx to serve anything.
  if grep -q "ops/nginx/conf.d" "$DIR/$FILE" 2>/dev/null && [ ! -d "$DIR/ops/nginx/conf.d" ]; then
    echo "[updater] FATAL: $DIR/ops/nginx/conf.d missing — relative mounts would resolve to empty dirs"
    return 1
  fi
  case "$DIR" in
    /compose) echo "[updater] FATAL: project mounted at /compose; set VPNCP_COMPOSE_DIR to the host path"; return 1 ;;
  esac
  return 0
}

run_update() {
  : > "$LOG"
  if ! paths_sane; then
    write_state failed 0 0 "" "updater is misconfigured: project directory not visible at its host path — see docs/SELF-UPDATE.md"
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') update refused: project path mismatch ($DIR)" >> "$INCIDENTS"
    return 1
  fi
  rm -f "$TRIGGER_DIR/.changed"

  # Sync deploy files FIRST, so the pull/recreate below already uses the compose
  # file that ships with the target release.
  _req_version=""
  if [ -f "$REQUEST" ]; then
    _req_version="$(tr -d ' \n' < "$REQUEST" | grep -o '"version":"[^"]*"' | sed -e 's/"version":"//' -e 's/"$//')"
    _req_version="$(printf '%s' "$_req_version" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)"
  fi
  write_state syncing 0 0 "$_req_version"
  sync_deploy_files "$_req_version"
  # Pin BEFORE pulling, so pull/recreate fetch exactly the target release.
  pin_version "$_req_version"

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

  # Every release leaves the previous layers behind; on a small VPS that grows
  # without bound. Dangling (untagged) images only — never `prune -a`, which
  # would delete the previous release image and destroy the rollback path.
  docker image prune -f >>"$LOG" 2>&1 || true

  write_state applied "$TOTAL" "$TOTAL" ""
  echo "[updater] update applied"

  # If this very script was updated, the running process is still the OLD code
  # (the file is mounted, not reloaded). Restarting ourselves is safe only now:
  # the update is finished and the state file already says so. This command kills
  # our own container, so nothing may follow it.
  if [ -f "$TRIGGER_DIR/.changed" ] && grep -q "ops/updater/watch.sh" "$TRIGGER_DIR/.changed" 2>/dev/null; then
    echo "[updater] watch.sh changed — restarting self to pick it up"
    rm -f "$TRIGGER_DIR/.changed"
    docker restart "$(hostname)" >/dev/null 2>&1 &
  fi
  return 0
}

# --- watchdog ---------------------------------------------------------------
# Why this exists: on 2026-07-19 the nginx container died after a successful
# update and did NOT come back, despite `restart: unless-stopped`. The panel was
# simply unreachable until a human noticed and ran `up -d`. Nothing watched it.
#
# This restarts any project container that is not running. Two deliberate rules:
#   * only NOT-RUNNING containers are touched — never "unhealthy" ones. Restarting
#     on health alone risks a restart loop that turns a degraded panel into a
#     dead one.
#   * containers whose restart policy is "no" are skipped, because they are meant
#     to exit (certbot runs and finishes; restarting it forever would be wrong).
#
# Before restarting, the dead container's exit code / OOM flag are recorded. That
# is what was missing during the incident: recreating the container destroyed the
# only evidence of why it died.
watchdog_tick() {
  [ -n "$PROJECT" ] || return 0
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.ID}} {{.Label "com.docker.compose.service"}} {{.State}}' 2>/dev/null \
  | while read -r _cid _svc _state; do
      [ -n "$_svc" ] || continue
      [ "$_svc" = "$SELF_SERVICE" ] && continue
      [ "$_state" = "running" ] && continue
      [ "$_state" = "restarting" ] && continue
      _pol="$(docker inspect "$_cid" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)"
      case "$_pol" in "" | no) continue ;; esac

      _post="$(docker inspect "$_cid" \
        --format 'exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err="{{.State.Error}}" finished={{.State.FinishedAt}}' 2>/dev/null)"
      _now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      echo "[watchdog] $_now $_svc was '$_state' ($_post) — restarting" | tee -a "$INCIDENTS"
      if docker compose $PROJ -f "$FILE" up -d --no-deps "$_svc" >>"$INCIDENTS" 2>&1; then
        echo "[watchdog] $_svc restarted" | tee -a "$INCIDENTS"
      else
        echo "[watchdog] FAILED to restart $_svc" | tee -a "$INCIDENTS"
      fi
    done
}

LAST=""
[ -f "$TRIGGER" ] && LAST="$(cat "$TRIGGER" 2>/dev/null || echo seed)"
TICK=0

while true; do
  if [ -f "$TRIGGER" ]; then
    NOW="$(cat "$TRIGGER" 2>/dev/null || echo x)"
    if [ "$NOW" != "$LAST" ]; then
      LAST="$NOW"
      echo "[updater] trigger=$NOW — pull + recreate"
      run_update || true
    fi
  fi
  # Watchdog every ~60s (20 ticks x 3s). Skipped implicitly while an update runs,
  # because run_update blocks this same loop.
  TICK=$((TICK + 1))
  if [ "$((TICK % 20))" = "0" ]; then
    watchdog_tick
  fi
  sleep 3
done
