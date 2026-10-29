#!/usr/bin/env bash
# Uninstall OpenWebRX+ stack and Docker packages.
# Keeps host SDR prep: module blacklist + udev rules (+ plugdev group).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"

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

confirm() {
  local __q="$1" __def="${2:-n}" __ans
  read -r -p "$__q [${__def}/$([ "$__def" = y ] && echo n || echo y)]: " __ans || true
  __ans="${__ans:-$__def}"
  [[ "$__ans" =~ ^[Yy]$ ]]
}

SPIN_PID=""
trap 'spin_clear' EXIT

spin_start() {
  local msg="$1"
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

# ---------- banner ----------
clear 2>/dev/null || true
bold "=============================================="
bold "  OpenWebRX+ Uninstall (Debian)"
bold "=============================================="
echo
info "Removes: containers, images, Compose files, Docker packages"
info "Keeps:   /etc/modprobe.d/owrx-blacklist.conf"
info "         /etc/udev/rules.d/99-sdr-devices.rules"
info "         plugdev group membership"
echo

# Load deploy config if present
OWRX_CONTAINER_NAME="openwebrxplus"
OWRX_DATA_DIR="/opt/owrx-docker"
OWRX_IMAGE="slechev/openwebrxplus:latest"
if [[ -f "$ROOT/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
  ok "Loaded .env (container=${OWRX_CONTAINER_NAME}, data=${OWRX_DATA_DIR})"
else
  warn "No .env — using defaults (container=${OWRX_CONTAINER_NAME}, data=${OWRX_DATA_DIR})"
fi
echo

bold "What will be removed"
echo "  1. OpenWebRX+ / autoheal containers & Compose project"
echo "  2. Related Docker images (openwebrxplus*, autoheal)"
echo "  3. Generated docker-compose.yml and .env in this repo"
echo "  4. Docker engine packages (docker.io, docker-compose, …)"
echo "  5. Optional: persistent data under ${OWRX_DATA_DIR}"
echo
bold "Kept on purpose"
echo "  • Kernel blacklist  /etc/modprobe.d/owrx-blacklist.conf"
echo "  • Udev SDR rules    /etc/udev/rules.d/99-sdr-devices.rules"
echo

REMOVE_DATA=false
if [[ -d "${OWRX_DATA_DIR}" ]]; then
  if confirm "Also delete persistent data (${OWRX_DATA_DIR})?" n; then
    REMOVE_DATA=true
  fi
fi

REMOVE_DOCKER=true
if ! confirm "Uninstall Docker packages from the host?" y; then
  REMOVE_DOCKER=false
  warn "Docker packages will be left installed."
fi

echo
cat <<EOF
  Container:   ${OWRX_CONTAINER_NAME}
  Data dir:    ${OWRX_DATA_DIR}  (delete: ${REMOVE_DATA})
  Remove Docker pkgs: ${REMOVE_DOCKER}
  Keep blacklist/udev: yes
EOF
echo
if ! confirm "Proceed with uninstall?" y; then
  warn "Aborted."
  exit 0
fi
echo

# ---------- stop compose / containers ----------
bold "1) Stop OpenWebRX+ stack"
DOCKER=""
COMPOSE=""
if DOCKER="$(resolve_docker 2>/dev/null)"; then
  COMPOSE="$(resolve_compose "$DOCKER" 2>/dev/null || true)"
fi

if [[ -n "${COMPOSE}" && -f "$ROOT/docker-compose.yml" ]]; then
  run_quiet "Stopping Compose project" "Compose project stopped" \
    $COMPOSE down --remove-orphans || true
elif [[ -n "${DOCKER}" ]]; then
  # Fallback if compose file missing but containers remain
  for c in "${OWRX_CONTAINER_NAME}" "${OWRX_CONTAINER_NAME}-autoheal"; do
    if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
      run_quiet "Removing container ${c}" "Removed ${c}" \
        $DOCKER rm -f "$c" || true
    fi
  done
else
  warn "Docker not reachable — skipping container stop."
fi

# ---------- remove images ----------
bold "2) Remove OpenWebRX+ images"
if [[ -n "${DOCKER}" ]]; then
  # Exact configured image + common tags + autoheal
  mapfile -t IMAGES < <(
    {
      echo "${OWRX_IMAGE}"
      echo "slechev/openwebrxplus"
      echo "slechev/openwebrxplus:latest"
      echo "slechev/openwebrxplus-softmbe"
      echo "slechev/openwebrxplus-softmbe:latest"
      echo "willfarrell/autoheal"
      echo "willfarrell/autoheal:latest"
      $DOCKER images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E 'openwebrxplus|autoheal' || true
    } | sort -u
  )
  for img in "${IMAGES[@]}"; do
    [[ -z "$img" || "$img" == "*: *" ]] && continue
    if $DOCKER image inspect "$img" >/dev/null 2>&1; then
      run_quiet "Removing image ${img}" "Removed ${img}" \
        $DOCKER rmi -f "$img" || true
    fi
  done
  # Dangling leftovers from the project
  run_quiet "Pruning dangling images" "Dangling images pruned" \
    $DOCKER image prune -f || true
else
  warn "Skipping image removal (no Docker)."
fi
echo

# ---------- generated project files ----------
bold "3) Remove generated deploy files"
for f in "$ROOT/docker-compose.yml" "$ROOT/.env"; do
  if [[ -f "$f" ]]; then
    rm -f "$f"
    ok "Removed $(basename "$f")"
  fi
done
echo

# ---------- data directory ----------
bold "4) Persistent data"
if [[ "$REMOVE_DATA" == true ]]; then
  if [[ -d "${OWRX_DATA_DIR}" ]]; then
    run_quiet "Deleting ${OWRX_DATA_DIR}" "Data directory deleted" \
      sudo rm -rf "${OWRX_DATA_DIR}"
  else
    warn "Data dir not found: ${OWRX_DATA_DIR}"
  fi
else
  if [[ -d "${OWRX_DATA_DIR}" ]]; then
    ok "Kept data: ${OWRX_DATA_DIR}"
  else
    info "No data dir at ${OWRX_DATA_DIR}"
  fi
fi
echo

# ---------- Docker packages ----------
bold "5) Docker packages"
if [[ "$REMOVE_DOCKER" == true ]]; then
  if command -v docker >/dev/null 2>&1 || dpkg -s docker.io >/dev/null 2>&1; then
    stop_docker_units() {
      sudo systemctl disable --now docker.socket docker.service 2>/dev/null || true
      sudo systemctl disable --now containerd.service 2>/dev/null || true
      sudo systemctl disable --now docker 2>/dev/null || true
      return 0
    }
    run_quiet "Stopping docker service" "Docker service stopped" stop_docker_units
  fi

  # Purge only engine/compose packages we (may have) installed — not usbutils/udev/curl
  PURGE_PKGS=()
  for p in docker.io docker-compose docker-compose-v2 docker-compose-plugin \
           docker-ce docker-ce-cli docker-buildx-plugin containerd.io \
           docker-doc docker-registry; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      PURGE_PKGS+=("$p")
    fi
  done

  if [[ ${#PURGE_PKGS[@]} -gt 0 ]]; then
    run_quiet "Purging ${PURGE_PKGS[*]}" "Docker packages purged" \
      sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
        -o Dpkg::Use-Pty=0 \
        "${PURGE_PKGS[@]}"
    run_quiet "Autoremoving unused deps" "Autoremove done" \
      sudo env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq \
        -o Dpkg::Use-Pty=0
  else
    ok "No Docker packages installed."
  fi
else
  ok "Skipped Docker package removal."
fi
echo

# ---------- confirm kept host files ----------
bold "6) Host SDR settings (kept)"
if [[ -f /etc/modprobe.d/owrx-blacklist.conf ]]; then
  ok "Kept blacklist: /etc/modprobe.d/owrx-blacklist.conf"
else
  info "No blacklist file present."
fi
if [[ -f /etc/udev/rules.d/99-sdr-devices.rules ]]; then
  ok "Kept udev rules: /etc/udev/rules.d/99-sdr-devices.rules"
else
  info "No SDR udev rules present."
fi
echo

ok "Uninstall complete."
info "Re-install later with: ./install.sh"
