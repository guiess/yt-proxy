#!/usr/bin/env bash
# Daily restart recommended by Invidious docs to clear stale state.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[$(date)] Daily restart..."
docker compose restart invidious companion
echo "[$(date)] Restart complete."
