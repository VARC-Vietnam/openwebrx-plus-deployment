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
