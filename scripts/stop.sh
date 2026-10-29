#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f docker-compose.yml ]]; then
  echo "Missing docker-compose.yml — run ./install.sh first."
  exit 1
fi

docker compose down
echo "Stopped."
