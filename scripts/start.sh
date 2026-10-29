#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f docker-compose.yml || ! -f .env ]]; then
  echo "Missing docker-compose.yml or .env — run ./install.sh first."
  exit 1
fi

# shellcheck disable=SC1091
source .env

echo "Starting OpenWebRX+ (${OWRX_CONTAINER_NAME})..."
docker compose up -d
echo
echo "Web UI: http://localhost:${OWRX_PORT}"
echo "Logs:   docker compose logs -f openwebrx"
