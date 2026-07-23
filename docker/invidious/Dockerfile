# Custom Invidious image that works around YouTube blacklisting the hard-coded
# WEB InnerTube client version (2.20250222.10.00), which makes search, browse and
# video endpoints return HTTP 400 on every instance.
#
#   Upstream issue: https://github.com/iv-org/invidious/issues/5817
#   See ../../TROUBLESHOOTING.md → "Search & video return HTTP 400".
#
# The version is a compile-time constant baked into the static Crystal binary, so
# it cannot be changed via config. Instead of recompiling from source (heavy, and
# Invidious's build runs `crystal spec` which itself fails during this outage), we
# patch the string IN PLACE in the prebuilt binary. The replacement MUST be the
# exact same byte length as the original (16 ASCII chars) so that all offsets in
# the binary are preserved.

ARG INVIDIOUS_IMAGE=quay.io/invidious/invidious:latest
FROM ${INVIDIOUS_IMAGE}

# The blacklisted version currently shipped in the image.
ARG OLD_WEB_CLIENT_VERSION=2.20250222.10.00
# A current, YouTube-accepted WEB version (format 2.YYYYMMDD.rr.rr, 16 chars).
# Capture the live value from a browser: F12 → Network → any youtubei/v1 request →
# request header `X-Youtube-Client-Version`.
ARG WEB_CLIENT_VERSION=2.20260722.01.00

USER root
RUN set -eux; \
    if [ "${#WEB_CLIENT_VERSION}" -ne "${#OLD_WEB_CLIENT_VERSION}" ]; then \
        echo "ERROR: WEB_CLIENT_VERSION must be ${#OLD_WEB_CLIENT_VERSION} chars, got ${#WEB_CLIENT_VERSION}"; \
        exit 1; \
    fi; \
    apk add --no-cache --virtual .patch-tools perl; \
    OLD="$OLD_WEB_CLIENT_VERSION" NEW="$WEB_CLIENT_VERSION" perl -0777 -i -pe 'my($o,$n)=($ENV{OLD},$ENV{NEW}); my $c=()=/\Q$o\E/g; die "old WEB client version not found in binary (upstream may have already changed it)\n" if $c==0; s/\Q$o\E/$n/g; warn "patched $c occurrence(s) of WEB client version\n";' /invidious/invidious; \
    chown invidious:invidious /invidious/invidious; \
    chmod 0755 /invidious/invidious; \
    apk del .patch-tools
USER invidious
