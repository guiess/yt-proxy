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

If a fix has been merged and a new official image published, just pull and restart:
```bash
ssh azureuser@<VM_IP> 'cd /opt/yt-proxy && \
  docker compose -f docker-compose.yml -f docker-compose.vpn.yml pull companion && \
  docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d companion'
```

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

```bash
# Tag custom image to replace the official one
docker tag invidious-companion:custom quay.io/invidious/invidious-companion:latest

# Recreate the Companion container
cd /opt/yt-proxy
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d companion
```

### Step 4: Verify

```bash
# Wait ~30s for PO token generation, then check logs
docker compose logs companion --tail=20
```

Look for: `[INFO] Successfully generated PO token`

### Step 5: Revert to official image later

Once an official release includes the fix:
```bash
cd /opt/yt-proxy
docker compose -f docker-compose.yml -f docker-compose.vpn.yml pull companion
docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d companion
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
