#!/usr/bin/env bash
# Shared helpers for scripts/

# Soft Ctrl+C: exit 130 with a short message, no shell error dump.
quiet_interrupt_trap() {
  on_interrupt() {
    echo
    echo "Cancelled."
    exit 130
  }
  trap on_interrupt INT
}

resolve_compose() {
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

resolve_docker() {
  if docker info >/dev/null 2>&1; then
    echo "docker"
  elif sudo docker info >/dev/null 2>&1; then
    echo "sudo docker"
  else
    return 1
  fi
}

# Seed custom.css + plugins/*/init.js so /static/... is real CSS/JS (not HTML 404 → MIME block).
# Safe to call repeatedly; never overwrites existing non-empty user files.
ensure_static_stubs() {
  local root="${1:-}"
  local data_dir="${2:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  if [[ -z "$data_dir" ]]; then
    if [[ -f "${root}/.env" ]]; then
      # shellcheck disable=SC1091
      set -a; source "${root}/.env"; set +a
    fi
    data_dir="${OWRX_DATA_DIR:-/opt/owrx-docker}"
  fi

  local tpl="${root}/templates"
  mkdir -p "${data_dir}/etc" \
    "${data_dir}/plugins/receiver" \
    "${data_dir}/plugins/map" 2>/dev/null \
    || sudo mkdir -p "${data_dir}/etc" \
      "${data_dir}/plugins/receiver" \
      "${data_dir}/plugins/map"

  _seed_stub() {
    local dest="$1" src="$2"
    if [[ -f "$dest" ]] && [[ -s "$dest" ]]; then
      return 0
    fi
    if [[ ! -f "$src" ]]; then
      return 0
    fi
    if cp "$src" "$dest" 2>/dev/null; then
      :
    else
      sudo cp "$src" "$dest"
      sudo chown "${USER}:${USER}" "$dest" 2>/dev/null || true
    fi
    echo "seeded: ${dest}"
  }

  _seed_stub "${data_dir}/etc/custom.css" "${tpl}/custom.css"
  _seed_stub "${data_dir}/plugins/receiver/init.js" "${tpl}/plugins/receiver/init.js"
  _seed_stub "${data_dir}/plugins/map/init.js" "${tpl}/plugins/map/init.js"
}

# Ensure docker-compose.yml mounts patches/sondehub.py (SondeHub isValidValue hotfix).
# Safe to call repeatedly; no-op if already present or files missing.
ensure_sondehub_hotfix() {
  local root="${1:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  local compose="${root}/docker-compose.yml"
  local patch="${root}/patches/sondehub.py"
  local mount='      - ./patches/sondehub.py:/usr/lib/python3/dist-packages/owrx/reporting/sondehub.py:ro'
  [[ -f "$patch" && -f "$compose" ]] || return 0
  if grep -q 'patches/sondehub.py' "$compose"; then
    return 0
  fi
  python3 - "$compose" "$mount" <<'PY'
import sys
from pathlib import Path

compose = Path(sys.argv[1])
mount = sys.argv[2] + "\n"
text = compose.read_text(encoding="utf-8")
marker = "htdocs/plugins"
idx = text.find(marker)
if idx < 0:
    raise SystemExit(
        "error: cannot find plugins volume in docker-compose.yml — re-run ./install.sh (reconfigure)"
    )
eol = text.find("\n", idx)
compose.write_text(text[: eol + 1] + mount + text[eol + 1 :], encoding="utf-8")
print("Added SondeHub reporter hotfix volume to docker-compose.yml")
PY
}
