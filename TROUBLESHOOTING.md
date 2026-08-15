# Troubleshooting: "The page needs to be reloaded" error

## Symptoms

- Video listing/search works, but playing any video fails
- Invidious shows "The page needs to be reloaded" on the video page
- Invidious logs: `get_video: <ID> : The page needs to be reloaded.` with HTTP 500
- Companion logs: `Failed to validate PO token: all validation attempts returned non-200 status codes`
  or `exportedVars.nFunction is not a function`

## Root cause

YouTube periodically changes its player JavaScript structure, breaking the signature
and nsig extraction logic in [YouTube.js](https://github.com/LuanRT/YouTube.js) —
the library that Invidious Companion depends on for video stream deciphering.

This is a **global issue** affecting all Invidious instances, not specific to our
deployment or VPN IP.

## Diagnosis

1. SSH into the VM and check Companion logs:
   ```bash
   ssh azureuser@<VM_IP> 'cd /opt/yt-proxy && docker compose logs companion --tail=50'
   ```
2. Look for these error patterns:
   - `Failed to validate PO token` — YouTube.js can't decipher the new player
   - `No valid format found for video` — same root cause
   - `exportedVars.nFunction is not a function` — YouTube.js extraction matchers are outdated
   - `Successfully generated PO token` — means Companion is healthy, issue is elsewhere

## Check if the issue is already resolved upstream

1. **Companion releases** — check if a new image exists:
   https://github.com/iv-org/invidious-companion/pkgs/container/invidious-companion

2. **Companion issue tracker** — look for open/recently closed issues:
   https://github.com/iv-org/invidious-companion/issues

3. **Key issues to watch:**
   - Signature extraction: https://github.com/iv-org/invidious-companion/issues/274
   - "Page needs to be reloaded": https://github.com/iv-org/invidious-companion/issues/286
   - YouTube.js fix PR: https://github.com/LuanRT/YouTube.js/pull/1148

4. **YouTube player IDs** (useful to check if old players are retired):
   https://youtube-player-ids.nadeko.net/

If a fix has been merged and a new official image published, bump the pinned tag.
`docker-compose.yml` pins companion to an **immutable** tag, so `pull` alone will
never upgrade it — that is deliberate (see the warning below):

```bash
# 1. Pick the newest tag from the registry (they sort chronologically):
curl -s 'https://quay.io/api/v1/repository/invidious/invidious-companion/tag/?onlyActiveTags=true&limit=5' \
  | grep -o '"name": "[^"]*"'

# 2. Record the digest you are running now — this is the rollback anchor:
ssh azureuser@<VM_IP> "docker inspect --format '{{.Image}}' yt-proxy-companion-1"

# 3. Edit the `image:` line in docker-compose.yml, commit, then on the VM:
ssh azureuser@<VM_IP> 'cd /opt/yt-proxy && git pull && \
  docker compose -f docker-compose.yml -f docker-compose.vpn.yml pull companion && \
  docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d companion'

# 4. Verify what actually landed matches the registry:
ssh azureuser@<VM_IP> "docker inspect --format '{{.Image}}' yt-proxy-companion-1"
```

Rollback is the same procedure with the previously recorded tag/digest — no rebuild,
under 5 minutes.

## Workaround: build Companion from a fix branch

When YouTube.js is broken but a fix exists in a PR/branch that hasn't been released yet,
build a custom Companion image from that branch.

### Step 1: Find the fix branch

Check for open PRs on the Companion repo that reference YouTube.js updates:
https://github.com/iv-org/invidious-companion/pulls

For the March 2026 incident, the fix was in PR #287 (`use-pr-1148` branch), which
pointed YouTube.js imports to a patched fork at `iv-org/YouTube.js`.

### Step 2: Build custom image on the VM

```bash
# SSH into the VM
ssh azureuser@<VM_IP>

# Clone the fix branch (replace branch name as needed)
cd /tmp && rm -rf invidious-companion
git clone --depth 1 --branch use-pr-1148 https://github.com/iv-org/invidious-companion.git

# Build the custom image
cd invidious-companion
docker build -t invidious-companion:custom .
```

Build takes ~30-60 seconds on the B2s VM.

### Step 3: Deploy

> ⚠️ **Never `docker tag` a local build over an official image tag.**
> A previous version of this runbook said to run
> `docker tag invidious-companion:custom quay.io/invidious/invidious-companion:latest`.
> **Do not do that.** It leaves a locally built image squatting on the official tag, which:
> * makes `docker compose pull` a **silent no-op** — you think you upgraded, you did not;
> * makes it impossible to say what code is running, because the tag no longer
>   corresponds to anything in the registry; and
> * survives reboots and image prunes, so it misleads the *next* investigation too.
>
> This actually happened here: the March 2026 custom build shadowed `:latest` and the
> deployment silently ran a ~5-month-old companion. `docker-compose.yml` now pins an
> immutable tag for exactly this reason.

Deploy the custom build through a **temporary overlay** instead, mirroring how
[`docker-compose.patch.yml`](docker-compose.patch.yml) does it for Invidious. The custom
image keeps its own name and never impersonates an official one:

```bash
cd /opt/yt-proxy

# Temporary, local-only overlay — do not commit it.
cat > docker-compose.companion-custom.yml <<'YAML'
services:
  companion:
    image: invidious-companion:custom
YAML

# The custom overlay must come LAST so its image: wins.
docker compose -f docker-compose.yml -f docker-compose.vpn.yml \
  -f docker-compose.companion-custom.yml up -d companion
```

Remember that every later `docker compose` command for this stack must include the same
`-f` list while the overlay is in use, or compose will revert companion to the pinned tag.

### Step 4: Verify

```bash
# Wait ~30s for PO token generation, then check logs
docker compose logs companion --tail=20
```

Look for: `[INFO] Successfully generated PO token`

### Step 5: Revert to official image later

Once an official release includes the fix, drop the overlay and bump the pinned tag in
`docker-compose.yml` to the release that carries it:

```bash
cd /opt/yt-proxy
rm -f docker-compose.companion-custom.yml

# git pull the commit that bumps the pinned tag, then recreate without the overlay:
docker compose -f docker-compose.yml -f docker-compose.vpn.yml pull companion
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d companion

# Clean up the local build so it cannot be confused with an official image later:
docker image rm invidious-companion:custom
```

## Azure VM access

```bash
# Check VM status and current public IP
az vm show -g RG-YT-PROXY -n vm-yt-proxy --show-details -o json

# FQDN (stable, doesn't change with IP):
# ytprx2.uaenorth.cloudapp.azure.com
```

## Other known issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Search/video return HTTP 400 | YouTube blacklisted the hard-coded WEB client version | See "Search & video return HTTP 400" section below |
| Every page fails with `Socket::Addrinfo::Error` ("Try again") | gluetun VPN tunnel wedged → killswitch blocks DNS | See "VPN tunnel wedged → DNS lookups fail" section below |
| Video hangs, then plays after delay | QUIC blocked by ISP | Already fixed: QUIC disabled in Caddyfile |
| VPN connection drops hourly | OpenVPN key renegotiation | Already fixed: `--reneg-sec 0` in gluetun config |
| Signed URL IP mismatch | Companion/Invidious use different IPs | Already fixed: both share gluetun network namespace |

---

# Search & video return HTTP 400 ("Youtube API returned status code 400")

## Symptoms

- Searching, opening channels/playlists, **and** playing videos all fail
- Invidious shows: `Error: non 200 status code. Youtube API returned status code 400.`
- Started suddenly with **no config change** on our side

## Root cause

On 2026-07-22 YouTube blacklisted the specific **WEB InnerTube client version** that
Invidious hard-codes (`2.20250222.10.00`). Every InnerTube request made with that WEB
client — search, browse, and video — now returns HTTP 400 (`Request contains an invalid
argument`).

- **Global** — breaks all public and private instances, including home IPs, so the VPN
  overlay does **not** help.
- **Different** from the "page needs to be reloaded" incident above: PO-token generation
  still works; this is the metadata/WEB client, not the player deciphering.
- Upstream tracking issue: https://github.com/iv-org/invidious/issues/5817
  (community diagnosis: bumping `X-Youtube-Client-Version` → HTTP 200).

The version is a **compile-time constant** in `src/invidious/yt_backend/youtube_api.cr`
(`HARDCODED_CLIENTS`, `ClientType::Web` and `ClientType::WebScreenEmbed`). It is **not**
configurable via env/YAML.

## Fix: build a patched Invidious image

Because the version is baked into the compiled binary, we patch the string **in place**
in the prebuilt image — a same-length (16-char) replacement that preserves all binary
offsets, so **no recompile is needed**. A full source rebuild is avoided on purpose:
Invidious's build runs `crystal spec`, which itself calls YouTube and fails during this
very outage, and the static build is memory-heavy on the B2s VM.

The patch lives in [`docker/invidious/Dockerfile`](docker/invidious/Dockerfile) and is
wired up by [`docker-compose.patch.yml`](docker-compose.patch.yml).

### Step 1 — Pick a current WEB client version

WEB versions are date-based `2.YYYYMMDD.rr.rr` and **must be exactly 16 characters**.
Capture the live value from a normal browser:
F12 → Network → click any `youtubei/v1/...` request → Request Headers → copy
`X-Youtube-Client-Version` (e.g. `2.20260721.01.00`).

### Step 2 — Build & deploy on the VM

```bash
ssh azureuser@<VM_IP>
cd /opt/yt-proxy && git pull

# No VPN:
WEB_CLIENT_VERSION=2.20260721.01.00 \
  docker compose -f docker-compose.yml -f docker-compose.patch.yml \
  up -d --build invidious

# With the VPN overlay (the patch overlay must come LAST):
WEB_CLIENT_VERSION=2.20260721.01.00 \
  docker compose -f docker-compose.yml -f docker-compose.vpn.yml -f docker-compose.patch.yml \
  up -d --build invidious
```

### Step 3 — Verify

```bash
docker compose logs invidious --tail=20
```

Then open the site and run a search — results should load (HTTP 200).

If the build fails with **"old WEB client version not found in binary"**, upstream has
already changed the version in the `:latest` image — skip the patch and just pull the
stock image (see revert below).

## Revert to the official image once upstream ships a fix

Watch https://github.com/iv-org/invidious/issues/5817 and the image registry. Once a
fixed `:latest` is published, simply **drop the patch overlay** — the base compose file
already points at the official image:

```bash
cd /opt/yt-proxy
docker compose -f docker-compose.yml pull invidious            # add -f docker-compose.vpn.yml if using VPN
docker compose -f docker-compose.yml up -d invidious           # add -f docker-compose.vpn.yml if using VPN
```

---

# VPN tunnel wedged → DNS lookups fail ("Socket::Addrinfo::Error")

## Symptoms

- Search, trending, channels — **every** page — fail immediately
- Invidious shows / logs:
  `Hostname lookup for www.youtube.com failed: Try again (Socket::Addrinfo::Error)`
  with a backtrace through `socket/addrinfo.cr` → `http/client.cr`
- `docker ps` shows `yt-proxy-gluetun-1` **and** `yt-proxy-invidious-1` as `(unhealthy)`
- Appeared on its own with **no config change** — slow degradation, not a deploy

## Root cause

This deployment routes Invidious and Companion through the VPN by having them share
gluetun's network namespace (`network_mode: "service:gluetun"` in
[`docker-compose.vpn.yml`](docker-compose.vpn.yml)). All of their DNS therefore goes
through gluetun, and gluetun's killswitch blocks **all** traffic — including DNS —
whenever the tunnel is down.

Over time gluetun's OpenVPN tunnel can get stuck in a restart loop. OpenVPN connects to
the ProtonVPN node fine ("Initialization Sequence Completed") but fails to install its
route, because stale routes have piled up in the container's network namespace:

```
ERROR [openvpn] OpenVPN tried to add an IP route which already exists (RTNETLINK answers: File exists)
ERROR [MTU discovery] ... getting VPN route: VPN route not found: for interface tun0 in 23 routes
WARN  [vpn] restarting VPN because it failed to pass the healthcheck: ... lookup github.com: i/o timeout
```

The healthcheck then fails, gluetun restarts the VPN **inside the same namespace**, the
route is still there ("File exists"), and it loops forever (`FailingStreak` climbs into
the hundreds). The tunnel never comes up, so DNS stays dead → `Try again` / `EAI_AGAIN`.

This is **not** the same as the two issues above: nothing reaches YouTube at all, so it is
neither the WEB-client HTTP 400 nor the player-deciphering break.

## Diagnosis

```bash
ssh azureuser@<VM_IP>

# Are gluetun + invidious unhealthy?
docker ps --format 'table {{.Names}}\t{{.Status}}'

# Why is gluetun unhealthy? Look for the route-add loop.
docker logs --tail 80 yt-proxy-gluetun-1
docker inspect --format '{{.State.Health.FailingStreak}}' yt-proxy-gluetun-1
```

## Fix: recreate gluetun (fresh netns), not restart

A plain `docker compose restart gluetun` **does not work** — restart reuses the same
network namespace, so the polluted routing table (and the loop) survive. gluetun must be
**recreated** to get a clean namespace, and because Invidious and Companion share that
namespace they must be recreated together, in the same command:

```bash
cd /opt/yt-proxy
# Use the SAME overlays the stack was deployed with (base + vpn [+ patch]):
docker compose -f docker-compose.yml -f docker-compose.vpn.yml -f docker-compose.patch.yml \
  up -d --force-recreate gluetun invidious companion
```

(Drop `-f docker-compose.patch.yml` if the WEB-client patch isn't in use.)

### Verify

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'                 # all three healthy/up
docker exec yt-proxy-gluetun-1 wget -qO- https://api.ipify.org     # VPN egress IP prints
docker exec yt-proxy-invidious-1 wget -qO- http://127.0.0.1:3000/api/v1/trending | head -c 100
```

The trending call should return JSON (starts with `[{"type":"video"...`).

## Prevention: the gluetun watchdog

Because gluetun never *exits* when it wedges (it loops internally), Docker's
`restart: unless-stopped` policy never triggers, and the outage persists until someone
notices. [`scripts/gluetun-watchdog.sh`](scripts/gluetun-watchdog.sh) closes that gap: it
checks gluetun's health and, once it has been failing for a sustained period, runs the
force-recreate above automatically. Install it in cron (every 5 min):

```bash
( crontab -l 2>/dev/null; \
  echo '*/5 * * * * /opt/yt-proxy/scripts/gluetun-watchdog.sh >> /home/azureuser/gluetun-watchdog.log 2>&1' \
) | crontab -
```

The script recreates with whatever overlays the running stack was created with (read from
the compose labels), so it works with or without the VPN/patch overlays.
