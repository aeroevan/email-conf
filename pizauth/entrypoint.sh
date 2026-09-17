#!/bin/sh
# Run pizauth with its token state persisted across container restarts.
#
# pizauth keeps refresh tokens in memory only.  The quadlet runs with podman's
# AutoRemove, so without this wrapper every restart -- reboot, image rebuild,
# OOM -- loses the refresh token and requires a human to reauthorise through a
# browser, with mbsync and msmtp failing until they do.
#
# `pizauth dump` serialises the token state and `pizauth restore` reads it back.
# The dump lives on the pizauth-data volume at $DUMP, mode 0600: it contains
# material that can mint access tokens, so treat it like a credential.
set -eu

DUMP=/var/lib/pizauth/dump
SAVE_INTERVAL="${PIZAUTH_SAVE_INTERVAL:-300}"

log() { echo "pizauth-wrapper: $*"; }

# -d keeps the server in the foreground; background it here so this script can
# own the lifecycle and still react to SIGTERM.
pizauth server -d -vv &
SRV=$!

# Wait for the daemon's socket before talking to it.
i=0
while [ "$i" -lt 100 ]; do
    if pizauth status >/dev/null 2>&1; then break; fi
    if ! kill -0 "$SRV" 2>/dev/null; then
        log "server exited during startup"
        wait "$SRV"
        exit 1
    fi
    i=$((i + 1))
    sleep 0.1
done

if [ -s "$DUMP" ]; then
    if pizauth restore < "$DUMP" 2>/dev/null; then
        log "restored token state from $DUMP"
    else
        log "WARNING: restore from $DUMP failed; browser reauthorisation needed"
    fi
else
    log "no saved state at $DUMP; browser reauthorisation needed on first use"
fi

# Write atomically, and never replace a good dump with an empty one: a failed
# dump must not destroy the only copy of the refresh token.
save() {
    umask 077
    if pizauth dump > "$DUMP.tmp" 2>/dev/null && [ -s "$DUMP.tmp" ]; then
        mv -f "$DUMP.tmp" "$DUMP"
    else
        rm -f "$DUMP.tmp"
        log "WARNING: dump produced no data; kept previous $DUMP"
    fi
}

on_term() {
    log "shutting down, saving state"
    save
    kill "$SRV" 2>/dev/null || true
    wait "$SRV" 2>/dev/null || true
    exit 0
}
trap on_term TERM INT

# Periodic saves so an unclean stop (OOM, host power loss) still leaves a
# usable dump.  `sleep &` + `wait` so the trap fires promptly instead of
# waiting out the whole interval.
while kill -0 "$SRV" 2>/dev/null; do
    sleep "$SAVE_INTERVAL" &
    wait $! 2>/dev/null || true
    save
done

log "server exited"
wait "$SRV" 2>/dev/null || true
