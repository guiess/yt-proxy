#!/usr/bin/env bash
# companion-monitor.sh — record what invidious-companion is doing, every 5 minutes.
#
# Companion dies about once a day (RestartCount=14 over 14 days), taking every
# in-flight audiobook stream with it. There is no CI, no staging and no test
# suite here, so the only way to tell whether a fix worked is to watch
# production — and nothing was being recorded. Every past investigation
# therefore started from scratch, live, after the damage was done.
#
# This script closes that gap. It appends one line per run:
#
#   2026-08-15T02:05:00+0000 restarts=14 fds=193 health=none
#
# and that is its entire contract. Two of those numbers matter:
#
#   restarts — the crash counter. A rising value is the failure itself.
#   fds      — the leading indicator. Companion leaks eventpoll/eventfd pairs at
#              ~53.5 FDs per 1,000 videoplayback requests, so it walks into
#              EMFILE ("Os { code: 24 } Too many open files" → Rust panic) and
#              dies. Sampling the count is how we learn whether that leak is
#              still there after an upgrade — the ceiling raised by ticket #3
#              cannot change the *rate*, only how long it takes to matter.
#
# Two implementation details are easy to get wrong and make the whole thing
# useless, so they are called out here:
#
#   * FDs are counted from the HOST's /proc, not with `docker exec`. The
#     companion image is distroless — there is no shell inside to exec into.
#   * `docker inspect .State.Pid` returns the container's PID 1, which for this
#     image is the /tini init wrapper holding a grand total of 3 file
#     descriptors. The Deno process we actually care about
#     (/app/invidious_companion) is tini's *child*. Counting PID 1's FDs
#     reports "3" forever and hides the leak completely.
#
# The PID is re-resolved on every run, because it changes on every restart.
#
# This script is strictly READ-ONLY with respect to containers: it inspects and
# never mutates. Acting on the numbers is a separate concern and a separate
# script. It also always exits 0 — see the ERR trap below.
#
# Reading /proc/<pid>/fd requires being the owner of that process or root, and
# the companion process is not owned by azureuser. Install in the ROOT crontab
# (every 5 minutes). Unlike gluetun-watchdog.sh this script writes its own log
# file, so cron does not redirect anything:
#
#   ( sudo crontab -l 2>/dev/null; \
#     echo '*/5 * * * * /opt/yt-proxy/scripts/companion-monitor.sh >/dev/null 2>&1' \
#   ) | sudo crontab -
#
# The azureuser crontab (as used by gluetun-watchdog.sh) is the lower privilege
# and also works, but it reports `fds=NA` whenever it cannot read the container
# process's /proc entry — which is the one number this script exists to collect.
# Root is therefore the recommended install. The log stays world-readable, so
# azureuser can still tail it.
#
# Uninstall:
#   sudo crontab -l | grep -v companion-monitor | sudo crontab -
set -euo pipefail

# cron runs with a minimal PATH; make docker/date/flock reachable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CONTAINER="${COMPANION_CONTAINER:-yt-proxy-companion-1}"
LOG_FILE="${LOG_FILE:-/home/azureuser/companion-monitor.log}"
LOCK_FILE="${LOCK_FILE:-/tmp/companion-monitor.lock}"
# Test seam: overridden only by the development harness so the sampler can be
# exercised off-host. Always /proc in production.
PROC_DIR="${PROC_DIR:-/proc}"

# ~17 KB/day of samples, so 10 MB is over a year of history. One previous
# generation is kept, bounding this script's disk footprint at ~20 MB — a
# monitoring tool must never be the thing that fills the disk.
MAX_LOG_BYTES=10485760
UNAVAILABLE="NA"

# A monitoring job must never generate cron failure mail, and must never be
# mistaken for the outage it exists to observe. Every value below is
# individually defaulted to NA, so this trap only catches genuinely unexpected
# failures (a missing coreutils binary, an unwritable log). A permanently
# broken sampler is still detectable: it shows up as a gap in the log.
trap 'exit 0' ERR

# Reads one Go-template field from the container, or NA if it cannot be read.
inspect_field() {
  docker inspect --format "$1" "$CONTAINER" 2>/dev/null || printf '%s' "$UNAVAILABLE"
}

# The crash counter: Docker's RestartCount, or NA if it is not a plain integer.
restart_count() {
  local restarts
  restarts="$(inspect_field '{{.RestartCount}}')"

  if [[ "$restarts" =~ ^[0-9]+$ ]]; then
    printf '%s' "$restarts"
  else
    printf '%s' "$UNAVAILABLE"
  fi
}

# Docker's health status, or `none` when the container declares no healthcheck
# (which is the case until the healthcheck ticket lands). Whitespace is stripped
# because the log line is whitespace-delimited and must stay parseable.
health_status() {
  local health
  health="$(inspect_field '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  health="${health//[[:space:]]/}"
  printf '%s' "${health:-none}"
}

# Maps the container's PID 1 (the /tini wrapper) to the process that actually
# holds the file descriptors — its single child. Falls back to PID 1 for images
# that run the application directly, with no init wrapper.
resolve_worker_pid() {
  local init_pid="$1"
  local children_file="$PROC_DIR/$init_pid/task/$init_pid/children"
  local first_child=""

  if [ -r "$children_file" ]; then
    read -r first_child _ <"$children_file" || true
  fi

  if [[ "$first_child" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$first_child"
  else
    printf '%s' "$init_pid"
  fi
}

# Counts entries in /proc/<pid>/fd, or NA when that cannot be read — which
# happens legitimately when the process just exited or when this script is not
# running with enough privilege.
open_fd_count() {
  local fd_dir="$PROC_DIR/$1/fd"
  local count

  if [ ! -d "$fd_dir" ] || [ ! -r "$fd_dir" ]; then
    printf '%s' "$UNAVAILABLE"
    return 0
  fi

  # Counted with a glob rather than `ls | wc -l`: no subprocess to fail, and no
  # pipeline whose failure `set -o pipefail` would have to special-case.
  count="$(shopt -s nullglob; fd_entries=("$fd_dir"/*); printf '%s' "${#fd_entries[@]}")"
  # Any live process holds at least stdin/stdout/stderr, so a zero count means
  # it exited between the readability check and the listing.
  if [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$count"
  else
    printf '%s' "$UNAVAILABLE"
  fi
}

# Open file descriptors held by the companion process right now, or NA when
# there is nothing to count. The PID is resolved fresh on every call because it
# changes on every container restart.
current_fd_count() {
  local init_pid
  init_pid="$(inspect_field '{{.State.Pid}}')"

  # PID 0 means the container exists but has no running process — created,
  # restarting, or exited.
  if [[ "$init_pid" =~ ^[1-9][0-9]*$ ]]; then
    open_fd_count "$(resolve_worker_pid "$init_pid")"
  else
    printf '%s' "$UNAVAILABLE"
  fi
}

# Keeps exactly one previous generation once the log outgrows MAX_LOG_BYTES.
rotate_log_if_oversized() {
  local size
  size="$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)"

  if [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt "$MAX_LOG_BYTES" ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
  fi
}

# Appends the one line that is this script's entire public contract. Field
# order is fixed; any future field must be appended at the end so existing
# greps keep working.
append_sample() {
  rotate_log_if_oversized
  printf '%s restarts=%s fds=%s health=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" "$3" >>"$LOG_FILE"
}

# Overlapping runs should be impossible at a 5-minute cadence, but rotation is
# a read-then-rename that two runs could race. Take the lock when flock is
# available; a host without util-linux must still get its sample.
acquire_lock_or_exit() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCK_FILE" || return 0
  flock -n 9 || exit 0
}

main() {
  # The stack being down is a legitimate state to record, not an error.
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    append_sample "$UNAVAILABLE" "$UNAVAILABLE" absent
    return 0
  fi

  append_sample "$(restart_count)" "$(current_fd_count)" "$(health_status)"
}

acquire_lock_or_exit
main
exit 0
