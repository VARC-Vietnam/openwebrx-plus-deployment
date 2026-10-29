#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
cd "$ROOT"

if [[ ! -f docker-compose.yml || ! -f .env ]]; then
  echo "Missing docker-compose.yml or .env — run ./install.sh first."
  exit 1
fi

# shellcheck disable=SC1091
source .env

DOCKER="$(resolve_docker)" || { echo "Docker daemon not reachable."; exit 1; }
COMPOSE="$(resolve_compose "$DOCKER")" || { echo "Docker Compose not found."; exit 1; }

echo "=== Compose ==="
$COMPOSE ps
echo
echo "=== Config ==="
echo "  Image:    ${OWRX_IMAGE}"
echo "  Device:   ${OWRX_DEVICE}"
echo "  Port:     ${OWRX_PORT}"
echo "  Data:     ${OWRX_DATA_DIR}"
echo "  rtl_tcp:  ${ENABLE_RTL_TCP:-false}"
echo
echo "=== USB (host) ==="
"$ROOT/scripts/detect-usb.sh" || true
