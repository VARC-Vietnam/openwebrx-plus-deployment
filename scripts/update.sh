#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
quiet_interrupt_trap
cd "$ROOT"

if [[ ! -f docker-compose.yml || ! -f .env ]]; then
  echo "Missing docker-compose.yml or .env — run ./install.sh first."
  exit 1
fi

DOCKER="$(resolve_docker)" || { echo "Docker daemon not reachable."; exit 1; }
COMPOSE="$(resolve_compose "$DOCKER")" || { echo "Docker Compose not found."; exit 1; }

echo "Pulling latest image..."
$COMPOSE pull
$COMPOSE up -d
echo "Updated and restarted."
