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
