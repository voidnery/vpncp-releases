#!/bin/sh
# =============================================================================
# sync-cert.sh — copy the DSM-managed certificate for the panel domain into the
# panel's bind-mounted cert folder (./ops/synology/certs) and reload nginx.
#
# The Synology edition serves an operator-provided cert (no certinit). DSM
# issues/renews Let's Encrypt into its own archive only, so run this once after
# issuing and on a schedule (DSM Task Scheduler, weekly, as root) to track renewals.
#
# Usage:  sudo sh sync-cert.sh <domain> [project-dir]
#   e.g.  sudo sh sync-cert.sh vpnc.denello.ru /volume2/web/vpnc
# =============================================================================
set -eu

DOMAIN="${1:?usage: sync-cert.sh <domain> [project-dir]}"
PROJECT_DIR="${2:-/volume2/web/vpnc}"
CERT_DIR="$PROJECT_DIR/ops/synology/certs"

# 1) Find the DSM archive folder whose certificate matches the domain.
ARCH=""
for d in /usr/syno/etc/certificate/_archive/*/; do
  [ -f "$d/cert.pem" ] || continue
  if openssl x509 -in "$d/cert.pem" -noout -text 2>/dev/null | grep -qF "$DOMAIN"; then
    ARCH="$d"; break
  fi
done
[ -n "$ARCH" ] || { echo "ERROR: no DSM certificate found for $DOMAIN"; exit 1; }
echo "DSM cert source: $ARCH"

# 2) Copy fullchain + privkey into the bind-mounted cert folder.
mkdir -p "$CERT_DIR"
if [ -f "$ARCH/fullchain.pem" ]; then
  cp "$ARCH/fullchain.pem" "$CERT_DIR/fullchain.pem"
else
  cat "$ARCH/cert.pem" "$ARCH/chain.pem" > "$CERT_DIR/fullchain.pem"
fi
cp "$ARCH/privkey.pem" "$CERT_DIR/privkey.pem"
chmod 600 "$CERT_DIR/privkey.pem"
echo "cert files written to: $CERT_DIR"

# 3) Reload the panel nginx so it picks up the new cert.
if [ -f "$PROJECT_DIR/docker-compose.yml" ]; then
  (cd "$PROJECT_DIR" && docker compose restart nginx)
else
  docker restart "$(docker ps -q --filter name=nginx | head -n1)"
fi
echo "OK: panel certificate updated for $DOMAIN"
