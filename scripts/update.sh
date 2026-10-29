#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f docker-compose.yml || ! -f .env ]]; then
  echo "Missing docker-compose.yml or .env — run ./install.sh first."
  exit 1
fi

echo "Pulling latest image..."
docker compose pull
docker compose up -d
echo "Updated and restarted."
