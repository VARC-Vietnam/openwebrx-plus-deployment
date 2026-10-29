#!/usr/bin/env bash
# Apply device presets into live OpenWebRX+ settings.json (full sdrs replace).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

if [[ ! -f "$ROOT/.env" ]]; then
  echo "Missing .env — run ./install.sh first."
  exit 1
fi
# shellcheck disable=SC1091
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

DEVICE="${OWRX_DEVICE:-rtl_sdr}"
PRESET="${ROOT}/presets/${DEVICE}/sdrs.json"
VAR_DIR="${OWRX_DATA_DIR}/var"

if [[ ! -f "$PRESET" ]]; then
  echo "Preset not found: ${PRESET}"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

# Data dir is often root/container-owned after first start
sudo mkdir -p "${OWRX_DATA_DIR}/presets" "$VAR_DIR"
sudo cp "$PRESET" "${OWRX_DATA_DIR}/presets/sdrs.${DEVICE}.json"
sudo cp "$PRESET" "${OWRX_DATA_DIR}/presets/sdrs.json"
sudo chown -R "${USER}:${USER}" "${OWRX_DATA_DIR}/presets" 2>/dev/null || true

DOCKER=""
COMPOSE=""
WAS_RUNNING=false
if DOCKER="$(resolve_docker 2>/dev/null)"; then
  COMPOSE="$(resolve_compose "$DOCKER" 2>/dev/null || true)"
  if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "${OWRX_CONTAINER_NAME}"; then
    WAS_RUNNING=true
    echo "Stopping ${OWRX_CONTAINER_NAME} to rewrite settings..."
    $DOCKER stop "${OWRX_CONTAINER_NAME}" >/dev/null
  fi
fi

echo "Applying preset → ${VAR_DIR}/settings.json"
# apply-presets.py uses sudo tee if the file is not writable
python3 "$ROOT/scripts/apply-presets.py" --var-dir "$VAR_DIR" --preset "$PRESET"

if [[ -d "${OWRX_DATA_DIR}/etc" ]]; then
  python3 "$ROOT/scripts/apply-presets.py" --var-dir "${OWRX_DATA_DIR}/etc" --preset "$PRESET" 2>/dev/null || true
fi

if [[ "$WAS_RUNNING" == true && -n "$DOCKER" ]]; then
  echo "Starting ${OWRX_CONTAINER_NAME}..."
  if [[ -n "$COMPOSE" && -f "$ROOT/docker-compose.yml" ]]; then
    $COMPOSE up -d --quiet-pull >/dev/null
  else
    $DOCKER start "${OWRX_CONTAINER_NAME}" >/dev/null
  fi
fi

echo "Done — HAMVN + HF + ISS profiles loaded; Airspy/SDRPlay removed."
