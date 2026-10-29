#!/usr/bin/env bash
# Interactive installer for OpenWebRX+ (slechev/openwebrxplus) with USB SDR binding.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

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

# ---------- quiet progress (spinner) ----------
SPIN_PID=""
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

# ---------- already configured? ----------
INSTALL_MODE="fresh"   # fresh | keep | reconfigure | presets
detect_existing_install

if [[ "$EXISTING" == true ]]; then
  step "0" "Existing installation"
  info "Repo: ${ROOT}"
  echo
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
  echo "  1) Keep config — pull image & (re)start only"
  echo "  2) Reconfigure — run full installer prompts again"
  echo "  3) Refresh presets only — copy latest sdrs.json into data dir"
  echo "  4) Abort"
  EXISTING_CHOICE=""
  while [[ -z "$EXISTING_CHOICE" ]]; do
    prompt EXISTING_CHOICE "Choose [1-4]" "1"
    case "$EXISTING_CHOICE" in
      1) INSTALL_MODE="keep" ;;
      2) INSTALL_MODE="reconfigure" ;;
      3) INSTALL_MODE="presets" ;;
      4) warn "Aborted."; exit 0 ;;
      *) EXISTING_CHOICE=""; warn "Invalid choice." ;;
    esac
  done
fi

# ---------- presets-only fast path ----------
if [[ "$INSTALL_MODE" == "presets" ]]; then
  step "…" "Refresh presets"
  if [[ ! -f "$ROOT/.env" ]]; then
    err "No .env — cannot refresh presets. Choose reconfigure (2) instead."
    exit 1
  fi
  info "RTL/RX-888 only — drop Airspy/SDRPlay"
  echo
  "$ROOT/scripts/apply-presets.sh"
  ok "Presets applied to live settings."
  exit 0
fi

# ---------- keep-config fast path ----------
if [[ "$INSTALL_MODE" == "keep" ]]; then
  step "…" "Keep config — pull & start"
  if [[ ! -f "$ROOT/.env" || ! -f "$ROOT/docker-compose.yml" ]]; then
    err "Missing .env or docker-compose.yml — choose reconfigure (2)."
    exit 1
  fi
  # shellcheck disable=SC1091
  set -a; source "$ROOT/.env"; set +a
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker not installed. Choose reconfigure or install Docker first."
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
echo "  1) RTL-SDR          (rtl_sdr — bind /dev/bus/usb, optional rtl_tcp)"
echo "  2) RX-888 / SDDC    (sddc_soapy — bind /dev/bus/usb)"
echo
DEVICE_CHOICE=""
while [[ -z "$DEVICE_CHOICE" ]]; do
  prompt DEVICE_CHOICE "Choose device [1-2]" "1"
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
python3 "$ROOT/scripts/select-profiles.py" \
  --preset "$PRESET_FULL" \
  --output "$SELECTED_PRESET" \
  --selected-file "$SELECTED_IDS_FILE"
# select-profiles clears the screen; restore step header briefly
ok "Profile selection saved"
sleep 0.8

# ---------- image / softmbe ----------
step "5/11" "Docker image"
echo "  1) slechev/openwebrxplus          (standard)"
echo "  2) slechev/openwebrxplus-softmbe  (includes SoftMBE digital voice)"
echo
IMAGE_CHOICE=""
while [[ -z "$IMAGE_CHOICE" ]]; do
  prompt IMAGE_CHOICE "Choose image [1-2]" "1"
  case "$IMAGE_CHOICE" in
    1) OWRX_IMAGE="slechev/openwebrxplus:latest" ;;
    2) OWRX_IMAGE="slechev/openwebrxplus-softmbe:latest" ;;
    *) IMAGE_CHOICE=""; warn "Invalid choice." ;;
  esac
done
ok "Image: ${OWRX_IMAGE}"
sleep 0.6

# ---------- admin / presets ----------
step "6/11" "Admin, timezone, ports, data"
DEFAULT_TZ="$(detect_debian_tz)"
prompt OWRX_CONTAINER_NAME "Container name" "openwebrxplus"
prompt OWRX_PORT "Web UI host port" "8073"
prompt TZ "Timezone (IANA)" "${TZ:-$DEFAULT_TZ}"
prompt OPENWEBRX_ADMIN_USER "Admin username" "admin"
prompt_secret OPENWEBRX_ADMIN_PASSWORD "Admin password" "changeme"
if [[ -z "$OPENWEBRX_ADMIN_PASSWORD" ]]; then
  err "Admin password cannot be empty."
  exit 1
fi

# Official OWRX+ docs use /opt/owrx-docker on Debian servers
DEFAULT_DATA="/opt/owrx-docker"
prompt OWRX_DATA_DIR "Persistent data directory" "$DEFAULT_DATA"
# Expand ~ if present
OWRX_DATA_DIR="${OWRX_DATA_DIR/#\~/$HOME}"
# Make absolute if relative
if [[ "${OWRX_DATA_DIR}" != /* ]]; then
  OWRX_DATA_DIR="$(cd "$ROOT" && mkdir -p "$OWRX_DATA_DIR" && cd "$OWRX_DATA_DIR" && pwd)"
fi
echo

# ---------- rtl_tcp ----------
ENABLE_RTL_TCP=false
FORWARD_LOCALPORT_INTERNAL=""
FORWARD_RTL_TCP_EXTERNAL=""
EXTRA_PORTS=""
EXTRA_ENV=""

step "7/11" "Device binding / rtl_tcp"
info "USB devices are always bound via /dev/bus/usb into the container."
echo

if [[ "$OWRX_DEVICE" == "rtl_sdr" ]]; then
  info "RTL-SDR options:"
  echo "  • Direct USB (recommended) — OpenWebRX talks to the dongle inside Docker"
  echo "  • Also expose rtl_tcp-compatible port (FORWARD_LOCALPORT) for external clients"
  echo
  if confirm "Enable rtl_tcp port forwarding from the container?" n; then
    ENABLE_RTL_TCP=true
    prompt FORWARD_LOCALPORT_INTERNAL "Internal rtl_tcp port (OWRX settings / rtltcp_compat)" "1234"
    prompt FORWARD_RTL_TCP_EXTERNAL "External host port to publish" "5678"
    if [[ "$FORWARD_LOCALPORT_INTERNAL" == "$FORWARD_RTL_TCP_EXTERNAL" ]]; then
      err "Internal and external rtl_tcp ports must differ (Docker Hub requirement)."
      exit 1
    fi
    EXTRA_PORTS="      - \"${FORWARD_RTL_TCP_EXTERNAL}:${FORWARD_RTL_TCP_EXTERNAL}\""
    EXTRA_ENV="      FORWARD_LOCALPORT_${FORWARD_LOCALPORT_INTERNAL}: ${FORWARD_RTL_TCP_EXTERNAL}"
    ok "rtl_tcp: container ${FORWARD_LOCALPORT_INTERNAL} → host ${FORWARD_RTL_TCP_EXTERNAL}"
  else
    ok "rtl_tcp forwarding disabled (USB-only)."
  fi
else
  warn "RX-888 uses SoapySDDC inside the image (CPU-heavy; not ideal on Pi-class hosts)."
  ok "USB bus will be passed through; no rtl_tcp forwarding for RX-888."
fi
sleep 0.6

# ---------- healthcheck ----------
step "8/11" "Health checks"
HEALTHCHECK_SDR_DEVICES=1
HEALTHCHECK_USB=""
case "$OWRX_DEVICE" in
  rtl_sdr)
    # Prefer Blog stick ID; also works for generic 2832
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
  # Convert KEY=VALUE → YAML "KEY: VALUE" for compose
  HC_YAML="${HEALTHCHECK_USB/=/: }"
  EXTRA_ENV="${EXTRA_ENV}"$'\n'"      ${HC_YAML}"$'\n'"      HEALTHCHECK_SDR_DEVICES: ${HEALTHCHECK_SDR_DEVICES}"
  ok "Health checks enabled (${HEALTHCHECK_USB})."
else
  HEALTHCHECK_USB=""
  HEALTHCHECK_SDR_DEVICES=""
  warn "Health checks skipped."
fi

ENABLE_AUTOHEAL=false
if confirm "Also start autoheal companion (restart unhealthy containers)?" n; then
  ENABLE_AUTOHEAL=true
fi
echo

# ---------- host prep ----------
step "9/11" "Host preparation (blacklist + udev)"
DO_BLACKLIST=false
DO_UDEV=false
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
sleep 0.6

# ---------- summary ----------
step "10/11" "Summary"
cat <<EOF
  Device:        ${DEVICE_LABEL} (${OWRX_DEVICE})
  Image:         ${OWRX_IMAGE}
  Container:     ${OWRX_CONTAINER_NAME}
  Web port:      ${OWRX_PORT}
  Timezone:      ${TZ}
  Admin:         ${OPENWEBRX_ADMIN_USER}
  Data dir:      ${OWRX_DATA_DIR}
  rtl_tcp:       ${ENABLE_RTL_TCP}$([ "$ENABLE_RTL_TCP" = true ] && echo " (${FORWARD_LOCALPORT_INTERNAL}→${FORWARD_RTL_TCP_EXTERNAL})" || true)
  Blacklist:     ${DO_BLACKLIST}
  Udev rules:    ${DO_UDEV}
  Autoheal:      ${ENABLE_AUTOHEAL}
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

# ---------- seed profiles ----------
bold "Seeding selected device profiles (no Airspy / SDRPlay)..."
PRESET_FULL="${PRESET_FULL:-${ROOT}/presets/${OWRX_DEVICE}/sdrs.json}"
PRESET_SRC="${SELECTED_PRESET:-$PRESET_FULL}"
PRESET_DST="${OWRX_DATA_DIR}/presets/sdrs.${OWRX_DEVICE}.json"
BACKGROUND_JSON="${ROOT}/presets/${OWRX_DEVICE}/background.json"
mkdir -p "${OWRX_DATA_DIR}/presets"
if [[ -f "$PRESET_FULL" ]]; then
  cp "$PRESET_FULL" "$PRESET_DST"
fi
if [[ -f "$PRESET_SRC" ]]; then
  cp "$PRESET_SRC" "${OWRX_DATA_DIR}/presets/sdrs.json"
  cp "$PRESET_SRC" "${OWRX_DATA_DIR}/presets/sdrs.selected.json"
  if [[ -n "${SELECTED_IDS_FILE:-}" && -f "$SELECTED_IDS_FILE" ]]; then
    cp "$SELECTED_IDS_FILE" "${OWRX_DATA_DIR}/presets/SELECTED_PROFILES.txt"
  fi
  if command -v python3 >/dev/null 2>&1; then
    BG_ARGS=()
    [[ -f "$BACKGROUND_JSON" ]] && BG_ARGS=(--background "$BACKGROUND_JSON")
    python3 "$ROOT/scripts/apply-presets.py" \
      --var-dir "${OWRX_DATA_DIR}/var" \
      --preset "$PRESET_SRC" \
      "${BG_ARGS[@]}" \
      && ok "Live settings seeded with selected profiles"
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
ENABLE_RTL_TCP=${ENABLE_RTL_TCP}
FORWARD_LOCALPORT_INTERNAL=${FORWARD_LOCALPORT_INTERNAL}
FORWARD_RTL_TCP_EXTERNAL=${FORWARD_RTL_TCP_EXTERNAL}
HEALTHCHECK_USB=${HEALTHCHECK_USB}
HEALTHCHECK_SDR_DEVICES=${HEALTHCHECK_SDR_DEVICES:-}
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

cat > "$OUT" <<EOF
# Generated by install.sh — re-run ./install.sh to regenerate.

services:
  openwebrx:
    image: \${OWRX_IMAGE}
    container_name: \${OWRX_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "\${OWRX_PORT}:8073"
${PORTS_LINES}    environment:
      TZ: \${TZ}
      OPENWEBRX_ADMIN_USER: \${OPENWEBRX_ADMIN_USER}
      OPENWEBRX_ADMIN_PASSWORD: \${OPENWEBRX_ADMIN_PASSWORD}
${ENV_LINES}    devices:
      - /dev/bus/usb:/dev/bus/usb
    volumes:
      - \${OWRX_DATA_DIR}/etc:/etc/openwebrx
      - \${OWRX_DATA_DIR}/var:/var/lib/openwebrx
      - \${OWRX_DATA_DIR}/plugins:/usr/lib/python3/dist-packages/htdocs/plugins
    tmpfs:
      - /tmp:mode=1777
    privileged: true

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

# ---------- pull & start ----------
step "11/11" "Pull image & start container"
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
  if [[ "$OWRX_DEVICE" == "rtl_sdr" && "$ENABLE_RTL_TCP" == true ]]; then
    echo "  rtl_tcp host port: ${FORWARD_RTL_TCP_EXTERNAL} (internal ${FORWARD_LOCALPORT_INTERNAL})"
  fi
  if [[ "$DO_BLACKLIST" == true ]]; then
    echo "  Reboot if the SDR is still not claimed."
  fi
else
  ok "Config written. Start later: ./scripts/start.sh"
fi

echo
ok "Install complete."
