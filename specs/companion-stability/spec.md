# Feature Specification: Invidious Companion Playback Stability

**Feature Branch**: `001-companion-stability`
**Created**: 2026-08-15
**Status**: Draft (baseline bootstrapped from existing deployment — brownfield)
**Input**: User description: "for last several days when watching big audiobooks it constantly either stops or lags"

**Owner**: @guiess (single operator)
**Last updated**: 2026-08-15
**Issue tracker**: https://github.com/guiess/yt-proxy/issues
**Tickets**: #1 (monitor), #2 (image pin), #3 (ulimits), #4 (healthcheck), #5 (fetch tuning), #6 (watchdog — conditional), #7 (docs)

---

## Bootstrap note (read this first)

This is a **brownfield bootstrap**. No spec existed for the yt-proxy deployment before now. Sections
below marked *(baseline)* reverse-engineer **what the deployment does today** from the compose files,
Caddyfile, scripts, and TROUBLESHOOTING.md. Sections marked *(delta)* describe the change being
specified. The baseline is captured so future changes have something to evolve from — it records
observed behaviour, **not** necessarily intended behaviour. Please correct anything that
misrepresents intent before treating this as the source of truth.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Uninterrupted long-form listening (Priority: P1)

A listener plays a multi-hour audiobook through the Invidious instance. The player issues thousands
of DASH byte-range requests over the course of the session. Today, `invidious-companion` dies roughly
once a day; every death severs **all** in-flight range requests, so the player stalls, buffers, or
drops out entirely. A 5-minute video rarely overlaps a crash window; a 6-hour audiobook almost
always does. The listener should be able to complete a multi-hour session without a stall caused by
a companion process death.

**Why this priority**: This is the reported symptom and the entire reason for the work. Every other
story exists to make this one verifiable or durable.

**Independent Test**: Play a ≥3-hour audiobook end-to-end while sampling
`docker inspect --format '{{.RestartCount}}' yt-proxy-companion-1` every 5 minutes. Value must not
increase during the session.

**Acceptance Scenarios**:

1. **Given** the companion container has been running for ≥24 h and has served ≥8,000 videoplayback
   requests, **When** a listener streams a 3-hour audiobook to completion, **Then** `RestartCount`
   does not increase and the listener reports no mid-stream stall.
2. **Given** the stack is running normally, **When** 14 consecutive days elapse, **Then** the
   companion `RestartCount` delta is 0 and `docker compose logs companion` contains zero
   `Too many open files` and zero `Uncaught (in promise)` lines.
3. **Given** a crash nevertheless occurs, **When** the operator inspects the monitoring log, **Then**
   the log contains the FD count, restart count, and health status sampled in the 5 minutes before
   the crash, sufficient to classify the crash mode without re-running a live investigation.

---

### User Story 2 — The operator can tell whether a fix worked (Priority: P1)

There is no CI, no test framework, and no staging environment. The only way to know whether a change
helped is to observe the running system. Today nothing is recorded, so "is it fixed?" can only be
answered by a manual live investigation like the one that produced this spec.

**Why this priority**: Co-equal P1 with Story 1 and **sequenced before it**. Without a recorded
baseline, no subsequent change is attributable. This is the foundation ticket.

**Independent Test**: Install the sampler, wait 24 h, confirm the log contains ≥288 samples with
plausible FD counts, and confirm a baseline FD growth rate can be computed from it.

**Acceptance Scenarios**:

1. **Given** the sampler cron is installed, **When** 24 h elapse, **Then** a log file exists
   containing timestamped `restarts=`, `fds=`, and `health=` fields at ~5-minute intervals.
2. **Given** the companion container restarts, **When** the sampler next runs, **Then** it re-resolves
   the container PID (the PID changes on restart) and continues reporting a valid FD count rather
   than a blank or stale value.
3. **Given** 24 h of samples and the videoplayback request count for the same period, **When** the
   operator computes FD growth per 1,000 requests, **Then** the result is comparable against the
   pre-change baseline of **53.5 FDs per 1,000 requests** recorded in this spec.

---

### User Story 3 — Deterministic, reversible image provenance (Priority: P2)

The running companion image is a 2026-03-22 build while upstream is 2026-08-10. The repo's own
runbook instructs the operator to `docker tag <local-build> quay.io/invidious/invidious-companion:latest`,
and stale `invidious-companion:custom` / `:pr287` images from the March incident still exist on the
host. Consequently nobody can currently state with confidence what code is running, and
`docker compose pull` may be a no-op against a locally shadowed tag.

**Why this priority**: P2 rather than P1 because it does not by itself stop the crashes, but it gates
the credibility of every other conclusion — including whether the upstream fix is even present.

**Independent Test**: After deploy, compare the running container's image digest against the registry
manifest digest for the pinned tag; they must match.

**Acceptance Scenarios**:

1. **Given** the compose file pins an immutable tag, **When** the operator runs `docker compose up -d companion`,
   **Then** the running container's image digest equals the registry digest for that tag.
2. **Given** a regression is observed after upgrade, **When** the operator reverts the pinned tag to
   the previously recorded digest and redeploys, **Then** the prior version is restored in under
   5 minutes without a rebuild.

---

### User Story 4 — Graceful degradation instead of hard death (Priority: P2)

Even if the upstream fix removes the leak, the deployment should not sit one unnoticed regression
away from a hard crash. The FD ceiling should be high enough that a leak degrades slowly and
visibly rather than killing the process every ~42 hours.

**Why this priority**: Defence-in-depth. Retains value even if the leak is fully fixed upstream, and
is the only mitigation that works if the leak's true root cause turns out to be something else.

**Independent Test**: `docker inspect --format '{{json .HostConfig.Ulimits}}' yt-proxy-companion-1`
returns the configured values, and the host-side `/proc/<pid>/limits` confirms them.

**Acceptance Scenarios**:

1. **Given** the ulimits block is deployed, **When** the operator inspects the container,
   **Then** `HostConfig.Ulimits` reports `nofile` soft=65536 hard=65536 (not `null`).
2. **Given** the FD leak were to persist unchanged at the measured baseline rate, **When** the
   ceiling is 65536, **Then** the projected interval between EMFILE deaths is ≥120 days
   (vs 1.76 days today).

---

### Edge Cases

- **Companion restarted while gluetun is unhealthy or mid-recreate.** Companion uses
  `network_mode: "service:gluetun"`; starting it against a missing or replaced network namespace
  fails. Any automated recovery MUST check gluetun health first and defer to the existing
  gluetun watchdog when gluetun is the unhealthy party.
- **Both watchdogs fire in the same 5-minute window.** The existing `gluetun-watchdog.sh` recreates
  gluetun+invidious+companion together. A companion-only actor must not race it. Shared `flock` path
  is mandatory if a second watchdog is ever introduced.
- **Healthcheck re-enabled but process is wedged rather than exited.** Docker Engine does **not**
  restart containers merely for being `unhealthy` (see Architectural deltas). A healthy-looking
  restart policy will not recover a hang.
- **`AbortSignal.timeout` now spans a whole response body.** Post-#329 the entire body is one fetch
  under one timeout, where previously each ≤5 MB chunk had its own budget. A slow or very large
  transfer can now be cut mid-body.
- **Enabling retry without raising `TIMES`.** `@std/async` `retry` with `maxAttempts: 1` performs a
  single attempt — enabling retry alone is a silent no-op.
- **Image pull collides with a locally re-tagged image.** Must remove the shadowing local tag before
  pulling, or the pull silently resolves to the March build.
- **Zero-traffic periods.** FD growth is request-driven; a low-traffic observation window can produce
  a false "leak fixed" reading. Acceptance must normalise per 1,000 requests, not per day.

---

## Requirements *(mandatory)*

### Baseline requirements *(baseline — what the deployment already guarantees)*

- **FR-B01**: The stack MUST serve Invidious over HTTPS via Caddy at `${DOMAIN}`, routing
  `/companion/*` to companion:8282 and all other paths to invidious:3000.
- **FR-B02**: Invidious and companion MUST egress through the gluetun VPN by sharing its network
  namespace, so that signed googlevideo URLs and the requests that use them originate from one IP.
- **FR-B03**: HTTP/3 (QUIC) MUST remain disabled at Caddy (ISP-blocked; causes playback hangs).
- **FR-B04**: All long-running services MUST use `restart: unless-stopped`.
- **FR-B05**: A cron watchdog MUST detect a sustained-unhealthy gluetun and force-recreate
  gluetun+invidious+companion together, reconstructing the overlay list from compose labels.
- **FR-B06**: Secrets (`HMAC_KEY`, `POSTGRES_PASSWORD`, `COMPANION_KEY`, VPN credentials) MUST come
  from `.env` and MUST NOT be committed.

### Functional Requirements *(delta — this change)*

- **FR-001**: The deployment MUST record companion restart count, open file-descriptor count, and
  container health status at ~5-minute intervals to a durable log on the host.
- **FR-002**: The FD sampler MUST re-resolve the container PID on every run, because the PID changes
  on every restart.
- **FR-003**: The FD sampler MUST measure from the **host** `/proc/<pid>/fd`, because the companion
  image is distroless and `docker exec` is impossible.
- **FR-004**: The companion service MUST pin an immutable image tag (date-prefixed, e.g.
  `2026.08.10-16cf10e`). `:latest` MUST NOT be used for companion.
- **FR-005**: The deploy procedure MUST remove any locally re-tagged
  `quay.io/invidious/invidious-companion:latest` before pulling, and MUST verify the running
  container's digest against the registry digest afterwards.
- **FR-006**: The previously running image digest MUST be recorded before upgrade so rollback is a
  tag change rather than a rebuild.
- **FR-007**: The companion service MUST set an explicit `nofile` ulimit with **both** soft and hard
  values (65536/65536).
- **FR-008**: The `healthcheck: {disable: true}` block MUST be removed so the image's bundled
  `/healthz` health check is active, and its interval MUST be relaxed from the image default of 5 s
  to 30 s to match the convention used by gluetun, invidious, and rammerhead on this 2-vCPU host.
- **FR-009**: `NETWORKING_FETCH_TIMEOUT_MS` MUST be raised above the 30 000 default to account for
  the whole-body timeout introduced by upstream #329.
- **FR-010**: If fetch retry is enabled, `NETWORKING_FETCH_RETRY_TIMES` MUST be ≥2 and a non-zero
  backoff MUST be configured, otherwise the setting is a no-op.
- **FR-011**: TROUBLESHOOTING.md MUST document this incident as a fourth section following the
  existing symptoms / root cause / diagnosis / fix / prevention structure.
- **FR-012**: TROUBLESHOOTING.md MUST carry an explicit warning against re-tagging local builds over
  the official image tag, replacing the current Step 3 guidance.
- **FR-013**: Automated recovery for companion, **if** introduced, MUST verify gluetun is healthy
  before acting and MUST share a lock with `gluetun-watchdog.sh`.
- **FR-014**: No change may introduce a memory limit on companion without first measuring steady-state
  RSS — evidence shows `OOMKilled=false`, so memory is not implicated and an unmeasured limit would
  add a new failure mode.

### Key Entities

- **companion container** — stateless HTTP proxy between Invidious and googlevideo. No persistent
  volume. Identity: `yt-proxy-companion-1`. Its PID is unstable across restarts.
- **monitoring log** — append-only, host-local, one line per sample: timestamp, restart count, FD
  count, health status. Not rotated by default; rotation is in scope for the sampler ticket.
- **pinned image reference** — tag plus recorded digest; the unit of rollback.

---

## Success Criteria *(mandatory)*

### Measured baseline (2026-08-01 → 2026-08-15, 14 days)

| Metric | Baseline value |
|---|---|
| Companion restarts | **14** (RestartCount, `ExitCode=0`, `OOMKilled=false`) |
| Crash cadence | ~**1.0 / day** |
| Videoplayback requests | **123,577** total ≈ **8,827 / day** |
| Crash mode 1 — `TimeoutError` unhandled rejection | 9 of 14, volume-independent (one after only 36 requests) |
| Crash mode 2 — EMFILE `Too many open files` | 5 of 14, clustered at **12,032–20,314** requests (mean 15,541) |
| Companion `nofile` soft limit | **1024** (Docker default; `HostConfig.Ulimits` = `null`) |
| Idle FD count | **193**, of which ~87 `eventpoll` + ~84 `eventfd` |
| Derived FD leak rate | **≈53.5 FDs per 1,000 videoplayback requests** (831 usable FDs / 15,541 requests) |
| Projected EMFILE interval at nofile=1024 | **1.76 days** |

### Measurable Outcomes

- **SC-001**: Companion `RestartCount` delta is **0 over a rolling 14-day window** after the final
  change lands (baseline: 14). A 7-day clean window is an early-confidence checkpoint but does not
  close the work.
- **SC-002**: Zero occurrences of `Too many open files` and zero `Uncaught (in promise)` in
  `docker compose logs companion` over the same 14-day window.
- **SC-003**: FD growth rate falls to **<5 FDs per 1,000 videoplayback requests** (>10× better than
  the 53.5 baseline). This is the criterion that determines whether the upstream image actually fixed
  the leak, and it is independent of the ulimit change — the ceiling does not affect the rate.
- **SC-004**: With `nofile=65536`, projected requests-to-EMFILE is **≥1.2 M** (≈138 days at the
  measured 8,827 req/day) even if the leak rate is entirely unchanged — a **78×** improvement over
  the 1.76-day baseline.
- **SC-005**: `docker inspect` reports the running companion image digest equal to the registry
  digest for the pinned tag (provenance unambiguous).
- **SC-006**: A ≥3-hour audiobook plays to completion with no companion-attributable stall, confirmed
  by the operator at least once after the changes land.
- **SC-007**: Rollback of any single change is demonstrated or documented to complete in **<5 minutes**
  without an image rebuild.
- **SC-008**: The monitoring log yields, for any crash that does occur, the FD/restart/health values
  from the preceding 5 minutes — i.e. no future incident requires a from-scratch live investigation.

---

## Assumptions

- The reported symptom ("audiobooks stop or lag") is caused by companion process deaths severing
  in-flight range requests. Corroborated by Caddy `aborting with incomplete response` warnings
  against `gluetun:8282`, and by the correlation between session length and stall probability.
  [NEEDS CLARIFICATION: no client-side telemetry exists; correlation is inferred, not proven per-session.]
- Request volume stays roughly at the measured ~8,827 videoplayback requests/day. Projections in
  SC-004 scale inversely with volume.
- Memory is not implicated: 1.7 GB available, `OOMKilled=false` on every container.
- The VPN is not implicated: gluetun 0 reconnects in 7 days, watchdog log empty, ~72 Mbit/s measured
  through the tunnel versus ~411 Mbit/s direct — far more than 360p DASH requires.
- The previously resolved WEB InnerTube HTTP 400 issue is out of scope; `docker-compose.patch.yml`
  is not deployed and stays undeployed.
- `COMPANION_PORT` and `COMPANION_HOST` in the compose file are believed **inert** — the application
  reads `PORT` and `HOST` (the image sets those to 8282/0.0.0.0), so current behaviour is correct by
  coincidence rather than by configuration. `COMPANION_INNER_TUBE_FORCE_LOCATION` does not appear in
  the upstream config schema either. [NEEDS CLARIFICATION: confirm on the VM before removing; treated
  as documentation cleanup, not a blocker.]
- The operator accepts short, scheduled interruptions to deploy fixes, but the acceptable window is
  **not yet agreed** — see Open Decisions D1.
- Single operator, no on-call rotation, no formal SLA.

---

## Decomposition

### Module map

| Module | Purpose (single responsibility) | Tickets |
|---|---|---|
| **A — Observability foundation** | Make the system's failure signals measurable before changing anything | #1 |
| **B — Companion runtime hardening** | Change what the companion runs and the limits it runs under | #2, #3, #4, #5 |
| **C — Automated recovery** | Recover from failure modes the restart policy cannot handle | #6 *(conditional)* |
| **D — Operational knowledge** | Ensure the next incident is diagnosed from docs, not from scratch | #7 |

### Component map

| Component | Single responsibility | Interface / contract | Depends on |
|---|---|---|---|
| `scripts/companion-monitor.sh` | Sample and append companion restart/FD/health metrics | **In:** container name (env, default `yt-proxy-companion-1`). **Out:** one line per run appended to `/home/azureuser/companion-monitor.log`: `<iso8601> restarts=<int> fds=<int> health=<str>`. **Errors:** container absent → log `fds=NA health=absent`, exit 0 (never fail cron). | Docker CLI; host `/proc`; cron |
| `companion` service definition (compose) | Declare the companion runtime: image, limits, health, config | **In:** `.env`. **Out:** a running container. **Contract:** pinned tag; `ulimits.nofile` 65536/65536; healthcheck active at 30 s; fetch env vars. | gluetun (netns), invidious (consumer) |
| `scripts/companion-watchdog.sh` *(conditional)* | Recover a companion that is **unhealthy but not exited** | **In:** Docker health status + gluetun health. **Out:** at most one `docker compose up -d companion` per lock interval. **Precondition:** gluetun healthy. **Lock:** shares `/tmp/gluetun-watchdog.lock`. | gluetun-watchdog.sh (lock); Docker health (#4) |
| `TROUBLESHOOTING.md` §4 | Explain this failure mode and its fix to a future operator | **In:** this spec + monitoring log. **Out:** symptoms / root cause / diagnosis / fix / prevention, matching the existing three sections. | All of the above |

### Sequencing and dependencies

- **Phase 0 (foundation, zero downtime):** **#1** — install the sampler and collect ≥24 h of baseline
  *before* changing anything. Without this, no later change is attributable.
- **Phase 1 (the fix, needs one restart window):** **#2** (pin + upgrade image) and **#3** (ulimits).
  These MAY share a single window without losing attributability: the ulimit raises the *ceiling*
  while SC-003 measures the *rate*, and the two are independent. This deliberately saves a downtime
  window relative to a strict one-change-per-window rule.
- **Phase 2 (needs a further window, after ≥24 h clean):** **#4** (healthcheck) then **#5** (fetch
  tuning). Separate from Phase 1 because #5 changes request behaviour and must be attributable on its
  own.
- **Phase 3 (conditional / deferred):** **#6** — build only if the trigger condition in that ticket
  is actually observed. Do not build speculatively.
- **Phase 4 (parallel, no downtime):** **#7** — documentation; finalise once Phase 1–2 results are known.

### Decomposition rationale

The dominant constraint is that **there is no CI, no tests, and no staging** — every verification is
an observation of production over days. That makes *attributability* the scarce resource, and it
drives two decisions. First, observability is sequenced **before** the fix rather than alongside it,
inverting the Delivery Guardian's proposed order: a fix deployed without a baseline cannot be proven
to have worked. Second, changes are split so each has a distinct, independently checkable signal,
except where analysis shows two changes cannot confound each other (#2 and #3), where they are
deliberately merged into one window to reduce user-visible downtime.

The alternative considered was a single "fix companion stability" ticket. It was rejected because the
five sub-changes have materially different risk profiles and rollback procedures — an image upgrade
carries real regression risk across ~5 months of upstream change, whereas a ulimit raise is inert
until a container restart. Bundling them would make a regression unattributable across a 5-month
upstream diff.

The watchdog (#6) is deliberately **deferred rather than dropped**. The evidence shows companion
*exits* (`ExitCode=0`, `RestartCount=14`), which `restart: unless-stopped` already handles; there is
no observed hang-without-exit. Building a watchdog now would solve an unobserved problem. It is
specified with an explicit trigger so the option stays open without wasting work.

---

## Guardian Consultation Results

### Code Review Guardian (architectural impact)

- **Watchdog partly redundant; prefer runtime-provided capability** *(SOLID/SRP — "don't build what
  the runtime already provides")*. **Accepted with a correction** — see Architectural deltas: the
  Guardian's stated mechanism (Docker auto-restarts unhealthy containers after ~35 s) is **incorrect**
  for plain Docker Engine. The conclusion (defer the watchdog) still holds, but for a different
  reason: companion *exits*, and the existing restart policy already covers exits.
- **Raising `nofile` masks rather than fixes the leak; verify FD trend before relying on it.**
  Accepted — drove SC-003 (rate, not ceiling) as the criterion that distinguishes the two.
- **`AbortSignal` now spans the whole response body post-#329** — a behavioural regression versus the
  ≤5 MB-per-chunk model. Accepted → FR-009.
- **Retry with `maxAttempts=1` is a no-op; zero backoff doubles instantaneous load on 2 vCPU.**
  Accepted → FR-010.
- **Image provenance cleanup is missing from the proposal** — stale local tags must be removed and the
  digest verified. Accepted → FR-005, FR-006.
- **Two watchdogs on shared-netns containers create a race** — must share a lock and check gluetun
  health first. Accepted → FR-013.
- **Restart-storm risk on 2 vCPU** if a fast healthcheck drives rapid churn. Accepted → FR-008
  relaxes the image's 5 s interval to 30 s.

### Platform Guardian

- **Always set both `soft` and `hard`** in `ulimits.nofile`; the long form is required when specifying
  both. Accepted → FR-007.
- **Per-service ulimits, not `/etc/docker/daemon.json` `default-ulimits`** — daemon-level defaults
  would raise the ceiling for postgres, caddy, and gluetun too, which none of them need. Accepted;
  blast radius stays scoped to companion.
- **`ulimits` are unaffected by `network_mode: "service:gluetun"`** — that shares only the network
  namespace; FD limits are per-process. Accepted; removes a suspected blocker.
- **Kernel headroom is not a constraint**: `fs.nr_open` default 1,048,576 ≫ 65,536; ~320 bytes/FD
  ⇒ ~20 MB kernel memory at full ceiling on a 3.8 GB host. Accepted.
- **Distroless ⇒ measure FDs from the host**, re-resolving PID each poll. Accepted → FR-002, FR-003.
- **`mem_limit` / `oom_score_adj` proposed to protect postgres.** **Rejected for this change** →
  FR-014. Evidence shows `OOMKilled=false` and 1.7 GB free; adding an unmeasured 512 MB cap would
  introduce a brand-new failure mode while fixing nothing observed. Recorded as a future option
  contingent on measuring steady-state RSS (the sampler in #1 can supply that).
- **Arithmetic correction**: the Guardian projected EMFILE after "~380 requests" at nofile=65536,
  by treating the ~171 idle FDs as a *per-request* cost. The evidence (EMFILE clustering at
  12k–20k requests) gives ~53.5 FDs per 1,000 requests, so 65,536 yields ≈1.22 M requests ≈138 days.
  The Guardian's figure was low by ~3,200×. Corrected figure is used in SC-004.

### Delivery Guardian

- **Ban `:latest` for companion; pin an immutable date tag.** Accepted → FR-004.
- **Pre-pull cleanup + post-deploy digest verification.** Accepted → FR-005.
- **Sequence changes, ≥24 h observation between steps, per-step rollback.** Accepted, with the
  modification described in Decomposition (observability first; #2+#3 may share a window).
- **Do not stand up Prometheus** for a single hobby VM; cron+log sampling covers the meaningful SLIs,
  and companion's prom-client metrics expose innertube/potoken counters only — **no FD gauge**, so
  the primary signal would be invisible there anyway. Accepted → #1 is a shell sampler.
- **14-day observation window** to declare the fix closed (baseline ~1 crash/day), with a 7-day
  early-confidence checkpoint. Accepted → SC-001.
- **Deploy in a low-traffic window; each recreate drops in-flight streams.** Accepted → Open Decision D1.
- **Watchtower / unattended updates not recommended without staging.** Accepted → Open Decision D2.

### Security Guardian

- Not consulted as a subagent for this change. Assessed inline as **low surface**: no authentication,
  authorization, input-validation, or data-handling changes; no new network exposure; no new secrets.
  Two genuine security-adjacent points are nonetheless carried into the tickets:
  - **Supply chain / provenance** — pinning an immutable tag and verifying the digest (FR-004, FR-005)
    is a supply-chain control, not merely an operational nicety; it closes the "local build silently
    shadows the official image" gap.
  - **Resource exhaustion** — raising `nofile` deliberately increases the resources one container may
    consume. Scoping it per-service rather than daemon-wide (Platform Guardian) keeps the blast radius
    to companion.
- [NEEDS CLARIFICATION: confirm this inline assessment is acceptable, or request a full Security
  Guardian review before Phase 1 lands.]

### Privacy Guardian

- **N/A — no personal-data change.** This work alters container limits, image pinning, health checks,
  and fetch timeouts. It collects no new user data. The new monitoring log records only container
  restart counts, FD counts, and health status — no IPs, no request URLs, no video IDs, no user
  identifiers. Existing Caddy/Invidious logging is unchanged.

---

## System Impact

### Affected components

| Component | Change type | Description |
|---|---|---|
| `docker-compose.yml` → `companion` service | Modified | Pin immutable image tag; add `ulimits.nofile` 65536/65536; remove `healthcheck: {disable: true}` and set `interval: 30s`; add fetch tuning env vars |
| `scripts/companion-monitor.sh` | New | 5-minute sampler of restart count, host-side FD count, health status |
| `scripts/companion-watchdog.sh` | New *(conditional)* | Only if a hang-without-exit is observed; shares gluetun watchdog's lock |
| `scripts/gluetun-watchdog.sh` | Unchanged, contract-affected | Becomes a lock counterparty if #6 ships; no edit otherwise |
| Host crontab | Modified | One new entry for the sampler (plus one for the watchdog if #6 ships) |
| `TROUBLESHOOTING.md` | Modified | New §4 incident; Step 3 re-tag guidance replaced with a warning |
| Companion container image | Modified | 2026-03-22 build → pinned 2026-08-10 build (~5 months of upstream change) |
| Host image store | Modified | Stale `invidious-companion:custom`, `:pr287`, and any locally re-tagged `:latest` removed |

### Affected contracts

| Contract | Change | Backward compatible? |
|---|---|---|
| Compose `companion` service | Add `ulimits`, pin tag, env vars | **Yes** — additive; `docker compose up -d` unchanged |
| Companion env vars | Add `NETWORKING_FETCH_*` (and optionally `SERVER_ENABLE_METRICS`) | **Yes** — upstream zod schema defines all with defaults; omitting them reproduces today's behaviour |
| Healthcheck contract | `disable: true` → active `/healthz` probe at 30 s | **No (behavioural)** — companion gains a `health` status it never had. Nothing consumes it today, so impact is observability-only; but any future automation keyed on health must account for the ~30 s start-up window |
| Image reference | `:latest` (mutable, locally shadowable) → immutable date tag | **No (procedural)** — routine updates now require an explicit tag bump; this is the intended trade-off. Rollback becomes deterministic |
| Cron / watchdog interface | New sampler entry; lock shared if #6 ships | **Yes** for the sampler (read-only, never mutates containers) |
| Monitoring log format | New: `<iso8601> restarts=<int> fds=<int> health=<str>` | **N/A** — new surface; format fixed here so future tooling can parse it |
| `/proc/<pid>` host access | New dependency for FD measurement | **Yes** — read-only; requires appropriate host privileges |

### Architectural deltas

- **"Companion cannot have a health check" no longer holds.** The compose comment
  *"Companion image is distroless (no shell/wget), so disable healthcheck"* was true for the old
  image and is now **obsolete**: the current image bundles a static `tiny-health-checker` binary and
  declares `HEALTHCHECK --interval=5s --timeout=5s --start-period=10s --retries=5 CMD ["/thc"]`
  against `/healthz`. Keeping `disable: true` would discard the single most relevant new capability
  shipped in the upgrade.
- **Correction — "unhealthy" does not mean "restarted".** Plain Docker Engine does **not** restart a
  container because its health check fails; only Swarm does. This repo already depends on that fact:
  `gluetun-watchdog.sh` exists precisely because *"Docker's `restart: unless-stopped` policy never
  triggers"* when gluetun wedges without exiting. Therefore re-enabling the health check buys
  **observability, not recovery**. Recovery for *exits* already works (that is what the 14 restarts
  are); recovery for *hangs* would require #6.
- **The crash mode 1 code path no longer exists upstream.** Issue #231 is still formally **open**
  (created 2025-10-19, `closed_at: null`, no linked fix PR), so "the upstream fix landed" cannot be
  asserted from issue state. However commit `cc2503e7` (2026-07-14, PR #329, *"Remove chunking from
  video playback proxy"*) **deleted the exact code #231 blamed** — the `TransformStream` +
  `StreamingApi` pair, the floating `chunk` promise chain, and the `chunk.catch(() => stream.abort())`
  whose rejection escaped. The handler now performs a single awaited fetch and returns
  `postResponse.body` directly. This is a **de facto fix reached by deletion**, not a targeted patch —
  which is why the upgrade is expected to help but is not guaranteed to, and why SC-003 measures the
  outcome rather than assuming it.
- **The known upstream FD-leak fix does not apply to this deployment.** Commit `81da42af`
  (2026-03-21, *"prevent HttpClient memory leak by reusing client and closing per-request ones"*,
  fixes #290) addresses a per-request `Deno.createHttpClient()` leak — but that code path is gated
  behind `if (proxyAddress || ipv6Block)`. This deployment sets **neither** (`PROXY` and
  `NETWORKING_IPV6_BLOCK` are unset; VPN egress is by shared network namespace, not an HTTP proxy).
  So the companion here never took the leaking path, and that commit neither explains nor fixes the
  observed `eventpoll`/`eventfd` leak. **The true root cause of our FD leak remains unconfirmed.**
  The leading hypothesis is that the removed chunking machinery orphaned per-request stream resources
  and left upstream response bodies un-cancelled on abort — which #329 would also fix — but this is
  a hypothesis, not a verified diagnosis. This uncertainty is the single strongest argument for
  treating the ulimit raise as essential rather than optional.
- **ulimit inheritance is no longer implicit.** The container ran on Docker's default soft
  `nofile=1024` purely because nothing specified otherwise (`HostConfig.Ulimits` = `null`), despite
  dockerd's own `LimitNOFILE=524288` and no `/etc/docker/daemon.json`. Limits become explicit and
  reviewable.
- **`:latest` is no longer treated as trustworthy.** Combined with the runbook's re-tag instruction
  and surviving local images, `:latest` on this host is effectively an operator-local alias. The
  deployment moves to immutable tags plus digest verification.
- **The shared network namespace becomes an operational constraint, not just a networking detail.**
  Any future automation touching companion must reason about gluetun's lifecycle first.

### Backward compatibility and migration

- **Breaking changes:** None at the user-facing or API level. Two procedural changes: image updates
  now require an explicit tag bump, and companion now reports a health status.
- **Migration path:**
  1. Install the sampler (#1); collect ≥24 h of baseline. No restart, no downtime.
  2. Record the currently running image digest (rollback anchor).
  3. Remove stale/shadowing local images.
  4. Pin the immutable tag, add ulimits, deploy in one low-traffic window (#2 + #3).
  5. Observe ≥24 h clean, then land #4, then #5, each in its own window.
  6. Evaluate #6's trigger condition; build only if met.
  7. Finalise documentation (#7).
- **Deprecation timeline:** `:latest` for companion is deprecated immediately on #2. The
  TROUBLESHOOTING.md Step 3 re-tag procedure is deprecated on #7 and replaced with a warning.

### Risk surface

**Risks introduced**

- **~5 months of upstream change in one step.** The upgrade spans 2026-03-22 → 2026-08-10, including
  chunking removal (#329), Deno 2.9.2, YouTube.js v17.2.0, KV-cache path changes, and a deliberate
  downgrade (`d3544b42`, "downgrade as per reports of #5779"). Mitigation: immutable tag + recorded
  prior digest ⇒ <5 min rollback (SC-007); land alone in Phase 1 for attributability.
- **Whole-body `AbortSignal` timeout** post-#329 may cut slow or large transfers that the old
  ≤5 MB-per-chunk model tolerated. Mitigation: FR-009 raises the timeout; the sampler plus user
  report surface regressions.
- **A higher FD ceiling lets a leak run longer before dying.** Mitigation: SC-003 monitors the rate;
  FR-014 explicitly refuses an unmeasured memory cap; the 65536 ceiling costs ~20 MB kernel memory
  at worst on a 3.8 GB host, so it cannot plausibly trade an EMFILE crash for a host OOM.
- **Retry amplification on 2 vCPU** if enabled without backoff. Mitigation: FR-010.
- **Restart churn** if a 5 s health-check interval drove rapid recreation. Mitigation: FR-008 (30 s).
- **Watchdog race** on shared-netns containers, if #6 ever ships. Mitigation: FR-013 (shared lock +
  gluetun precondition).

**Risks reduced**

- Crash-mode-1 code path removed upstream ⇒ the dominant crash mode (9 of 14) should disappear.
- EMFILE interval extended ~78× (1.76 days → ~138 days projected) even with the leak unchanged.
- Image provenance becomes verifiable; the re-tag footgun is closed.
- Future incidents start from a monitoring log rather than a from-scratch live investigation (SC-008).
- The "companion has no health signal" blind spot is removed.

---

## Product Impact

### Positioning shift

None. This is a reliability repair to a personal, self-hosted deployment. It does not add a feature
or change what the product is. It does, however, move the deployment from *"reactively repaired when
a human notices"* toward *"continuously measured"* — the first instance in this repo of recording a
baseline before changing anything.

### Scope boundary changes

Narrow and deliberate. The change explicitly **does not** open the door to a monitoring stack
(Prometheus/Grafana was considered and rejected as disproportionate for one hobby VM), nor to
unattended auto-updates (deferred to Open Decision D2). It closes one category of future work: ad-hoc
`docker tag` overrides of official images are now discouraged by policy and by documentation.

### Roadmap dependencies

- **Unlocks:** a reusable host-side sampling pattern that could later cover invidious, postgres, and
  caddy; a measured RSS baseline that would make a future `mem_limit` decision evidence-based rather
  than speculative; a health signal that makes #6 buildable if ever needed.
- **Blocks or delays:** pinning tags adds a small recurring maintenance obligation (periodic tag
  bumps) that did not exist under `:latest`.
- **Depends on:** the existing gluetun watchdog's lock and label-reconstruction conventions, which
  the new scripts follow rather than reinvent.

### User-facing communication

- **Internal stakeholders:** single operator (@guiess). No team to inform.
- **External communication:** listeners should be told informally about each maintenance window,
  since every companion recreate drops in-flight streams (~<60 s). Exact wording and channel are the
  operator's call — see Open Decision D1.

---

## Open Decisions

These are unresolved and are surfaced in the tickets. **D1 and D2 block Phase 1.**

| # | Decision | Options | Recommendation |
|---|---|---|---|
| **D1** | Acceptable restart/downtime window | Any time vs. a fixed low-traffic window (e.g. 02:00–06:00 local) | Fixed low-traffic window; each recreate is <60 s but severs in-flight streams |
| **D2** | Unattended image updates | Manual periodic tag bump vs. Watchtower auto-update | **Manual.** No staging and no CI means an auto-deployed bad image would reach users unfiltered |
| **D3** | Watchdog aggressiveness (only if #6 is built) | Match gluetun's 10 consecutive failures (~5 min) vs. tighter 3–5 (~1.5–2.5 min) | 5 consecutive failures at a 30 s interval (~2.5 min), **and** only after the trigger condition is observed |
| **D4** | Observation window to close the work | 7 vs. 14 days | 14 days (baseline is ~1 crash/day; 7 days is the early checkpoint only) |
| **D5** | Enable `SERVER_ENABLE_METRICS` | Yes (ad-hoc `curl`) vs. no | Optional; it exposes innertube/potoken counters but **no FD gauge**, so it does not serve the primary signal |
| **D6** | Remove the suspected-inert `COMPANION_PORT` / `COMPANION_HOST` / `COMPANION_INNER_TUBE_FORCE_LOCATION` env vars | Remove vs. keep | Verify on the VM first; treat as documentation cleanup, never bundled with a functional change |

---

## Appendix — References

**Upstream evidence (verified against the GitHub API on 2026-08-15)**

- iv-org/invidious-companion#231 — *Exception during async chunk streaming causes companion to crash*.
  **Still open**, created 2025-10-19, `closed_at: null`, no linked fix PR.
- Commit `cc2503e7` (2026-07-14, PR #329) — *Remove chunking from video playback proxy*. Deletes the
  `TransformStream`/`StreamingApi` chunk chain and `chunk.catch(() => stream.abort())` cited by #231.
- Commit `81da42af` (2026-03-21) — *prevent HttpClient memory leak…* (fixes #290). Gated behind
  `proxy || ipv6_block`; **not applicable** to this deployment.
- Commit `6c8ee956` (2026-07-14) — *Tag container images with sortable date prefix on master*
  (origin of the `2026.08.10-16cf10e` tag form).
- Commits `c1b496bb`, `38e9ddb1`, `88e278a1` (2026-07-14) — Deno KV cache path/permission fixes.
- Commit `0813f008` (2026-06-29) — YouTube.js v17.2.0. Commit `d3544b42` (2026-06-17) — deliberate
  downgrade per reports of iv-org/invidious#5779.
- Upstream `Dockerfile` — bundles `tiny-health-checker` and declares
  `HEALTHCHECK … CMD ["/thc"]` with `THC_PATH=/healthz`; `src/routes/health.ts` returns plain 200 `OK`.
- Upstream `src/lib/helpers/config.ts` — zod schema (`.strict()`) defining `NETWORKING_FETCH_TIMEOUT_MS`
  (30000), `NETWORKING_FETCH_RETRY_ENABLED` (false), `NETWORKING_FETCH_RETRY_TIMES` (1),
  `..._INITIAL_DEBOUNCE` (0), `..._DEBOUNCE_MULTIPLIER` (0), `SERVER_ENABLE_METRICS` (false).
- Upstream `src/lib/helpers/metrics.ts` — prom-client counters for innertube/potoken only; **no FD gauge**.

**Local evidence**

- `docker-compose.yml`, `docker-compose.vpn.yml`, `caddy/Caddyfile`, `scripts/gluetun-watchdog.sh`,
  `TROUBLESHOOTING.md` (three prior incidents), `.env.example`.
- Live VM measurements: `RestartCount=14`; `ExitCode=0`; `OOMKilled=false`;
  `HostConfig.Ulimits = null`; `/proc/<pid>/limits` 1024 soft / 524288 hard; 193 idle FDs
  (87 `eventpoll`, 84 `eventfd`); Caddy `aborting with incomplete response` against `gluetun:8282`.
