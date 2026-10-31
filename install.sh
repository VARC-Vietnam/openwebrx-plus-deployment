#!/usr/bin/env bash
# Interactive installer for OpenWebRX+ (slechev/openwebrxplus) with USB SDR binding.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

# ---------- helpers ----------
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[0;33m'
CYN=$'\033[0;36m'
BLD=$'\033[1m'
RST=$'\033[0m'

info()  { printf '%s%s%s\n' "$CYN" "$*" "$RST"; }
ok()    { printf '%s%s%s\n' "$GRN" "$*" "$RST"; }
warn()  { printf '%s%s%s\n' "$YLW" "$*" "$RST"; }
err()   { printf '%s%s%s\n' "$RED" "$*" "$RST" >&2; }
bold()  { printf '%s%s%s\n' "$BLD" "$*" "$RST"; }

# Clear screen and show only the current installer step.
step() {
  local num="$1" title="$2"
  clear 2>/dev/null || printf '\033c'
  bold "=============================================="
  bold "  OpenWebRX+  —  Step ${num}: ${title}"
  bold "=============================================="
  echo
}

prompt() {
  # prompt VAR "Question" "default"
  local __var="$1" __q="$2" __def="${3-}" __ans
  if [[ -n "$__def" ]]; then
    read -r -p "$__q [$__def]: " __ans || true
    __ans="${__ans:-$__def}"
  else
    read -r -p "$__q: " __ans || true
  fi
  printf -v "$__var" '%s' "$__ans"
}

prompt_secret() {
  local __var="$1" __q="$2" __def="${3-}" __ans
  if [[ -n "$__def" ]]; then
    read -r -s -p "$__q [$__def]: " __ans || true
    echo
    __ans="${__ans:-$__def}"
  else
    read -r -s -p "$__q: " __ans || true
    echo
  fi
  printf -v "$__var" '%s' "$__ans"
}

confirm() {
  local __q="$1" __def="${2:-y}" __ans
  read -r -p "$__q [${__def}/$([ "$__def" = y ] && echo n || echo y)]: " __ans || true
  __ans="${__ans:-$__def}"
  [[ "$__ans" =~ ^[Yy]$ ]]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command not found: $1"
    return 1
  }
}

# ---------- quiet Ctrl+C / progress ----------
SPIN_PID=""
on_interrupt() {
  spin_clear 2>/dev/null || true
  printf '\033[?25h' 2>/dev/null || true
  echo
  warn "Cancelled."
  exit 130
}
trap on_interrupt INT
trap 'spin_clear' EXIT

spin_start() {
  local msg="$1"
  # Keep one updating line; hide cursor while spinning
  printf '\033[?25l' 2>/dev/null || true
  (
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while true; do
      printf '\r%s%s %s%s' "$CYN" "${frames:i++%10:1}" "$msg" "$RST"
      sleep 0.08
    done
  ) &
  SPIN_PID=$!
  disown "$SPIN_PID" 2>/dev/null || true
}

spin_clear() {
  if [[ -n "${SPIN_PID:-}" ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
  fi
  printf '\r\033[K\033[?25h' 2>/dev/null || true
}

# Ask for sudo on a clean line (never while the spinner is running).
ensure_sudo() {
  spin_clear
  if sudo -n true 2>/dev/null; then
    return 0
  fi
  printf '\n'
  info "Administrator password required for the next steps."
  # Prompt on the real TTY so it never shares a line with the spinner / redirected logs
  if ! sudo -v </dev/tty >/dev/tty 2>/dev/tty; then
    err "sudo authentication failed"
    return 1
  fi
  ok "sudo authenticated"
  printf '\n'
}

# run_quiet "Working on X..." "X done" -- cmd args...
# Captures cmd output; on failure shows last ~12 lines only.
# Callers that need sudo must run ensure_sudo first (never prompt under the spinner).
run_quiet() {
  local msg="$1" done_msg="$2"
  shift 2
  local log rc=0
  log="$(mktemp)"
  spin_start "$msg"
  set +e
  "$@" >"$log" 2>&1
  rc=$?
  set -e
  spin_clear
  if [[ $rc -eq 0 ]]; then
    ok "$done_msg"
    rm -f "$log"
    return 0
  fi
  err "$msg — failed"
  if [[ -s "$log" ]]; then
    err "----"
    tail -n 12 "$log" | sed 's/^/  /' >&2 || true
    err "----"
  fi
  rm -f "$log"
  return "$rc"
}

apt_update_quiet() {
  ensure_sudo || return 1
  run_quiet "Updating apt indexes" "Apt indexes updated" \
    sudo apt-get update -qq
}

apt_install_quiet() {
  local pkgs=("$@")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  ensure_sudo || return 1
  run_quiet "Installing ${pkgs[*]}" "Installed ${pkgs[*]}" \
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      -o Dpkg::Use-Pty=0 \
      -o APT::Color=0 \
      "${pkgs[@]}"
}

detect_debian_tz() {
  if [[ -f /etc/timezone ]]; then
    tr -d '[:space:]' </etc/timezone
  elif [[ -L /etc/localtime ]]; then
    readlink /etc/localtime | sed 's|.*/zoneinfo/||'
  else
    echo "UTC"
  fi
}

is_debian_like() {
  [[ -f /etc/debian_version ]] || grep -qiE 'debian|ubuntu' /etc/os-release 2>/dev/null
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

pkg_available() {
  # Returns 0 if apt knows a candidate version for the package
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

ensure_debian_packages() {
  local pkgs=("$@") missing=() unavailable=()
  local p
  for p in "${pkgs[@]}"; do
    if pkg_installed "$p"; then
      continue
    fi
    if pkg_available "$p"; then
      missing+=("$p")
    else
      unavailable+=("$p")
    fi
  done
  if [[ ${#unavailable[@]} -gt 0 ]]; then
    warn "Skip (not in apt): ${unavailable[*]}"
  fi
  if [[ ${#missing[@]} -eq 0 ]]; then
    [[ ${#unavailable[@]} -eq 0 ]]
    return $?
  fi
  if confirm "Install missing packages (${missing[*]})?" y; then
    apt_update_quiet
    apt_install_quiet "${missing[@]}"
  else
    err "Install manually: sudo apt-get install -y ${missing[*]}"
    return 1
  fi
}

install_docker_debian() {
  # Debian Trixie: docker.io + docker-compose (Compose v2)
  # Note: docker-compose-v2 / docker-compose-plugin are NOT in Trixie apt.
  ensure_sudo || return 1
  apt_update_quiet

  if ! command -v docker >/dev/null 2>&1; then
    if pkg_available docker.io; then
      apt_install_quiet docker.io
    else
      err "Package docker.io is not available. Enable the main apt suite or install Docker CE."
      return 1
    fi
  fi
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker engine install failed (docker binary still missing)."
    return 1
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    local compose_pkg=""
    for compose_pkg in docker-compose docker-compose-v2 docker-compose-plugin; do
      if pkg_available "$compose_pkg"; then
        apt_install_quiet "$compose_pkg"
        break
      fi
    done
  fi

  if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    err "Docker Compose not found after install."
    err "On Debian Trixie: sudo apt-get install -y docker.io docker-compose"
    return 1
  fi

  ensure_sudo || return 1
  run_quiet "Enabling docker service" "Docker service running" \
    sudo systemctl enable --now docker
  ok "Docker ready."
}

resolve_docker() {
  if docker info >/dev/null 2>&1; then
    echo "docker"
  elif sudo docker info >/dev/null 2>&1; then
    echo "sudo docker"
  else
    return 1
  fi
}

resolve_compose() {
  # Prefer "docker compose" (v2 plugin); fall back to docker-compose binary.
  local docker_bin="${1:-docker}"
  if $docker_bin compose version >/dev/null 2>&1; then
    echo "$docker_bin compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    if [[ "$docker_bin" == "sudo docker" ]]; then
      echo "sudo docker-compose"
    else
      echo "docker-compose"
    fi
  else
    return 1
  fi
}

container_running() {
  local name="$1"
  command -v docker >/dev/null 2>&1 || return 1
  if docker info >/dev/null 2>&1; then
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
  else
    return 1
  fi
}

container_exists() {
  local name="$1"
  command -v docker >/dev/null 2>&1 || return 1
  if docker info >/dev/null 2>&1; then
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
  else
    return 1
  fi
}

detect_existing_install() {
  # Sets globals: EXISTING=true/false, EXISTING_* summary fields
  EXISTING=false
  EXISTING_REASONS=()
  if [[ -f "$ROOT/.env" ]]; then
    EXISTING=true
    EXISTING_REASONS+=(".env present")
  fi
  if [[ -f "$ROOT/docker-compose.yml" ]]; then
    EXISTING=true
    EXISTING_REASONS+=("docker-compose.yml present")
  fi
  if [[ -f "$ROOT/.env" ]]; then
    # shellcheck disable=SC1091
    set -a
    # shellcheck disable=SC1091
    source "$ROOT/.env"
    set +a
  fi
  local cname="${OWRX_CONTAINER_NAME:-openwebrxplus}"
  local ddir="${OWRX_DATA_DIR:-/opt/owrx-docker}"
  if [[ -d "$ddir/var" ]] || [[ -d "$ddir/etc" ]]; then
    EXISTING=true
    EXISTING_REASONS+=("data dir ${ddir}")
  fi
  if container_running "$cname"; then
    EXISTING=true
    EXISTING_REASONS+=("container ${cname} running")
  elif container_exists "$cname"; then
    EXISTING=true
    EXISTING_REASONS+=("container ${cname} exists (stopped)")
  fi
  if [[ -f /etc/modprobe.d/owrx-blacklist.conf ]]; then
    EXISTING_REASONS+=("host blacklist installed")
  fi
  if [[ -f /etc/udev/rules.d/99-sdr-devices.rules ]]; then
    EXISTING_REASONS+=("host udev rules installed")
  fi
}

# ---------- main menu ----------
INSTALL_MODE=""   # configure | keep | profiles | services
# CLI shortcuts skip the interactive menu
if [[ "${1:-}" == "--profiles" || "${1:-}" == "-p" ]]; then
  INSTALL_MODE="profiles"
elif [[ "${1:-}" == "--services" || "${1:-}" == "-s" ]]; then
  INSTALL_MODE="services"
elif [[ "${1:-}" == "--configure" || "${1:-}" == "-c" ]]; then
  INSTALL_MODE="configure"
elif [[ "${1:-}" == "--restart" || "${1:-}" == "-r" ]]; then
  INSTALL_MODE="keep"
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<EOF
Usage: ./install.sh [option]

  (no args)       Interactive main menu
  --configure,-c  Fresh install / reconfigure
  --restart,-r    Pull latest image & restart existing instance
  --profiles,-p   Select active profiles
  --services,-s   Select background decoding mode
EOF
  exit 0
fi

detect_existing_install

# Prefer existing .env values as defaults for re-runs / reconfigure
if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

if [[ -z "$INSTALL_MODE" ]]; then
  step "0" "OpenWebRX+ deployment"
  info "Repo: ${ROOT}"
  echo
  if [[ "$EXISTING" == true ]]; then
    info "Detected existing install:"
    for r in "${EXISTING_REASONS[@]}"; do
      echo "  • $r"
    done
    echo
    if [[ -f "$ROOT/.env" ]]; then
      echo "  Container:  ${OWRX_CONTAINER_NAME:-openwebrxplus}"
      echo "  Device:     ${OWRX_DEVICE:-unknown}"
      echo "  Image:      ${OWRX_IMAGE:-unknown}"
      echo "  Port:       ${OWRX_PORT:-8073}"
      echo "  Data:       ${OWRX_DATA_DIR:-/opt/owrx-docker}"
      echo "  Admin:      ${OPENWEBRX_ADMIN_USER:-admin}"
      echo
    fi
  else
    info "No existing install detected — choose (1) for a fresh setup."
    echo
  fi
  echo "  1) Configure new OpenWebRX+ instance (fresh install / reconfigure)"
  echo "  2) Restart using existing OpenWebRX instance (pull latest version)"
  echo "  3) Select active profiles"
  echo "  4) Select background decoding mode"
  echo "  5) Abort"
  MENU_DEFAULT="1"
  [[ "$EXISTING" == true ]] && MENU_DEFAULT="3"
  MENU_CHOICE=""
  while [[ -z "$MENU_CHOICE" ]]; do
    prompt MENU_CHOICE "Choose [1-5]" "$MENU_DEFAULT"
    case "$MENU_CHOICE" in
      1) INSTALL_MODE="configure" ;;
      2) INSTALL_MODE="keep" ;;
      3) INSTALL_MODE="profiles" ;;
      4) INSTALL_MODE="services" ;;
      5) warn "Aborted."; exit 0 ;;
      *) MENU_CHOICE=""; warn "Invalid choice." ;;
    esac
  done
fi

# ---------- background decoder selection (checkbox UI) ----------
# Sets: SELECTED_BACKGROUND_JSON SELECTED_SERVICES_FILE
#        ENABLE_MQTT ENABLE_SONDEHUB SONDEHUB_CALLSIGN SCHEDULE_TO_SONDE
SELECTED_BACKGROUND_JSON=""
SELECTED_SERVICES_FILE=""
ENABLE_MQTT="${ENABLE_MQTT:-false}"
ENABLE_SONDEHUB="${ENABLE_SONDEHUB:-false}"
SONDEHUB_CALLSIGN="${SONDEHUB_CALLSIGN:-}"
SCHEDULE_TO_SONDE=false

run_select_background_services() {
  local data_dir="${1:-${OWRX_DATA_DIR:-/opt/owrx-docker}}"
  local catalog="${ROOT}/presets/services.json"
  SELECTED_BACKGROUND_JSON="$(mktemp)"
  SELECTED_SERVICES_FILE="$(mktemp)"

  if [[ ! -f "$catalog" ]]; then
    err "Services catalog missing: ${catalog}"
    return 1
  fi

  local initial_args=()
  local prev="${data_dir}/presets/SELECTED_SERVICES.txt"
  local prev_bg="${data_dir}/presets/background.json"
  if [[ -f "$prev" ]]; then
    initial_args=(--initial-selected "$prev")
  elif [[ -f "$prev_bg" ]]; then
    initial_args=(--initial-selected "$prev_bg")
  fi

  info "MQTT is optional (publish/receive spots). Background Sonde needs services_decoders + 403 MHz schedule."
  echo
  sleep 0.3

  python3 "$ROOT/scripts/select-services.py" \
    --catalog "$catalog" \
    --output "$SELECTED_BACKGROUND_JSON" \
    --selected-file "$SELECTED_SERVICES_FILE" \
    "${initial_args[@]}"

  ENABLE_MQTT="${ENABLE_MQTT:-false}"
  ENABLE_SONDEHUB="${ENABLE_SONDEHUB:-false}"
  SCHEDULE_TO_SONDE=false
  SONDEHUB_CALLSIGN="${SONDEHUB_CALLSIGN:-${OPENWEBRX_ADMIN_USER:-}}"

  if grep -qE '^sonde-' "$SELECTED_SERVICES_FILE" 2>/dev/null; then
    echo
    info "Sonde decoder(s) selected."
    if confirm "Set idle schedule to Sonde RS41 403 (instead of FT8 20m)?" y; then
      SCHEDULE_TO_SONDE=true
    fi
    if confirm "Enable SondeHub telemetry upload?" y; then
      ENABLE_SONDEHUB=true
      prompt SONDEHUB_CALLSIGN "SondeHub callsign / uploader id" "${SONDEHUB_CALLSIGN:-N0CALL}"
    fi
    if confirm "Run local MQTT broker (Mosquitto) for sonde/report pub-sub?" n; then
      ENABLE_MQTT=true
    fi
  elif confirm "Run local MQTT broker (Mosquitto) anyway?" n; then
    ENABLE_MQTT=true
  fi
}

apply_schedule_to_sonde() {
  local preset_file="$1"
  [[ -f "$preset_file" ]] || return 0
  python3 - "$preset_file" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
changed = False
for device in data.values():
    if not isinstance(device, dict):
        continue
    profiles = device.get("profiles") or {}
    if "sonde_rs41_403" not in profiles:
        print("warn: profile sonde_rs41_403 not in selection — schedule unchanged", file=sys.stderr)
        continue
    device["always-on"] = True
    device["services"] = True
    device["scheduler"] = {
        "type": "static",
        "schedule": {"0001-2359": "sonde_rs41_403"},
    }
    changed = True
if changed:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print("schedule: idle profile → sonde_rs41_403")
PY
}

apply_reporting_settings() {
  local var_dir="$1"
  local etc_dir="$2"
  local patch
  patch="$(mktemp)"
  python3 - "$patch" "$ENABLE_MQTT" "$ENABLE_SONDEHUB" "$SONDEHUB_CALLSIGN" <<'PY'
import json, sys
from pathlib import Path
out, enable_mqtt, enable_sondehub, callsign = sys.argv[1:5]
patch = {}
if enable_mqtt == "true":
    patch.update({
        "mqtt_enabled": True,
        "mqtt_host": "mosquitto",
        "mqtt_use_ssl": False,
        "mqtt_topic": "openwebrx",
        "mqtt_sonde": True,
        "mqtt_wsjt": True,
        "mqtt_aprs": True,
        "mqtt_meshtastic": True,
        "report_clients": False,
        "report_radio": True,
    })
if enable_sondehub == "true":
    patch.update({
        "sondehub_enabled": True,
        "sondehub_callsign": callsign or "N0CALL",
    })
Path(out).write_text(json.dumps(patch, indent=2) + "\n", encoding="utf-8")
print("reporting patch keys:", ", ".join(sorted(patch.keys())) or "(none)")
PY
  if [[ -s "$patch" ]] && grep -q '[^[:space:]{}]' "$patch"; then
    python3 "$ROOT/scripts/apply-settings-keys.py" --var-dir "$var_dir" --patch "$patch" || true
  fi
  rm -f "$patch"

  if [[ -f "${SELECTED_SERVICES_FILE:-}" ]] && grep -qE '^sonde-' "$SELECTED_SERVICES_FILE"; then
    local modes
    modes="$(grep -E '^sonde-' "$SELECTED_SERVICES_FILE" | paste -sd, -)"
    python3 "$ROOT/scripts/ensure-sonde-bandplan.py" \
      --etc-dir "$etc_dir" \
      --modes "$modes" || true
  fi
}

# ---------- profiles-only fast path (option 3 / --profiles) ----------
run_profiles_only() {
  if [[ ! -f "$ROOT/.env" ]]; then
    err "No .env — run a full install first (./install.sh)."
    return 1
  fi
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a

  local device="${OWRX_DEVICE:-rtl_sdr}"
  local preset_full="${ROOT}/presets/${device}/sdrs.json"
  local background="${ROOT}/presets/${device}/background.json"
  local var_dir="${OWRX_DATA_DIR}/var"
  local filtered selected_ids
  filtered="$(mktemp)"
  selected_ids="$(mktemp)"

  if [[ ! -f "$preset_full" ]]; then
    err "Preset not found: ${preset_full}"
    rm -f "$filtered" "$selected_ids"
    return 1
  fi

  step "1/3" "Select profiles"
  info "Device: ${device}   Data: ${OWRX_DATA_DIR}"
  echo
  sleep 0.3

  local initial_args=()
  local prev="${OWRX_DATA_DIR}/presets/SELECTED_PROFILES.txt"
  local prev_json="${OWRX_DATA_DIR}/presets/sdrs.selected.json"
  if [[ -f "$prev" ]]; then
    initial_args=(--initial-selected "$prev")
  elif [[ -f "$prev_json" ]]; then
    initial_args=(--initial-selected "$prev_json")
  fi

  python3 "$ROOT/scripts/select-profiles.py" \
    --preset "$preset_full" \
    --output "$filtered" \
    --selected-file "$selected_ids" \
    "${initial_args[@]}"

  if [[ "${RTL_TCP_CLIENT:-false}" == true && -n "${RTL_TCP_REMOTE:-}" ]]; then
    patched="$(mktemp)"
    python3 "$ROOT/scripts/patch-rtl-tcp-preset.py" \
      --input "$filtered" \
      --output "$patched" \
      --remote "$RTL_TCP_REMOTE"
    mv "$patched" "$filtered"
    ok "Profiles use rtl_tcp → ${RTL_TCP_REMOTE}"
  fi

  step "2/3" "Select background decoders"
  run_select_background_services "${OWRX_DATA_DIR}"
  background="${SELECTED_BACKGROUND_JSON}"

  if [[ "$SCHEDULE_TO_SONDE" == true ]]; then
    apply_schedule_to_sonde "$filtered"
  fi

  step "3/3" "Apply profiles + services"
  sudo mkdir -p "${OWRX_DATA_DIR}/presets" "$var_dir" "${OWRX_DATA_DIR}/etc"
  sudo cp "$preset_full" "${OWRX_DATA_DIR}/presets/sdrs.${device}.json"
  sudo cp "$filtered" "${OWRX_DATA_DIR}/presets/sdrs.json"
  sudo cp "$filtered" "${OWRX_DATA_DIR}/presets/sdrs.selected.json"
  sudo cp "$selected_ids" "${OWRX_DATA_DIR}/presets/SELECTED_PROFILES.txt"
  sudo cp "$background" "${OWRX_DATA_DIR}/presets/background.json"
  sudo cp "$SELECTED_SERVICES_FILE" "${OWRX_DATA_DIR}/presets/SELECTED_SERVICES.txt"
  sudo chown -R "${USER}:${USER}" "${OWRX_DATA_DIR}/presets" 2>/dev/null || true

  # Persist MQTT flag into .env for compose regeneration on next full install
  if [[ -f "$ROOT/.env" ]]; then
    if grep -q '^ENABLE_MQTT=' "$ROOT/.env"; then
      sed -i.bak "s/^ENABLE_MQTT=.*/ENABLE_MQTT=${ENABLE_MQTT}/" "$ROOT/.env" && rm -f "$ROOT/.env.bak"
    else
      echo "ENABLE_MQTT=${ENABLE_MQTT}" >> "$ROOT/.env"
    fi
  fi

  # Sudo/docker auth on a clean line before stop/write/reload
  ensure_sudo || return 1

  local docker_bin="" compose_bin=""
  if ! docker_bin="$(resolve_docker)"; then
    err "Docker not reachable (is the daemon running? try: sudo systemctl start docker)"
    return 1
  fi
  compose_bin="$(resolve_compose "$docker_bin" || true)"

  # Stop first so settings.json is not overwritten while OWRX is running
  if $docker_bin ps --format '{{.Names}}' 2>/dev/null | grep -qx "${OWRX_CONTAINER_NAME}"; then
    run_quiet "Stopping ${OWRX_CONTAINER_NAME} for settings reload" "Stopped" \
      $docker_bin stop "${OWRX_CONTAINER_NAME}"
  fi

  run_quiet "Writing settings.json" "Settings updated" \
    python3 "$ROOT/scripts/apply-presets.py" \
      --var-dir "$var_dir" \
      --preset "$filtered" \
      --background "$background"

  apply_reporting_settings "$var_dir" "${OWRX_DATA_DIR}/etc"

  # Always reload container so new profiles are live
  if [[ -n "$compose_bin" && -f "$ROOT/docker-compose.yml" ]]; then
    ensure_sondehub_hotfix "$ROOT" || true
    if [[ "$ENABLE_MQTT" == true ]]; then
      # Ensure mosquitto service exists in compose (inject if missing)
      if ! grep -q 'container_name:.*mosquitto\|image: eclipse-mosquitto' "$ROOT/docker-compose.yml"; then
        warn "Mosquitto not in docker-compose.yml — re-run install option 1 (configure) to add it, or start an external broker."
      fi
      run_quiet "Reloading OpenWebRX+ (+ MQTT if configured)" "Container reloaded" \
        $compose_bin up -d --force-recreate --quiet-pull
    else
      run_quiet "Reloading OpenWebRX+ container" "Container reloaded" \
        $compose_bin up -d --force-recreate --quiet-pull
    fi
  elif $docker_bin ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${OWRX_CONTAINER_NAME}"; then
    run_quiet "Reloading ${OWRX_CONTAINER_NAME}" "Container reloaded" \
      $docker_bin restart "${OWRX_CONTAINER_NAME}"
  else
    warn "Container ${OWRX_CONTAINER_NAME} not found — start with ./scripts/start.sh"
  fi

  rm -f "$filtered" "$selected_ids" "$SELECTED_BACKGROUND_JSON" "$SELECTED_SERVICES_FILE"
  echo
  ok "Profiles + background decoders updated; container reloaded."
  info "Web UI: http://localhost:${OWRX_PORT:-8073}"
}

run_services_only() {
  if [[ ! -f "$ROOT/.env" ]]; then
    err "No .env — run a full install first (./install.sh)."
    return 1
  fi
  set -a; source "$ROOT/.env"; set +a
  local var_dir="${OWRX_DATA_DIR}/var"
  local device="${OWRX_DEVICE:-rtl_sdr}"
  local preset="${OWRX_DATA_DIR}/presets/sdrs.selected.json"
  [[ -f "$preset" ]] || preset="${ROOT}/presets/${device}/sdrs.json"

  step "1/2" "Select background decoders"
  run_select_background_services "${OWRX_DATA_DIR}"

  if [[ "$SCHEDULE_TO_SONDE" == true && -f "$preset" ]]; then
    local tmp
    tmp="$(mktemp)"
    cp "$preset" "$tmp"
    apply_schedule_to_sonde "$tmp"
    preset="$tmp"
  fi

  step "2/2" "Apply background decoding settings"
  ensure_sudo || return 1
  sudo mkdir -p "${OWRX_DATA_DIR}/presets" "${OWRX_DATA_DIR}/etc" "$var_dir"
  sudo cp "$SELECTED_BACKGROUND_JSON" "${OWRX_DATA_DIR}/presets/background.json"
  sudo cp "$SELECTED_SERVICES_FILE" "${OWRX_DATA_DIR}/presets/SELECTED_SERVICES.txt"
  sudo chown -R "${USER}:${USER}" "${OWRX_DATA_DIR}/presets" 2>/dev/null || true

  local docker_bin compose_bin=""
  docker_bin="$(resolve_docker)" || { err "Docker not reachable"; return 1; }
  compose_bin="$(resolve_compose "$docker_bin" || true)"
  if $docker_bin ps --format '{{.Names}}' 2>/dev/null | grep -qx "${OWRX_CONTAINER_NAME}"; then
    run_quiet "Stopping ${OWRX_CONTAINER_NAME}" "Stopped" $docker_bin stop "${OWRX_CONTAINER_NAME}"
  fi

  run_quiet "Writing settings.json" "Settings updated" \
    python3 "$ROOT/scripts/apply-presets.py" \
      --var-dir "$var_dir" \
      --preset "$preset" \
      --background "$SELECTED_BACKGROUND_JSON"
  apply_reporting_settings "$var_dir" "${OWRX_DATA_DIR}/etc"

  if [[ -n "$compose_bin" && -f "$ROOT/docker-compose.yml" ]]; then
    ensure_sondehub_hotfix "$ROOT" || true
    run_quiet "Reloading containers" "Reloaded" $compose_bin up -d --force-recreate --quiet-pull
  fi
  rm -f "$SELECTED_BACKGROUND_JSON" "$SELECTED_SERVICES_FILE"
  [[ -n "${tmp:-}" ]] && rm -f "$tmp"
  ok "Background decoders updated."
}

if [[ "$INSTALL_MODE" == "profiles" ]]; then
  run_profiles_only
  exit $?
fi
if [[ "$INSTALL_MODE" == "services" ]]; then
  run_services_only
  exit $?
fi

# ---------- restart / pull latest fast path ----------
if [[ "$INSTALL_MODE" == "keep" ]]; then
  step "…" "Restart existing instance — pull latest & start"
  if [[ ! -f "$ROOT/.env" || ! -f "$ROOT/docker-compose.yml" ]]; then
    err "Missing .env or docker-compose.yml — choose option 1 (configure) first."
    exit 1
  fi
  # shellcheck disable=SC1091
  set -a; source "$ROOT/.env"; set +a
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker not installed. Choose option 1 (configure) first."
    exit 1
  fi
  DOCKER="docker"
  if ! docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  fi
  if ! COMPOSE="$(resolve_compose "$DOCKER")"; then
    err "Docker Compose not found."
    exit 1
  fi
  ensure_sondehub_hotfix "$ROOT" || true
  run_quiet "Pulling ${OWRX_IMAGE}" "Image pulled" $COMPOSE pull --quiet
  run_quiet "Starting OpenWebRX+" "Container started" $COMPOSE up -d --quiet-pull
  ok "Ready → http://localhost:${OWRX_PORT:-8073}"
  exit 0
fi

# ---------- prerequisites ----------
step "1/10" "Prerequisites"
if [[ "$(uname -s)" != "Linux" ]]; then
  err "This installer targets a native Debian Linux host (USB SDR passthrough)."
  exit 1
fi
if ! is_debian_like; then
  warn "Not detecting Debian/Ubuntu (/etc/debian_version). Continuing anyway."
else
  ok "Debian-like host: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Debian}")"
fi

# Host tools used by detect/blacklist/udev steps
if is_debian_like; then
  ensure_debian_packages usbutils udev ca-certificates curl || true
fi

if ! command -v docker >/dev/null 2>&1; then
  if is_debian_like && confirm "Docker not found. Install docker.io + docker-compose via apt?" y; then
    install_docker_debian || exit 1
  else
    err "Install: sudo apt-get install -y docker.io docker-compose && sudo systemctl enable --now docker"
    exit 1
  fi
elif ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
  if is_debian_like && confirm "Docker Compose missing. Install docker-compose via apt?" y; then
    install_docker_debian || exit 1
  else
    err "Install: sudo apt-get install -y docker-compose"
    exit 1
  fi
fi

ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

# Socket permission check
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  warn "Cannot talk to Docker daemon (permission or service down)."
  if is_debian_like; then
    info "Try: sudo systemctl start docker"
    info "And: sudo usermod -aG docker $USER  (then log out/in), or re-run with sudo."
  fi
  if ! confirm "Continue with sudo docker for this install?" y; then
    exit 1
  fi
  DOCKER="sudo docker"
fi

if ! COMPOSE="$(resolve_compose "$DOCKER")"; then
  err "Docker Compose v2 is required (docker compose or docker-compose)."
  err "  sudo apt-get install -y docker-compose"
  exit 1
fi
ok "Compose OK: $($COMPOSE version 2>/dev/null | head -n1)"

# Ensure plugdev exists (udev rules reference it)
if is_debian_like && ! getent group plugdev >/dev/null; then
  sudo groupadd plugdev
fi
if is_debian_like; then
  NEED_GROUPS=()
  id -nG "$USER" | grep -qw docker || NEED_GROUPS+=(docker)
  id -nG "$USER" | grep -qw plugdev || NEED_GROUPS+=(plugdev)
  if [[ ${#NEED_GROUPS[@]} -eq 0 ]]; then
    ok "User ${USER} already in docker + plugdev"
  elif confirm "Add user $USER to groups: ${NEED_GROUPS[*]}?" y; then
    sudo usermod -aG "$(IFS=,; echo "${NEED_GROUPS[*]}")" "$USER"
    warn "Group change applies after you log out and back in."
  fi
fi
echo
read -r -p "Press Enter to continue..." _ || true

# ---------- detect devices ----------
step "2/10" "Detect plugged USB SDR devices"
if [[ -x "$ROOT/scripts/detect-usb.sh" ]]; then
  "$ROOT/scripts/detect-usb.sh" || warn "No known devices detected yet — you can still continue."
else
  warn "detect-usb.sh missing; skipping."
fi
echo
read -r -p "Press Enter to continue..." _ || true

# ---------- device selection ----------
step "3/10" "Select supported device"
echo "  1) RTL-SDR          (USB or network rtl_tcp — choose next)"
echo "  2) RX-888 / SDDC    (sddc_soapy — bind /dev/bus/usb)"
echo
DEVICE_DEFAULT="1"
[[ "${OWRX_DEVICE:-}" == "rx888" ]] && DEVICE_DEFAULT="2"
DEVICE_CHOICE=""
while [[ -z "$DEVICE_CHOICE" ]]; do
  prompt DEVICE_CHOICE "Choose device [1-2]" "$DEVICE_DEFAULT"
  case "$DEVICE_CHOICE" in
    1) OWRX_DEVICE=rtl_sdr; DEVICE_LABEL="RTL-SDR" ;;
    2) OWRX_DEVICE=rx888;   DEVICE_LABEL="RX-888" ;;
    *) DEVICE_CHOICE=""; warn "Invalid choice." ;;
  esac
done
ok "Selected: ${DEVICE_LABEL} (${OWRX_DEVICE})"
sleep 0.6

# ---------- profile checkboxes ----------
step "4/11" "Select profiles"
PRESET_FULL="${ROOT}/presets/${OWRX_DEVICE}/sdrs.json"
SELECTED_PRESET="$(mktemp)"
SELECTED_IDS_FILE="$(mktemp)"
if [[ ! -f "$PRESET_FULL" ]]; then
  err "No preset file: ${PRESET_FULL}"
  exit 1
fi
# Restore previous checks (from last install / profiles apply)
PREV_SELECTED=""
_prev_dir="${OWRX_DATA_DIR:-/opt/owrx-docker}"
if [[ -f "${_prev_dir}/presets/SELECTED_PROFILES.txt" ]]; then
  PREV_SELECTED="${_prev_dir}/presets/SELECTED_PROFILES.txt"
elif [[ -f "${_prev_dir}/presets/sdrs.selected.json" ]]; then
  PREV_SELECTED="${_prev_dir}/presets/sdrs.selected.json"
fi
INITIAL_ARGS=()
if [[ -n "$PREV_SELECTED" ]]; then
  INITIAL_ARGS=(--initial-selected "$PREV_SELECTED")
  info "Restoring previous profile checks from ${_prev_dir}/presets/"
fi
python3 "$ROOT/scripts/select-profiles.py" \
  --preset "$PRESET_FULL" \
  --output "$SELECTED_PRESET" \
  --selected-file "$SELECTED_IDS_FILE" \
  "${INITIAL_ARGS[@]}"
# select-profiles clears the screen; restore step header briefly
ok "Profile selection saved"
sleep 0.8

# ---------- background decoders ----------
step "5/12" "Background decoding services"
run_select_background_services "${OWRX_DATA_DIR:-/opt/owrx-docker}"
if [[ "$SCHEDULE_TO_SONDE" == true && -n "${SELECTED_PRESET:-}" && -f "$SELECTED_PRESET" ]]; then
  apply_schedule_to_sonde "$SELECTED_PRESET"
fi
ok "Background decoder selection saved"
sleep 0.6

# ---------- image / softmbe ----------
step "6/12" "Docker image"
echo "  1) slechev/openwebrxplus          (standard)"
echo "  2) slechev/openwebrxplus-softmbe  (includes SoftMBE digital voice)"
echo
IMAGE_DEFAULT="1"
[[ "${OWRX_IMAGE:-}" == *softmbe* ]] && IMAGE_DEFAULT="2"
IMAGE_CHOICE=""
while [[ -z "$IMAGE_CHOICE" ]]; do
  prompt IMAGE_CHOICE "Choose image [1-2]" "$IMAGE_DEFAULT"
  case "$IMAGE_CHOICE" in
    1) OWRX_IMAGE="slechev/openwebrxplus:latest" ;;
    2) OWRX_IMAGE="slechev/openwebrxplus-softmbe:latest" ;;
    *) IMAGE_CHOICE=""; warn "Invalid choice." ;;
  esac
done
ok "Image: ${OWRX_IMAGE}"
sleep 0.6

# ---------- admin / presets ----------
step "7/12" "Admin, timezone, ports, data"
DEFAULT_TZ="$(detect_debian_tz)"
prompt OWRX_CONTAINER_NAME "Container name" "${OWRX_CONTAINER_NAME:-openwebrxplus}"
prompt OWRX_PORT "Web UI host port" "${OWRX_PORT:-8073}"
prompt TZ "Timezone (IANA)" "${TZ:-$DEFAULT_TZ}"
prompt OPENWEBRX_ADMIN_USER "Admin username" "${OPENWEBRX_ADMIN_USER:-admin}"
prompt_secret OPENWEBRX_ADMIN_PASSWORD "Admin password" "${OPENWEBRX_ADMIN_PASSWORD:-changeme}"
if [[ -z "$OPENWEBRX_ADMIN_PASSWORD" ]]; then
  err "Admin password cannot be empty."
  exit 1
fi

# Official OWRX+ docs use /opt/owrx-docker on Debian servers
DEFAULT_DATA="${OWRX_DATA_DIR:-/opt/owrx-docker}"
prompt OWRX_DATA_DIR "Persistent data directory" "$DEFAULT_DATA"
# Expand ~ if present
OWRX_DATA_DIR="${OWRX_DATA_DIR/#\~/$HOME}"
# Make absolute if relative
if [[ "${OWRX_DATA_DIR}" != /* ]]; then
  OWRX_DATA_DIR="$(cd "$ROOT" && mkdir -p "$OWRX_DATA_DIR" && cd "$OWRX_DATA_DIR" && pwd)"
fi
echo

# ---------- SDR access: USB vs managed rtl_tcp ----------
ENABLE_RTL_TCP=false
RTL_TCP_CLIENT=false
RTL_TCP_MANAGED=false
RTL_TCP_REMOTE=""
RTL_TCP_REMOTE_PORT="1234"
BIND_USB=true
FORWARD_LOCALPORT_INTERNAL=""
FORWARD_RTL_TCP_EXTERNAL=""
EXTRA_PORTS=""
EXTRA_ENV=""
EXTRA_HOSTS=""
INSTALL_RTL_TCP_SVC=false

ensure_rtl_tcp_binary() {
  if command -v rtl_tcp >/dev/null 2>&1; then
    ok "rtl_tcp found: $(command -v rtl_tcp)"
    return 0
  fi
  if ! is_debian_like; then
    err "rtl_tcp not found and this is not Debian/Ubuntu — install rtl-sdr manually."
    return 1
  fi
  info "rtl_tcp missing — installing package rtl-sdr…"
  apt_update_quiet || true
  if pkg_available rtl-sdr; then
    apt_install_quiet rtl-sdr || return 1
  else
    err "Package rtl-sdr not available in apt."
    return 1
  fi
  if ! command -v rtl_tcp >/dev/null 2>&1; then
    err "rtl_tcp still missing after installing rtl-sdr."
    return 1
  fi
  ok "Installed rtl_tcp: $(command -v rtl_tcp)"
}

install_managed_rtl_tcp_service() {
  local port="$1"
  local unit_src="${ROOT}/host/owrx-rtl-tcp.service"
  local default_src="${ROOT}/host/owrx-rtl-tcp.default"
  [[ -f "$unit_src" ]] || { err "Missing ${unit_src}"; return 1; }
  ensure_sudo || return 1

  # Prefer blacklisted DVB modules so rtl_tcp can claim the stick
  for mod in dvb_usb_rtl28xxu dvb_usb_rtl2832u rtl2832 rtl2830 rtl8xxxu; do
    sudo modprobe -r "$mod" 2>/dev/null || true
  done

  sudo tee /etc/default/owrx-rtl-tcp >/dev/null <<EOF
# Managed by openwebrx-plus-deployment install.sh
RTL_TCP_LISTEN=0.0.0.0
RTL_TCP_PORT=${port}
EOF
  sudo cp "$unit_src" /etc/systemd/system/owrx-rtl-tcp.service
  # If template default exists, keep as reference only — live config is /etc/default/owrx-rtl-tcp
  [[ -f "$default_src" ]] || true

  sudo systemctl daemon-reload
  sudo systemctl enable owrx-rtl-tcp.service
  sudo systemctl restart owrx-rtl-tcp.service
  sleep 1
  if sudo systemctl is-active --quiet owrx-rtl-tcp.service; then
    ok "rtl_tcp service active on 0.0.0.0:${port}"
  else
    warn "rtl_tcp service not active yet — check: sudo journalctl -u owrx-rtl-tcp -n 40"
    sudo systemctl status owrx-rtl-tcp.service --no-pager -l || true
  fi
}

step "8/12" "Device binding / rtl_tcp"
echo

if [[ "$OWRX_DEVICE" == "rtl_sdr" ]]; then
  info "How should OpenWebRX reach the RTL-SDR?"
  echo "  1) USB in Docker              — mount /dev/bus/usb (type rtl_sdr)"
  echo "  2) rtl_tcp on this host       — install/run rtl_tcp, OpenWebRX type rtl_tcp (no USB in Docker)"
  echo
  RTL_ACCESS_DEFAULT="1"
  [[ "${RTL_TCP_CLIENT:-}" == "true" || "${RTL_TCP_MANAGED:-}" == "true" ]] && RTL_ACCESS_DEFAULT="2"
  RTL_ACCESS=""
  while [[ -z "$RTL_ACCESS" ]]; do
    prompt RTL_ACCESS "Choose access mode [1-2]" "$RTL_ACCESS_DEFAULT"
    case "$RTL_ACCESS" in
      1|2) ;;
      *) RTL_ACCESS=""; warn "Invalid choice." ;;
    esac
  done

  if [[ "$RTL_ACCESS" == "2" ]]; then
    RTL_TCP_CLIENT=true
    RTL_TCP_MANAGED=true
    BIND_USB=false
    ENABLE_RTL_TCP=false
    INSTALL_RTL_TCP_SVC=true
    info "Managed rtl_tcp: installer will check/install rtl-sdr, run a systemd unit,"
    info "and point OpenWebRX at host.docker.internal:<port> (no /dev/bus/usb in Compose)."
    echo
    prompt RTL_TCP_REMOTE_PORT "rtl_tcp listen port" "${RTL_TCP_REMOTE_PORT:-1234}"
    if ! [[ "$RTL_TCP_REMOTE_PORT" =~ ^[0-9]+$ ]] || (( RTL_TCP_REMOTE_PORT < 1 || RTL_TCP_REMOTE_PORT > 65535 )); then
      err "Invalid port: ${RTL_TCP_REMOTE_PORT}"
      exit 1
    fi
    RTL_TCP_REMOTE="host.docker.internal:${RTL_TCP_REMOTE_PORT}"
    EXTRA_HOSTS="    extra_hosts:
      - \"host.docker.internal:host-gateway\""
    ok "Will bind OpenWebRX rtl_tcp → ${RTL_TCP_REMOTE}"
  else
    BIND_USB=true
    RTL_TCP_CLIENT=false
    RTL_TCP_MANAGED=false
    RTL_TCP_REMOTE=""
    info "USB mode: /dev/bus/usb will be bound into the container."
    echo "  Optional: also publish an rtl_tcp-compatible IQ tap (FORWARD_LOCALPORT)"
    echo "  for external clients — this is not the same as managed rtl_tcp mode."
    echo
    if confirm "Also expose rtl_tcp-compatible port from the container?" n; then
      ENABLE_RTL_TCP=true
      prompt FORWARD_LOCALPORT_INTERNAL "Internal rtl_tcp port (OWRX rtltcp_compat)" "1234"
      prompt FORWARD_RTL_TCP_EXTERNAL "External host port to publish" "5678"
      if [[ "$FORWARD_LOCALPORT_INTERNAL" == "$FORWARD_RTL_TCP_EXTERNAL" ]]; then
        err "Internal and external rtl_tcp ports must differ (Docker Hub requirement)."
        exit 1
      fi
      EXTRA_PORTS="      - \"${FORWARD_RTL_TCP_EXTERNAL}:${FORWARD_RTL_TCP_EXTERNAL}\""
      EXTRA_ENV="      FORWARD_LOCALPORT_${FORWARD_LOCALPORT_INTERNAL}: ${FORWARD_RTL_TCP_EXTERNAL}"
      ok "IQ tap: container ${FORWARD_LOCALPORT_INTERNAL} → host ${FORWARD_RTL_TCP_EXTERNAL}"
    else
      ok "USB-only (no rtl_tcp publish)."
    fi
  fi
else
  BIND_USB=true
  warn "RX-888 uses SoapySDDC inside the image (CPU-heavy; not ideal on Pi-class hosts)."
  ok "USB bus will be passed through; no rtl_tcp client mode for RX-888."
fi
sleep 0.6

# ---------- healthcheck ----------
step "9/12" "Health checks"
HEALTHCHECK_SDR_DEVICES=1
HEALTHCHECK_USB=""
if [[ "$BIND_USB" == true ]]; then
  case "$OWRX_DEVICE" in
    rtl_sdr)
      if command -v lsusb >/dev/null 2>&1; then
        if lsusb -d 0bda:2838 >/dev/null 2>&1; then
          HEALTHCHECK_USB="HEALTHCHECK_USB_0BDA_2838=1"
        elif lsusb -d 0bda:2832 >/dev/null 2>&1; then
          HEALTHCHECK_USB="HEALTHCHECK_USB_0BDA_2832=1"
        else
          HEALTHCHECK_USB="HEALTHCHECK_USB_0BDA_2838=1"
        fi
      else
        HEALTHCHECK_USB="HEALTHCHECK_USB_0BDA_2838=1"
      fi
      ;;
    rx888)
      if command -v lsusb >/dev/null 2>&1 && lsusb -d 04b4:00f3 >/dev/null 2>&1; then
        HEALTHCHECK_USB="HEALTHCHECK_USB_04B4_00F3=1"
      else
        HEALTHCHECK_USB="HEALTHCHECK_USB_04B4_00F1=1"
      fi
      ;;
  esac

  if confirm "Enable USB + SDR health checks?" y; then
    HC_YAML="${HEALTHCHECK_USB/=/: }"
    EXTRA_ENV="${EXTRA_ENV}"$'\n'"      ${HC_YAML}"$'\n'"      HEALTHCHECK_SDR_DEVICES: ${HEALTHCHECK_SDR_DEVICES}"
    ok "Health checks enabled (${HEALTHCHECK_USB})."
  else
    HEALTHCHECK_USB=""
    HEALTHCHECK_SDR_DEVICES=""
    warn "Health checks skipped."
  fi
else
  HEALTHCHECK_USB=""
  HEALTHCHECK_SDR_DEVICES=""
  ok "USB health checks skipped (rtl_tcp client — no USB in container)."
fi

ENABLE_AUTOHEAL=false
if confirm "Also start autoheal companion (restart unhealthy containers)?" n; then
  ENABLE_AUTOHEAL=true
fi
echo

# ---------- host prep ----------
step "10/12" "Host preparation (blacklist + udev)"
DO_BLACKLIST=false
DO_UDEV=false
# USB-in-Docker OR managed host rtl_tcp both need the stick free of DVB drivers.
NEED_HOST_SDR_PREP=false
if [[ "$BIND_USB" == true || "$RTL_TCP_MANAGED" == true ]]; then
  NEED_HOST_SDR_PREP=true
fi
if [[ "$NEED_HOST_SDR_PREP" != true ]]; then
  ok "Skipping blacklist/udev (no local USB SDR for this install mode)."
else
  if [[ "$RTL_TCP_MANAGED" == true ]]; then
    info "Managed rtl_tcp still needs blacklist/udev so the host can open the dongle."
  fi
  if [[ -f /etc/modprobe.d/owrx-blacklist.conf ]]; then
    ok "Blacklist already installed — keeping"
  else
    if confirm "Install kernel module blacklist for SDR drivers? (recommended)" y; then
      DO_BLACKLIST=true
    fi
  fi
  if [[ -f /etc/udev/rules.d/99-sdr-devices.rules ]]; then
    ok "Udev rules already installed — keeping"
  else
    if confirm "Install udev rules for SDR USB permissions? (recommended)" y; then
      DO_UDEV=true
    fi
  fi
fi
sleep 0.6

# ---------- summary ----------
step "11/12" "Summary"
RTL_SUMMARY="off"
if [[ "$RTL_TCP_MANAGED" == true ]]; then
  RTL_SUMMARY="managed host service → ${RTL_TCP_REMOTE}"
elif [[ "$RTL_TCP_CLIENT" == true ]]; then
  RTL_SUMMARY="client → ${RTL_TCP_REMOTE} (no USB mount)"
elif [[ "$ENABLE_RTL_TCP" == true ]]; then
  RTL_SUMMARY="publish ${FORWARD_LOCALPORT_INTERNAL}→${FORWARD_RTL_TCP_EXTERNAL}"
fi
ACCESS_SUMMARY="USB mount"
[[ "$BIND_USB" != true && "$RTL_TCP_MANAGED" == true ]] && ACCESS_SUMMARY="rtl_tcp (managed on host)"
[[ "$BIND_USB" != true && "$RTL_TCP_MANAGED" != true ]] && ACCESS_SUMMARY="rtl_tcp client"
cat <<EOF
  Device:        ${DEVICE_LABEL} (${OWRX_DEVICE})
  Access:        ${ACCESS_SUMMARY}
  Image:         ${OWRX_IMAGE}
  Container:     ${OWRX_CONTAINER_NAME}
  Web port:      ${OWRX_PORT}
  Timezone:      ${TZ}
  Admin:         ${OPENWEBRX_ADMIN_USER}
  Data dir:      ${OWRX_DATA_DIR}
  rtl_tcp:       ${RTL_SUMMARY}
  Blacklist:     ${DO_BLACKLIST}
  Udev rules:    ${DO_UDEV}
  Autoheal:      ${ENABLE_AUTOHEAL}
  MQTT broker:   ${ENABLE_MQTT}
  SondeHub:      ${ENABLE_SONDEHUB}
EOF
echo
if ! confirm "Proceed with install?" y; then
  warn "Aborted."
  exit 0
fi
echo

# ---------- create dirs ----------
bold "Creating directories..."
if [[ ! -d "${OWRX_DATA_DIR}" ]] || [[ ! -w "$(dirname "${OWRX_DATA_DIR}")" ]]; then
  sudo mkdir -p \
    "${OWRX_DATA_DIR}/var" \
    "${OWRX_DATA_DIR}/etc" \
    "${OWRX_DATA_DIR}/plugins/receiver" \
    "${OWRX_DATA_DIR}/plugins/map" \
    "${OWRX_DATA_DIR}/presets"
  sudo chown -R "${USER}:${USER}" "${OWRX_DATA_DIR}"
else
  mkdir -p \
    "${OWRX_DATA_DIR}/var" \
    "${OWRX_DATA_DIR}/etc" \
    "${OWRX_DATA_DIR}/plugins/receiver" \
    "${OWRX_DATA_DIR}/plugins/map" \
    "${OWRX_DATA_DIR}/presets"
fi
ok "Data directories ready under ${OWRX_DATA_DIR}"
ensure_static_stubs "$ROOT" "${OWRX_DATA_DIR}"

# ---------- seed profiles ----------
bold "Seeding selected device profiles (no Airspy / SDRPlay)..."
PRESET_FULL="${PRESET_FULL:-${ROOT}/presets/${OWRX_DEVICE}/sdrs.json}"
PRESET_SRC="${SELECTED_PRESET:-$PRESET_FULL}"
PRESET_DST="${OWRX_DATA_DIR}/presets/sdrs.${OWRX_DEVICE}.json"
BACKGROUND_JSON="${SELECTED_BACKGROUND_JSON:-${ROOT}/presets/${OWRX_DEVICE}/background.json}"
mkdir -p "${OWRX_DATA_DIR}/presets" "${OWRX_DATA_DIR}/etc"

# If rtl_tcp client mode: rewrite selected preset to type=rtl_tcp + remote=host:port
if [[ "$RTL_TCP_CLIENT" == true && -n "$RTL_TCP_REMOTE" && -f "$PRESET_SRC" ]]; then
  PATCHED="$(mktemp)"
  if python3 "$ROOT/scripts/patch-rtl-tcp-preset.py" \
      --input "$PRESET_SRC" \
      --output "$PATCHED" \
      --remote "$RTL_TCP_REMOTE"; then
    PRESET_SRC="$PATCHED"
    ok "Preset converted to rtl_tcp → ${RTL_TCP_REMOTE}"
  else
    err "Failed to convert preset to rtl_tcp"
    exit 1
  fi
fi

if [[ -f "$PRESET_FULL" ]]; then
  cp "$PRESET_FULL" "$PRESET_DST"
fi
if [[ -f "$PRESET_SRC" ]]; then
  cp "$PRESET_SRC" "${OWRX_DATA_DIR}/presets/sdrs.json"
  cp "$PRESET_SRC" "${OWRX_DATA_DIR}/presets/sdrs.selected.json"
  if [[ -n "${SELECTED_IDS_FILE:-}" && -f "$SELECTED_IDS_FILE" ]]; then
    cp "$SELECTED_IDS_FILE" "${OWRX_DATA_DIR}/presets/SELECTED_PROFILES.txt"
  fi
  if [[ -f "$BACKGROUND_JSON" ]]; then
    cp "$BACKGROUND_JSON" "${OWRX_DATA_DIR}/presets/background.json"
  fi
  if [[ -n "${SELECTED_SERVICES_FILE:-}" && -f "$SELECTED_SERVICES_FILE" ]]; then
    cp "$SELECTED_SERVICES_FILE" "${OWRX_DATA_DIR}/presets/SELECTED_SERVICES.txt"
  fi
  if command -v python3 >/dev/null 2>&1; then
    BG_ARGS=()
    [[ -f "$BACKGROUND_JSON" ]] && BG_ARGS=(--background "$BACKGROUND_JSON")
    python3 "$ROOT/scripts/apply-presets.py" \
      --var-dir "${OWRX_DATA_DIR}/var" \
      --preset "$PRESET_SRC" \
      "${BG_ARGS[@]}" \
      && ok "Live settings seeded with selected profiles"
    apply_reporting_settings "${OWRX_DATA_DIR}/var" "${OWRX_DATA_DIR}/etc"
  else
    ok "Preset copied → ${OWRX_DATA_DIR}/presets/sdrs.json"
    warn "python3 missing — could not rewrite settings.json yet"
  fi
else
  warn "No selected preset to seed"
fi

cat > "${OWRX_DATA_DIR}/presets/SELECTED_DEVICE.txt" <<EOF
device=${OWRX_DEVICE}
label=${DEVICE_LABEL}
image=${OWRX_IMAGE}
bind_usb=${BIND_USB}
rtl_tcp_client=${RTL_TCP_CLIENT}
rtl_tcp_managed=${RTL_TCP_MANAGED}
rtl_tcp_remote=${RTL_TCP_REMOTE}
generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ---------- write .env ----------
bold "Writing .env..."
cat > "${ROOT}/.env" <<EOF
OWRX_IMAGE=${OWRX_IMAGE}
OWRX_CONTAINER_NAME=${OWRX_CONTAINER_NAME}
OWRX_PORT=${OWRX_PORT}
TZ=${TZ}
OPENWEBRX_ADMIN_USER=${OPENWEBRX_ADMIN_USER}
OPENWEBRX_ADMIN_PASSWORD=${OPENWEBRX_ADMIN_PASSWORD}
OWRX_DATA_DIR=${OWRX_DATA_DIR}
OWRX_DEVICE=${OWRX_DEVICE}
BIND_USB=${BIND_USB}
RTL_TCP_CLIENT=${RTL_TCP_CLIENT}
RTL_TCP_MANAGED=${RTL_TCP_MANAGED}
RTL_TCP_REMOTE=${RTL_TCP_REMOTE}
RTL_TCP_REMOTE_PORT=${RTL_TCP_REMOTE_PORT}
ENABLE_RTL_TCP=${ENABLE_RTL_TCP}
FORWARD_LOCALPORT_INTERNAL=${FORWARD_LOCALPORT_INTERNAL}
FORWARD_RTL_TCP_EXTERNAL=${FORWARD_RTL_TCP_EXTERNAL}
HEALTHCHECK_USB=${HEALTHCHECK_USB}
HEALTHCHECK_SDR_DEVICES=${HEALTHCHECK_SDR_DEVICES:-}
ENABLE_MQTT=${ENABLE_MQTT:-false}
ENABLE_SONDEHUB=${ENABLE_SONDEHUB:-false}
SONDEHUB_CALLSIGN=${SONDEHUB_CALLSIGN:-}
EOF
ok "Wrote ${ROOT}/.env"

# ---------- render compose ----------
bold "Generating docker-compose.yml..."
OUT="${ROOT}/docker-compose.yml"

# Normalize optional env lines (already indented with 6 spaces when set)
ENV_LINES=""
if [[ -n "${EXTRA_ENV}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    if [[ "$line" =~ ^[[:space:]] ]]; then
      ENV_LINES+="${line}"$'\n'
    else
      ENV_LINES+="      ${line}"$'\n'
    fi
  done <<< "$(printf '%s\n' "${EXTRA_ENV}")"
fi

PORTS_LINES=""
if [[ -n "${EXTRA_PORTS}" ]]; then
  PORTS_LINES="${EXTRA_PORTS}"$'\n'
fi

USB_BLOCK=""
if [[ "$BIND_USB" == true ]]; then
  USB_BLOCK="    devices:
      - /dev/bus/usb:/dev/bus/usb
    privileged: true"
else
  USB_BLOCK="    # USB not mounted — OpenWebRX uses rtl_tcp at \${RTL_TCP_REMOTE}
    privileged: false"
fi

HOSTS_BLOCK=""
if [[ -n "${EXTRA_HOSTS}" ]]; then
  HOSTS_BLOCK="${EXTRA_HOSTS}"$'\n'
fi

MQTT_SERVICE=""
MQTT_DEPENDS=""
if [[ "${ENABLE_MQTT:-false}" == true ]]; then
  MQTT_DEPENDS="    depends_on:
      - mosquitto
"
  MQTT_SERVICE="$(cat <<'MQTTEOF'

  mosquitto:
    image: eclipse-mosquitto:2
    container_name: ${OWRX_CONTAINER_NAME}-mosquitto
    restart: unless-stopped
    ports:
      - "1883:1883"
    # Anonymous local broker for OpenWebRX+ pub/sub (sonde, WSJT, APRS, …)
    entrypoint:
      - /bin/sh
      - -c
      - |
        printf 'listener 1883\nallow_anonymous true\n' > /tmp/mosquitto.conf
        exec mosquitto -c /tmp/mosquitto.conf
MQTTEOF
)"
fi

cat > "$OUT" <<EOF
# Generated by install.sh — re-run ./install.sh to regenerate.

services:
  openwebrx:
    image: \${OWRX_IMAGE}
    container_name: \${OWRX_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${OWRX_PORT}:8073"
${PORTS_LINES}${MQTT_DEPENDS}    environment:
      TZ: \${TZ}
      OPENWEBRX_ADMIN_USER: \${OPENWEBRX_ADMIN_USER}
      OPENWEBRX_ADMIN_PASSWORD: \${OPENWEBRX_ADMIN_PASSWORD}
${ENV_LINES}${HOSTS_BLOCK}${USB_BLOCK}
    volumes:
      - \${OWRX_DATA_DIR}/etc:/etc/openwebrx
      - \${OWRX_DATA_DIR}/var:/var/lib/openwebrx
      - \${OWRX_DATA_DIR}/plugins:/usr/lib/python3/dist-packages/htdocs/plugins
      # Hotfix: SondeHub isValidValue missing self (remove when image > 2026-10-28)
      - ./patches/sondehub.py:/usr/lib/python3/dist-packages/owrx/reporting/sondehub.py:ro
    tmpfs:
      - /tmp:mode=1777
${MQTT_SERVICE}
  autoheal:
    image: willfarrell/autoheal:latest
    container_name: \${OWRX_CONTAINER_NAME}-autoheal
    restart: always
    environment:
      AUTOHEAL_CONTAINER_LABEL: all
      AUTOHEAL_INTERVAL: 60
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    profiles:
      - autoheal
EOF
ok "Wrote ${OUT}"

# ---------- host blacklist / udev ----------
if [[ "$DO_BLACKLIST" == true ]]; then
  bold "Installing module blacklist (requires sudo)..."
  sudo cp "${ROOT}/host/owrx-blacklist.conf" /etc/modprobe.d/owrx-blacklist.conf
  ok "Installed /etc/modprobe.d/owrx-blacklist.conf"
  warn "Reboot (or unload modules) so the blacklist takes effect before using the SDR."
  if confirm "Try unloading conflicting modules now?" y; then
    for mod in dvb_usb_rtl28xxu dvb_usb_rtl2832u rtl2832 rtl2830 rtl8xxxu hackrf \
               sdr_msi3101 msi001 msi2500; do
      sudo modprobe -r "$mod" 2>/dev/null || true
    done
    ok "Unload attempted."
  fi
fi

if [[ "$DO_UDEV" == true ]]; then
  bold "Installing udev rules (requires sudo)..."
  sudo cp "${ROOT}/host/99-sdr-devices.rules" /etc/udev/rules.d/99-sdr-devices.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  ok "Installed /etc/udev/rules.d/99-sdr-devices.rules"
fi
echo

# ---------- managed rtl_tcp on host ----------
if [[ "$INSTALL_RTL_TCP_SVC" == true ]]; then
  bold "Installing managed rtl_tcp host service..."
  ensure_rtl_tcp_binary || exit 1
  install_managed_rtl_tcp_service "$RTL_TCP_REMOTE_PORT" || exit 1
  echo
fi

# ---------- pull & start ----------
step "12/12" "Pull image & start container"
COMPOSE="${COMPOSE:-docker compose}"
if confirm "Pull image and start OpenWebRX+ now?" y; then
  run_quiet "Pulling ${OWRX_IMAGE}" "Image pulled" \
    $COMPOSE pull --quiet
  if [[ "$ENABLE_AUTOHEAL" == true ]]; then
    run_quiet "Starting containers (+ autoheal)" "Containers started" \
      $COMPOSE --profile autoheal up -d --quiet-pull
  else
    run_quiet "Starting OpenWebRX+" "Container started" \
      $COMPOSE up -d --quiet-pull
  fi

  # Re-apply after first boot so OWRX defaults (Airspy/SDRPlay) cannot stick
  if [[ -f "${PRESET_SRC:-}" ]] && command -v python3 >/dev/null 2>&1; then
    sleep 4
    BG_ARGS=()
    [[ -f "${BACKGROUND_JSON:-}" ]] && BG_ARGS=(--background "$BACKGROUND_JSON")
    python3 "$ROOT/scripts/apply-presets.py" \
      --var-dir "${OWRX_DATA_DIR}/var" \
      --preset "$PRESET_SRC" \
      "${BG_ARGS[@]}" >/dev/null
    $DOCKER restart "${OWRX_CONTAINER_NAME}" >/dev/null 2>&1 || true
    ok "Profiles locked to your selection (${DEVICE_LABEL})"
  fi

  echo
  ok "Ready → http://localhost:${OWRX_PORT}  (user: ${OPENWEBRX_ADMIN_USER})"
  info "Logs: $COMPOSE logs -f openwebrx"
  echo
  bold "Next"
  echo "  Profiles: HAMVN / HF FT8-FT4 / ISS only (no Airspy+, no SDRPlay)"
  if [[ "$RTL_TCP_MANAGED" == true ]]; then
    echo "  Host rtl_tcp: systemctl status owrx-rtl-tcp"
    echo "  OpenWebRX → ${RTL_TCP_REMOTE}"
    echo "  Logs: journalctl -u owrx-rtl-tcp -f"
  elif [[ "$RTL_TCP_CLIENT" == true ]]; then
    echo "  OpenWebRX connects to rtl_tcp at ${RTL_TCP_REMOTE}"
  elif [[ "$OWRX_DEVICE" == "rtl_sdr" && "$ENABLE_RTL_TCP" == true ]]; then
    echo "  rtl_tcp publish: host ${FORWARD_RTL_TCP_EXTERNAL} (internal ${FORWARD_LOCALPORT_INTERNAL})"
  fi
  if [[ "$DO_BLACKLIST" == true ]]; then
    echo "  Reboot if the SDR is still not claimed."
  fi
else
  ok "Config written. Start later: ./scripts/start.sh"
  if [[ "$INSTALL_RTL_TCP_SVC" == true ]]; then
    info "rtl_tcp service was already installed/started above."
  fi
fi

echo
ok "Install complete."
