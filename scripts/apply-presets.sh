#!/usr/bin/env bash
# Apply device presets into live OpenWebRX+ settings.json (full sdrs replace).
# Interactively checkbox-select which profiles to enable unless --all is passed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
quiet_interrupt_trap

SELECT_ALL=false
if [[ "${1:-}" == "--all" ]]; then
  SELECT_ALL=true
fi

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
PRESET_FULL="${ROOT}/presets/${DEVICE}/sdrs.json"
BACKGROUND="${ROOT}/presets/${DEVICE}/background.json"
VAR_DIR="${OWRX_DATA_DIR}/var"
FILTERED="$(mktemp)"
SELECTED_IDS="$(mktemp)"
trap 'rm -f "$FILTERED" "$SELECTED_IDS"' EXIT

if [[ ! -f "$PRESET_FULL" ]]; then
  echo "Preset not found: ${PRESET_FULL}"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

INITIAL_ARGS=()
PREV_SELECTED="${OWRX_DATA_DIR}/presets/SELECTED_PROFILES.txt"
PREV_JSON="${OWRX_DATA_DIR}/presets/sdrs.selected.json"
if [[ -f "$PREV_SELECTED" ]]; then
  INITIAL_ARGS=(--initial-selected "$PREV_SELECTED")
elif [[ -f "$PREV_JSON" ]]; then
  INITIAL_ARGS=(--initial-selected "$PREV_JSON")
fi

if [[ "$SELECT_ALL" == true ]]; then
  python3 "$ROOT/scripts/select-profiles.py" \
    --preset "$PRESET_FULL" \
    --output "$FILTERED" \
    --selected-file "$SELECTED_IDS" \
    --noninteractive
else
  python3 "$ROOT/scripts/select-profiles.py" \
    --preset "$PRESET_FULL" \
    --output "$FILTERED" \
    --selected-file "$SELECTED_IDS" \
    "${INITIAL_ARGS[@]}"
fi

if [[ "${RTL_TCP_CLIENT:-false}" == true && -n "${RTL_TCP_REMOTE:-}" ]]; then
  PATCHED="$(mktemp)"
  python3 "$ROOT/scripts/patch-rtl-tcp-preset.py" \
    --input "$FILTERED" \
    --output "$PATCHED" \
    --remote "$RTL_TCP_REMOTE"
  mv "$PATCHED" "$FILTERED"
  echo "Using rtl_tcp client → ${RTL_TCP_REMOTE}"
fi

# Data dir is often root/container-owned after first start
sudo mkdir -p "${OWRX_DATA_DIR}/presets" "$VAR_DIR"
sudo cp "$PRESET_FULL" "${OWRX_DATA_DIR}/presets/sdrs.${DEVICE}.json"
sudo cp "$FILTERED" "${OWRX_DATA_DIR}/presets/sdrs.json"
sudo cp "$FILTERED" "${OWRX_DATA_DIR}/presets/sdrs.selected.json"
sudo cp "$SELECTED_IDS" "${OWRX_DATA_DIR}/presets/SELECTED_PROFILES.txt"
sudo chown -R "${USER}:${USER}" "${OWRX_DATA_DIR}/presets" 2>/dev/null || true

# Cache sudo so resolve_docker can use "sudo docker" without a hidden prompt
if ! sudo -n true 2>/dev/null; then
  sudo -v </dev/tty >/dev/tty 2>/dev/tty || { echo "sudo authentication failed"; exit 1; }
fi

DOCKER=""
COMPOSE=""
if ! DOCKER="$(resolve_docker)"; then
  echo "Docker not reachable (try: sudo systemctl start docker)"
  exit 1
fi
COMPOSE="$(resolve_compose "$DOCKER" || true)"

if $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "${OWRX_CONTAINER_NAME}"; then
  echo "Stopping ${OWRX_CONTAINER_NAME} for settings reload..."
  $DOCKER stop "${OWRX_CONTAINER_NAME}" >/dev/null
fi

echo "Applying selected profiles → ${VAR_DIR}/settings.json"
BG_ARGS=()
if [[ -f "$BACKGROUND" ]]; then
  BG_ARGS=(--background "$BACKGROUND")
fi
python3 "$ROOT/scripts/apply-presets.py" \
  --var-dir "$VAR_DIR" \
  --preset "$FILTERED" \
  "${BG_ARGS[@]}"

if [[ -d "${OWRX_DATA_DIR}/etc" ]]; then
  python3 "$ROOT/scripts/apply-presets.py" \
    --var-dir "${OWRX_DATA_DIR}/etc" \
    --preset "$FILTERED" \
    "${BG_ARGS[@]}" 2>/dev/null || true
fi

echo "Reloading container..."
if [[ -n "$COMPOSE" && -f "$ROOT/docker-compose.yml" ]]; then
  $COMPOSE up -d --force-recreate --quiet-pull >/dev/null
elif $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${OWRX_CONTAINER_NAME}"; then
  $DOCKER restart "${OWRX_CONTAINER_NAME}" >/dev/null
else
  echo "Container ${OWRX_CONTAINER_NAME} not found — start with ./scripts/start.sh"
  exit 1
fi

echo "Done — profiles applied and container reloaded."
