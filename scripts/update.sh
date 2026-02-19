#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[$(date)] Pulling latest images..."
docker compose pull

echo "[$(date)] Recreating containers with new images..."
docker compose up -d --remove-orphans

echo "[$(date)] Removing old images..."
docker image prune -f

echo "[$(date)] Update complete."
