#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ORCA_PAIRING_ADDRESS:-}" ]]; then
    echo "ORCA_PAIRING_ADDRESS is required (use a reachable Tailscale IP, hostname, or proxy URL)." >&2
    exit 2
fi

exec /opt/orca/squashfs-root/AppRun serve \
    --port "${ORCA_PORT:-6768}" \
    --pairing-address "${ORCA_PAIRING_ADDRESS}" \
    --json
