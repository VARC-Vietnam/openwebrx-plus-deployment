#!/usr/bin/env bash
# Apply device presets into live OpenWebRX+ settings.json
# and strip Airspy HF+ / SDRPlay defaults.
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

mkdir -p "${OWRX_DATA_DIR}/presets" "$VAR_DIR"
cp "$PRESET" "${OWRX_DATA_DIR}/presets/sdrs.${DEVICE}.json"
cp "$PRESET" "${OWRX_DATA_DIR}/presets/sdrs.json"

python3 "$ROOT/scripts/apply-presets.py" --var-dir "$VAR_DIR" --preset "$PRESET"

# Also scrub /etc/openwebrx if a settings copy exists there
if [[ -d "${OWRX_DATA_DIR}/etc" ]]; then
  python3 "$ROOT/scripts/apply-presets.py" --var-dir "${OWRX_DATA_DIR}/etc" --preset "$PRESET" 2>/dev/null || true
fi

# Restart so OWRX reloads devices (if stack is up)
if DOCKER="$(resolve_docker 2>/dev/null)"; then
  if COMPOSE="$(resolve_compose "$DOCKER" 2>/dev/null)" && [[ -f "$ROOT/docker-compose.yml" ]]; then
    $COMPOSE up -d --quiet-pull >/dev/null 2>&1 || true
    $DOCKER restart "${OWRX_CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
fi

echo "Done. Airspy/SDRPlay removed; only ${DEVICE} presets kept."
