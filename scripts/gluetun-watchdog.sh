#!/usr/bin/env bash
# gluetun-watchdog.sh — auto-recover the VPN when gluetun wedges.
#
# Invidious and Companion share gluetun's network namespace
# (network_mode: "service:gluetun" in docker-compose.vpn.yml), so all of
# their DNS goes through gluetun. When gluetun's OpenVPN tunnel gets stuck
# in a restart loop (stale routes accumulate in its network namespace), the
# killswitch blocks every outbound packet — including DNS — and Invidious
# fails every request with:
#
#   Hostname lookup for www.youtube.com failed: Try again (Socket::Addrinfo::Error)
#
# Docker's `restart: unless-stopped` never fires because gluetun does not
# *exit* — it loops internally. And `docker compose restart` reuses the same
# (polluted) network namespace, so it doesn't help either. The only reliable
# fix is to *recreate* gluetun (fresh netns) together with the containers
# that share its network.
#
# This script detects a sustained-unhealthy gluetun and force-recreates the
# trio. It is safe to run from cron every few minutes: it only acts once
# gluetun has been failing its healthcheck for a while, so it ignores the
# brief unhealthy blips that happen during a normal VPN reconnect.
#
# Install (cron, every 5 minutes):
#   ( crontab -l 2>/dev/null; \
#     echo '*/5 * * * * /opt/yt-proxy/scripts/gluetun-watchdog.sh >> /home/azureuser/gluetun-watchdog.log 2>&1' \
#   ) | crontab -
set -euo pipefail

# cron runs with a minimal PATH; make docker/flock/etc. reachable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

GLUETUN="${GLUETUN_CONTAINER:-yt-proxy-gluetun-1}"
# These share gluetun's network namespace and must be recreated together.
SERVICES=(gluetun invidious companion)
# gluetun's healthcheck interval is 30s, so ~10 consecutive failures ≈ 5 min
# of sustained downtime — long enough to skip normal reconnect blips.
FAIL_THRESHOLD="${FAIL_THRESHOLD:-10}"
LOCK="/tmp/gluetun-watchdog.lock"

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

# Prevent overlapping runs (a recovery takes ~60s).
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another watchdog run is in progress; exiting."
  exit 0
fi

# If gluetun isn't running at all, there's nothing for this script to heal.
if ! docker inspect "$GLUETUN" >/dev/null 2>&1; then
  log "container $GLUETUN not found; nothing to do."
  exit 0
fi

health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$GLUETUN")"
streak="$(docker inspect --format '{{if .State.Health}}{{.State.Health.FailingStreak}}{{else}}0{{end}}' "$GLUETUN")"

if [ "$health" != "unhealthy" ] || [ "${streak:-0}" -lt "$FAIL_THRESHOLD" ]; then
  # Healthy, starting, or only briefly failing — leave it alone.
  exit 0
fi

log "gluetun unhealthy (FailingStreak=$streak >= $FAIL_THRESHOLD) — recovering."

# Rebuild the exact `-f` overlay set from the labels compose stamped on the
# container, so we recreate with the same config that was deployed
# (base + vpn [+ patch]), regardless of what is checked out in git.
project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$GLUETUN")"
cfg="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$GLUETUN")"
workdir="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$GLUETUN")"
workdir="${workdir:-/opt/yt-proxy}"

fargs=()
IFS=',' read -ra files <<< "$cfg"
for f in "${files[@]}"; do
  [ -n "$f" ] && fargs+=(-f "$f")
done
# Fallback if the label was empty for some reason.
if [ "${#fargs[@]}" -eq 0 ]; then
  fargs=(-f "$workdir/docker-compose.yml" -f "$workdir/docker-compose.vpn.yml")
fi

cd "$workdir"
log "recreating (project=$project): docker compose ${fargs[*]} up -d --force-recreate ${SERVICES[*]}"
if docker compose -p "${project:-yt-proxy}" "${fargs[@]}" --project-directory "$workdir" \
     up -d --force-recreate "${SERVICES[@]}"; then
  log "recovery command completed; waiting for gluetun to become healthy…"
else
  log "ERROR: recovery command failed."
  exit 1
fi

# Give the tunnel up to ~2 min to establish and pass the healthcheck.
for _ in $(seq 1 24); do
  sleep 5
  h="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$GLUETUN" 2>/dev/null || echo gone)"
  if [ "$h" = "healthy" ]; then
    log "gluetun healthy again after recovery."
    exit 0
  fi
done
log "WARN: gluetun still not healthy 2 min after recovery — may need manual attention."
exit 1
