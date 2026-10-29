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

ensure_debian_packages() {
  local pkgs=("$@") missing=()
  local p
  for p in "${pkgs[@]}"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      missing+=("$p")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    return 0
  fi
  warn "Missing Debian packages: ${missing[*]}"
  if confirm "Install with apt now? (sudo)" y; then
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    err "Install packages manually: sudo apt-get install -y ${missing[*]}"
    return 1
  fi
}

# ---------- banner ----------
clear 2>/dev/null || true
bold "=============================================="
bold "  OpenWebRX+ Docker Deployment (Debian)"
bold "=============================================="
echo
info "Image: https://hub.docker.com/r/slechev/openwebrxplus"
info "Repo:  ${ROOT}"
echo

# ---------- prerequisites ----------
bold "1) Prerequisites (native Debian)"
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

if ! need_cmd docker; then
  if is_debian_like && confirm "Docker not found. Install docker.io + compose plugin via apt?" y; then
    ensure_debian_packages docker.io docker-compose-v2 || {
      # Bookworm+ often ships compose as docker-compose-v2; fall back to plugin name
      ensure_debian_packages docker.io docker-compose-plugin || true
    }
    sudo systemctl enable --now docker
  else
    err "Install Docker Engine on Debian, then re-run:"
    err "  sudo apt-get install -y docker.io docker-compose-v2"
    err "  sudo systemctl enable --now docker"
    err "  sudo usermod -aG docker \"\$USER\"  # then log out/in"
    exit 1
  fi
fi

if ! docker compose version >/dev/null 2>&1; then
  if is_debian_like && confirm "docker compose missing. Install compose plugin via apt?" y; then
    ensure_debian_packages docker-compose-v2 || ensure_debian_packages docker-compose-plugin || true
  fi
fi
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 is required (docker compose)."
  err "  sudo apt-get install -y docker-compose-v2"
  exit 1
fi
ok "Docker OK: $(docker --version)"
ok "Compose OK: $(docker compose version)"

# Socket permission check
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
  COMPOSE="sudo docker compose"
else
  DOCKER="docker"
  COMPOSE="docker compose"
fi

# Ensure plugdev exists (udev rules reference it)
if is_debian_like && ! getent group plugdev >/dev/null; then
  sudo groupadd plugdev
fi
if is_debian_like && confirm "Add user $USER to groups docker + plugdev?" y; then
  sudo usermod -aG docker,plugdev "$USER" || sudo usermod -aG docker "$USER"
  warn "Group change applies after you log out and back in."
fi
echo

# ---------- detect devices ----------
bold "2) Detect plugged USB SDR devices"
if [[ -x "$ROOT/scripts/detect-usb.sh" ]]; then
  "$ROOT/scripts/detect-usb.sh" || warn "No known devices detected yet — you can still continue."
else
  warn "detect-usb.sh missing; skipping."
fi
echo

# ---------- device selection ----------
bold "3) Select supported device"
echo "  1) RTL-SDR          (rtl_sdr — bind /dev/bus/usb, optional rtl_tcp)"
echo "  2) RX-888 / SDDC    (sddc_soapy — bind /dev/bus/usb)"
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
echo

# ---------- image / softmbe ----------
bold "4) Docker image"
echo "  1) slechev/openwebrxplus          (standard)"
echo "  2) slechev/openwebrxplus-softmbe  (includes SoftMBE digital voice)"
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
echo

# ---------- admin / presets ----------
bold "5) Presets — admin, timezone, ports, profiles"
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

bold "6) Device binding / rtl_tcp"
info "USB devices are always bound via /dev/bus/usb into the container."

if [[ "$OWRX_DEVICE" == "rtl_sdr" ]]; then
  echo
  info "RTL-SDR options:"
  echo "  • Direct USB (recommended) — OpenWebRX talks to the dongle inside Docker"
  echo "  • Also expose rtl_tcp-compatible port (FORWARD_LOCALPORT) for external clients"
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
echo

# ---------- healthcheck ----------
bold "7) Health checks"
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
bold "8) Host preparation (Debian blacklist + udev)"
DO_BLACKLIST=false
DO_UDEV=false
if confirm "Install kernel module blacklist for SDR drivers? (recommended)" y; then
  DO_BLACKLIST=true
fi
if confirm "Install udev rules for SDR USB permissions? (recommended)" y; then
  DO_UDEV=true
fi
echo

# ---------- summary ----------
bold "9) Summary"
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
bold "Seeding device profile preset..."
PRESET_SRC="${ROOT}/presets/${OWRX_DEVICE}/sdrs.json"
PRESET_DST="${OWRX_DATA_DIR}/presets/sdrs.${OWRX_DEVICE}.json"
if [[ -f "$PRESET_SRC" ]]; then
  cp "$PRESET_SRC" "$PRESET_DST"
  cp "$PRESET_SRC" "${OWRX_DATA_DIR}/presets/sdrs.json"
  ok "Preset copied → ${PRESET_DST}"
  info "After first start, import/apply profiles via Settings → SDR Devices,"
  info "or merge ${PRESET_DST} into the live settings (see README)."
else
  warn "No preset found at ${PRESET_SRC}"
fi

# Optional: drop a marker so users know which device was chosen
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
bold "10) Pull image & start container"
# Default COMPOSE if prerequisites path set DOCKER/COMPOSE earlier
COMPOSE="${COMPOSE:-docker compose}"
if confirm "Pull image and start OpenWebRX+ now?" y; then
  $COMPOSE pull
  if [[ "$ENABLE_AUTOHEAL" == true ]]; then
    $COMPOSE --profile autoheal up -d
  else
    $COMPOSE up -d
  fi
  echo
  ok "Container started."
  info "Web UI:  http://localhost:${OWRX_PORT}"
  info "Login:   ${OPENWEBRX_ADMIN_USER} / (password you set)"
  info "Logs:    $COMPOSE logs -f openwebrx"
  info "Status:  ./scripts/status.sh"
  info "Stop:    ./scripts/stop.sh"
  echo
  bold "Next steps"
  echo "  1. Open the web UI and sign in as admin."
  echo "  2. Go to Settings → SDR Devices and Profiles."
  case "$OWRX_DEVICE" in
    rtl_sdr)
      echo "  3. Enable/configure the RTL-SDR device (preset reference: ${PRESET_DST})."
      echo "     For rtl_tcp clients, ensure rtltcp_compat/port matches ${FORWARD_LOCALPORT_INTERNAL:-1234}."
      ;;
    rx888)
      echo "  3. Add/enable an RX-888 device with type sddc_soapy (preset: ${PRESET_DST})."
      echo "     If the device is missing, restart the container after USB plug-in."
      ;;
  esac
  if [[ "$DO_BLACKLIST" == true ]]; then
    echo "  4. Reboot the host if the SDR is not detected (blacklist needs reboot)."
  fi
else
  ok "Config written. Start later with: ./scripts/start.sh"
fi

echo
ok "Install complete."
