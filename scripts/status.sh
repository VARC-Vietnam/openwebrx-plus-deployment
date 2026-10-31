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
echo "  USB bind: ${BIND_USB:-true}"
if [[ "${RTL_TCP_MANAGED:-false}" == true || "${RTL_TCP_CLIENT:-false}" == true ]]; then
  echo "  rtl_tcp:  ${RTL_TCP_REMOTE:-?}  managed=${RTL_TCP_MANAGED:-false}"
elif [[ "${ENABLE_RTL_TCP:-false}" == true ]]; then
  echo "  rtl_tcp:  publish ${FORWARD_LOCALPORT_INTERNAL:-?}→${FORWARD_RTL_TCP_EXTERNAL:-?}"
else
  echo "  rtl_tcp:  off"
fi
if [[ "${RTL_TCP_MANAGED:-false}" == true ]]; then
  echo
  echo "=== owrx-rtl-tcp (host) ==="
  systemctl is-active owrx-rtl-tcp 2>/dev/null || echo "  (inactive / not installed)"
  systemctl status owrx-rtl-tcp --no-pager -l 2>/dev/null | head -12 || true
fi
echo
echo "=== USB (host) ==="
"$ROOT/scripts/detect-usb.sh" || true
