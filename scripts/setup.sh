#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Invidious setup ==="

# Generate .env from template if it doesn't exist
if [ ! -f .env ]; then
  cp .env.example .env
  # Generate random secrets
  sed -i "s/^HMAC_KEY=$/HMAC_KEY=$(openssl rand -hex 32)/" .env
  sed -i "s/^POSTGRES_PASSWORD=$/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
  sed -i "s/^COMPANION_KEY=$/COMPANION_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)/" .env
  echo "Created .env with generated secrets."
  echo ">>> Edit .env to set DOMAIN and ACME_EMAIL before starting! <<<"
else
  echo ".env already exists, skipping."
fi

# Fetch Invidious DB init files
INVIDIOUS_REPO="https://raw.githubusercontent.com/iv-org/invidious/master"

echo "Fetching database init files from Invidious repo..."
mkdir -p config/sql docker

curl -fsSL "$INVIDIOUS_REPO/docker/init-invidious-db.sh" -o docker/init-invidious-db.sh
chmod +x docker/init-invidious-db.sh

# The init script references SQL files — fetch them all
SQL_FILES=(
  annotations.sql
  channel_videos.sql
  channels.sql
  nonces.sql
  playlist_videos.sql
  playlists.sql
  session_ids.sql
  users.sql
  videos.sql
)

for f in "${SQL_FILES[@]}"; do
  curl -fsSL "$INVIDIOUS_REPO/config/sql/$f" -o "config/sql/$f"
done

echo "Database init files downloaded."
echo ""
echo "=== Setup complete ==="
echo "Next steps:"
echo "  1. Edit .env — set DOMAIN and ACME_EMAIL"
echo "  2. Point your domain's DNS A record to this server's IP"
echo "  3. Run: docker compose up -d"
