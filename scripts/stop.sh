#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
cd "$ROOT"

if [[ ! -f docker-compose.yml ]]; then
  echo "Missing docker-compose.yml — run ./install.sh first."
  exit 1
fi

DOCKER="$(resolve_docker)" || { echo "Docker daemon not reachable."; exit 1; }
COMPOSE="$(resolve_compose "$DOCKER")" || { echo "Docker Compose not found."; exit 1; }

$COMPOSE down
echo "Stopped."
