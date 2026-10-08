#!/usr/bin/env bash
# =============================================================================
# VPN Control Plane — end-user installer (distribution).
#
# Run from inside an extracted release bundle (the dir containing
# docker-compose.dist.yml, .env.example and ops/). Requires only Docker +
# Docker Compose v2 on a fresh host. Generates secrets, prompts for the few
# values it can't invent, pulls the pinned images and starts the stack.
#
#   curl -fsSL https://get.docker.com | sudo sh        # if Docker is missing
#   ./quick-install.sh
#
# Non-interactive: pre-set any of PUBLIC_DOMAIN, LETSENCRYPT_EMAIL,
# BOOTSTRAP_ADMIN_PASSWORD, VPNCP_LICENSE, VPNCP_VERSION, VPNCP_REGISTRY in the
# environment and the matching prompt is skipped.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
COMPOSE_FILE="docker-compose.dist.yml"
ENV_FILE=".env"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
blu()  { printf '\033[34m%s\033[0m\n' "$*"; }

# --- preflight ---
command -v docker >/dev/null 2>&1 || { red "Docker not found. Install: curl -fsSL https://get.docker.com | sudo sh"; exit 1; }
docker compose version >/dev/null 2>&1 || { red "Docker Compose v2 required ('docker compose')."; exit 1; }
command -v openssl >/dev/null 2>&1 || { red "openssl is required to generate secrets."; exit 1; }
[ -f "$COMPOSE_FILE" ] || { red "Run this from the release bundle (missing $COMPOSE_FILE)."; exit 1; }
[ -f ".env.example" ] || { red "Missing .env.example in bundle."; exit 1; }

# --- url-encode helper (for passwords inside connection URIs) ---
urlenc() { python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1" 2>/dev/null \
  || printf '%s' "$1"; }

setval() { # setval KEY VALUE  — replace or append KEY=VALUE in .env
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENV_FILE"; then
    # use | delimiter; escape | and & in value
    local esc=${v//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
    sed -i.bak "s|^${k}=.*|${k}=${esc}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}
getval() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

# --- .env bootstrap ---
if [ ! -f "$ENV_FILE" ]; then
  blu "Creating .env from .env.example"
  cp .env.example "$ENV_FILE"
fi

blu "Generating secrets…"
gen_b64() { openssl rand -base64 "${1:-32}" | tr -d '\n'; }
gen_pwd() { openssl rand -base64 24 | tr -d '\n=+/' | cut -c1-32; }

# Only fill placeholders, keep any existing real values (idempotent re-runs).
fill() { local k="$1" v="$2"; case "$(getval "$k")" in CHANGE_ME*|""|*example.com*) setval "$k" "$v";; esac; }
fill MASTER_KEY         "$(gen_b64 32)"
fill JWT_ACCESS_SECRET  "$(gen_b64 48)"
fill JWT_REFRESH_SECRET "$(gen_b64 48)"
fill COOKIE_SECRET      "$(gen_b64 32)"
fill ENROLLMENT_SECRET  "$(gen_b64 32)"
fill BACKUP_PASSPHRASE  "$(gen_b64 24)"
case "$(getval MONGO_PASS)" in CHANGE_ME*|"") setval MONGO_PASS "$(gen_pwd)";; esac
case "$(getval REDIS_PASS)" in CHANGE_ME*|"") setval REDIS_PASS "$(gen_pwd)";; esac

# Rebuild connection URIs from the (possibly new) credentials.
MU=$(getval MONGO_USER); MP=$(getval MONGO_PASS); MD=$(getval MONGO_DB); RP=$(getval REDIS_PASS)
setval MONGO_URI "mongodb://${MU}:$(urlenc "$MP")@mongo:27017/${MD}?authSource=admin"
setval REDIS_URL "redis://default:$(urlenc "$RP")@redis:6379"

# --- prompts for values we cannot invent ---
ask() { # ask VAR "Prompt" [silent]
  local var="$1" prompt="$2" silent="${3:-}" cur="${!var:-}"
  if [ -n "$cur" ]; then setval "$var" "$cur"; return; fi
  local existing; existing="$(getval "$var")"
  case "$existing" in CHANGE_ME*|""|*example.com*) ;; *) return;; esac  # already set
  local ans
  if [ "$silent" = "silent" ]; then read -rsp "$prompt: " ans; echo; else read -rp "$prompt: " ans; fi
  [ -n "$ans" ] && setval "$var" "$ans"
}

blu ""
ylw "A few values are required:"
ask PUBLIC_DOMAIN          "Panel domain (e.g. panel.example.com)"
DOMAIN="$(getval PUBLIC_DOMAIN)"
setval PUBLIC_API_URL      "https://${DOMAIN}"
setval ALLOWED_ORIGINS     "https://${DOMAIN}"
ask LETSENCRYPT_EMAIL      "Email for Let's Encrypt"
ask BOOTSTRAP_ADMIN_PASSWORD "First admin password" silent
ask VPNCP_LICENSE          "License token (optional, Enter to skip free mode)"
[ -n "${VPNCP_VERSION:-}" ]  && setval VPNCP_VERSION  "$VPNCP_VERSION"
[ -n "${VPNCP_REGISTRY:-}" ] && setval VPNCP_REGISTRY "$VPNCP_REGISTRY"

# --- validate required ---
for v in PUBLIC_DOMAIN LETSENCRYPT_EMAIL BOOTSTRAP_ADMIN_PASSWORD; do
  case "$(getval "$v")" in CHANGE_ME*|""|*example.com*) red "Missing required value: $v"; exit 1;; esac
done
chmod 600 "$ENV_FILE" || true

# --- pull + start ---
blu ""
blu "Pulling images…"
docker compose -f "$COMPOSE_FILE" pull
blu "Starting datastore…"
docker compose -f "$COMPOSE_FILE" up -d mongo redis
sleep 5
blu "Starting panel…"
docker compose -f "$COMPOSE_FILE" up -d api web nginx

grn ""
grn "Done. Panel starting for https://${DOMAIN}"
ylw "Next:"
ylw "  1. Point DNS A/AAAA for ${DOMAIN} at this server."
ylw "  2. Obtain TLS cert (Let's Encrypt webroot), then: docker compose -f ${COMPOSE_FILE} restart nginx"
ylw "  3. Log in as admin and (optionally) install your license on the License page."
