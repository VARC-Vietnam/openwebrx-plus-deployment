#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
cd "$ROOT"

if [[ ! -f docker-compose.yml || ! -f .env ]]; then
  echo "Missing docker-compose.yml or .env — run ./install.sh first."
  exit 1
fi

# shellcheck disable=SC1091
source .env

DOCKER="$(resolve_docker)" || { echo "Docker daemon not reachable."; exit 1; }
COMPOSE="$(resolve_compose "$DOCKER")" || { echo "Docker Compose not found (apt install docker-compose)."; exit 1; }

echo "Starting OpenWebRX+ (${OWRX_CONTAINER_NAME})..."
$COMPOSE up -d
echo
echo "Web UI: http://localhost:${OWRX_PORT}"
echo "Logs:   $COMPOSE logs -f openwebrx"
