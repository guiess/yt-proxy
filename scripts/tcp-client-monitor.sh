#!/usr/bin/env bash
# tcp-client-monitor.sh — record the quality of each client's TCP connection.
#
# The audiobook stutter that survived the companion fix is not a server
# problem: the VM serves the same file at 4-6 MB/s while the stream itself
# needs ~15 KB/s. The bottleneck is the 151 ms path to the listener, and the
# only way to tell *which* part of that path misbehaves is to look at the
# kernel's own view of the connection while playback is happening.
#
# Nothing was recording that, so every investigation so far has been inference
# from request timing. This script records the facts instead. One line per
# established HTTPS connection per sample:
#
#   2026-08-16T15:30:00+0000 peer=185.134.151.90 rtt=150.9 rttvar=0.3 \
#     cwnd=10 ssthresh=NA retrans=0 total_retrans=0 delivery_rate=1234567 \
#     pacing_rate=2345678 bytes_acked=98765 cc=bbr
#
# The fields that matter, and what a bad value means:
#
#   cwnd           — congestion window in MSS. This is the whole reason the
#                    script exists. If cwnd sits near 10 (the initial window)
#                    during steady streaming, the kernel is throwing the window
#                    away between segment fetches and every request pays a slow
#                    start ramp — at 151 ms RTT that is ~1.1 s of dead time per
#                    segment, which is exactly what starves the player buffer.
#                    A healthy streaming connection should show cwnd well above
#                    the initial window and stable.
#   retrans        — retransmits currently outstanding. Sustained non-zero means
#                    real loss, which would point at the path rather than cwnd.
#   delivery_rate  — what the connection actually achieved, in bytes/sec. Compare
#                    against the ~15 KB/s the audio track needs; anything near
#                    that is a stall in progress.
#   rttvar         — jitter. Idle measurement was 0.29 ms; a large value here
#                    under load means queueing somewhere on the path.
#   cc             — congestion control in use, to confirm BBR is actually
#                    applied to real connections and not just set in sysctl.
#
# `ss -ti` prints two lines per socket (address line, then an indented metrics
# line), so the parser pairs them up rather than reading line-by-line.
#
# IMPORTANT: Caddy runs in its own network namespace, so the host's `ss` sees
# NONE of these sockets — it returns an empty list and the log looks like
# "no clients" forever. The sampler therefore enters Caddy's netns with
# nsenter. That needs root, hence the ROOT crontab below.
#
# Sampling every 5 s for 55 s means a once-a-minute cron entry yields ~11
# samples per minute, which is fine-grained enough to catch a rebuffer event.
# A plain */5 cron would only ever see one instant in every 300 s and would
# almost certainly miss the stalls entirely.
#
# Install (ROOT crontab — nsenter requires it):
#
#   ( sudo crontab -l 2>/dev/null; \
#     echo '* * * * * /opt/yt-proxy/scripts/tcp-client-monitor.sh >/dev/null 2>&1' \
#   ) | sudo crontab -
#
# Uninstall:
#   sudo crontab -l | grep -v tcp-client-monitor | sudo crontab -
#
# This script is strictly READ-ONLY: it inspects socket state and never changes
# it. It always exits 0 so a parsing failure can never make cron noisy.
set -euo pipefail

# cron runs with a minimal PATH; make ss/date/nsenter/docker reachable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOG="${TCP_MONITOR_LOG:-/home/azureuser/tcp-client-monitor.log}"
CONTAINER="${TCP_MONITOR_CONTAINER:-yt-proxy-caddy-1}"
PORT="${TCP_MONITOR_PORT:-443}"
SAMPLES="${TCP_MONITOR_SAMPLES:-11}"
INTERVAL="${TCP_MONITOR_INTERVAL:-5}"
MAX_LOG_BYTES="${TCP_MONITOR_MAX_BYTES:-10485760}" # 10 MB, keep one generation

# Never let a failure here surface as a cron error mail; the log is the product.
trap 'exit 0' ERR

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# Keep the log bounded without needing a logrotate config to be installed and
# then forgotten. One rename, one generation, ~20 MB worst case.
rotate_if_needed() {
    local size
    size=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$MAX_LOG_BYTES" ]; then
        mv -f "$LOG" "$LOG.1" 2>/dev/null || true
    fi
}

# Pull one field out of an `ss -ti` metrics line. Values look like `rtt:150.9/0.3`
# or `cwnd:10`, so the caller says which piece it wants.
field() {
    local text="$1" key="$2"
    printf '%s\n' "$text" | grep -oE "(^| )${key}:[^ ]+" | head -1 | cut -d: -f2- || true
}

# A few of the most useful metrics are printed space-separated rather than
# colon-separated (`pacing_rate 1205656bps`, `delivery_rate 841704bps`, `send
# 602832bps`), so they need their own extractor. The trailing unit is stripped
# to keep the log numeric and greppable.
field_sp() {
    local text="$1" key="$2"
    printf '%s\n' "$text" | grep -oE "(^| )${key} [0-9]+[a-zA-Z]*" | head -1 \
        | awk '{print $2}' | tr -d 'a-zA-Z' || true
}

# `ss -ti` emits an address line followed by an indented metrics line. Pair them
# so each output row describes one socket. Runs inside the proxy container's
# network namespace, which is where the client sockets actually live.
sample_once() {
    local ts peer info line addr_line="" nspid
    ts="$(timestamp)"

    # The PID changes whenever the container is recreated, so resolve it every
    # sample rather than caching it.
    nspid=$(docker inspect --format '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || echo "")
    case "$nspid" in
        ''|*[!0-9]*|0) return 0 ;;   # container gone or not running — skip quietly
    esac

    nsenter -t "$nspid" -n ss -tin state established "( sport = :${PORT} )" 2>/dev/null | tail -n +2 | \
    while IFS= read -r line; do
        case "$line" in
            [[:space:]]*)
                # Metrics line — belongs to the address line we just stored.
                [ -n "$addr_line" ] || continue
                info="$line"
                # Address line looks like:
                #   0  0  [::ffff:172.18.0.4]:443  [::ffff:173.178.171.4]:51742
                # Field 4 is the peer. Strip the brackets, the :port suffix and
                # the IPv4-mapped-IPv6 prefix so the value is a plain IP.
                peer=$(printf '%s\n' "$addr_line" \
                    | awk '{print $4}' \
                    | sed -e 's/^\[//' -e 's/\]:[0-9]*$//' -e 's/:[0-9]*$//' -e 's/^::ffff://')
                [ -n "$peer" ] || peer=NA

                local rtt rttvar cwnd ssth retr totretr drate prate backed cc
                rtt=$(field "$info" rtt | cut -d/ -f1)
                rttvar=$(field "$info" rtt | cut -d/ -f2)
                cwnd=$(field "$info" cwnd)
                ssth=$(field "$info" ssthresh)
                retr=$(field "$info" retrans | cut -d/ -f1)
                totretr=$(field "$info" retrans | cut -d/ -f2)
                drate=$(field_sp "$info" delivery_rate)
                prate=$(field_sp "$info" pacing_rate)
                backed=$(field "$info" bytes_acked)
                # The cc algorithm is a bare word, not a key:value pair.
                cc=$(printf '%s\n' "$info" | grep -oE '(^| )(bbr|cubic|reno|bbr2)( |$)' | head -1 | tr -d ' ')

                printf '%s peer=%s rtt=%s rttvar=%s cwnd=%s ssthresh=%s retrans=%s total_retrans=%s delivery_rate=%s pacing_rate=%s bytes_acked=%s cc=%s\n' \
                    "$ts" "$peer" "${rtt:-NA}" "${rttvar:-NA}" "${cwnd:-NA}" \
                    "${ssth:-NA}" "${retr:-0}" "${totretr:-0}" "${drate:-NA}" \
                    "${prate:-NA}" "${backed:-NA}" "${cc:-NA}"
                addr_line=""
                ;;
            *)
                addr_line="$line"
                ;;
        esac
    done
}

main() {
    rotate_if_needed
    local i=0
    while [ "$i" -lt "$SAMPLES" ]; do
        sample_once >> "$LOG" 2>/dev/null || true
        i=$((i + 1))
        [ "$i" -lt "$SAMPLES" ] && sleep "$INTERVAL"
    done
}

main
exit 0
