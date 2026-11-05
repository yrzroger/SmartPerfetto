#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2024-2026 Gracker (Chris)
# This file is part of SmartPerfetto. See LICENSE for details.

# Start SmartPerfetto reachable from the LAN, deriving the browser-facing
# frontend origin from whatever IPv4 address this machine currently uses.
# Nothing here is tied to one machine: move the checkout to another host and
# the detected address follows.
#
# Usage:
#   ./scripts/start-lan.sh                        # bind 0.0.0.0, auto-detect
#   LAN_ADDRESS=10.0.0.5 ./scripts/start-lan.sh   # pin the address explicitly
#
# Arguments are passed through to start.sh (e.g. --clean).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ENV_FILE="${PROJECT_ROOT}/backend/.env"

# The address the OS would use to reach the outside world: that is the NIC a
# peer on this network reaches, not a docker bridge or a VPN tunnel.
detect_lan_address() {
  local address=""
  if command -v ip >/dev/null 2>&1; then
    address="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
      { for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }
    ')"
  fi
  if [ -z "$address" ] && command -v hostname >/dev/null 2>&1; then
    address="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  fi
  printf '%s' "$address"
}

LAN_ADDRESS="${LAN_ADDRESS:-$(detect_lan_address)}"
if [ -z "$LAN_ADDRESS" ]; then
  echo "ERROR: could not detect a LAN IPv4 address." >&2
  echo "Set it explicitly, for example: LAN_ADDRESS=192.168.1.20 $0" >&2
  exit 1
fi
case "$LAN_ADDRESS" in
  127.*|0.0.0.0|::1)
    echo "ERROR: detected address '$LAN_ADDRESS' is not a LAN address." >&2
    echo "Set it explicitly, for example: LAN_ADDRESS=192.168.1.20 $0" >&2
    exit 1
    ;;
esac

# A deployment that pins FRONTEND_URL (reverse proxy, HTTPS domain) keeps it.
# start.sh clears the shell variable when it sources the port helpers, so the
# only place it survives is an env file - read it from there.
env_file_value() {
  local key="$1" file value=""
  for file in "$ENV_FILE" "${PROJECT_ROOT}/.env"; do
    [ -f "$file" ] || continue
    value="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true)"
    [ -n "$value" ] && break
  done
  value="${value%%#*}"
  value="${value//\"/}"
  value="${value//\'/}"
  printf '%s' "$(printf '%s' "$value" | tr -d '[:space:]')"
}

FRONTEND_PORT="$(env_file_value SMARTPERFETTO_FRONTEND_PORT)"
FRONTEND_PORT="${FRONTEND_PORT:-10000}"
FRONTEND_ORIGIN="http://${LAN_ADDRESS}:${FRONTEND_PORT}"

if [ -n "${FRONTEND_URL:-}" ]; then
  RESOLVED_FRONTEND_URL="$FRONTEND_URL"
elif [ -n "$(env_file_value FRONTEND_URL)" ]; then
  RESOLVED_FRONTEND_URL="$(env_file_value FRONTEND_URL)"
else
  RESOLVED_FRONTEND_URL="$FRONTEND_ORIGIN"
fi

echo "=============================================="
echo "SmartPerfetto (LAN)"
echo "  Address:  ${LAN_ADDRESS}"
echo "  UI:       ${RESOLVED_FRONTEND_URL}"
echo "=============================================="

# start.sh sources the port helpers, which reset FRONTEND_URL before reading
# it from SMARTPERFETTO_ENV_FILE. A generated override file - same settings as
# the real one, plus this machine's origin - is what makes the detected
# address reach both the launch scripts and the backend.
if [ -f "$ENV_FILE" ] && ! grep -qE "^[[:space:]]*FRONTEND_URL=" "$ENV_FILE"; then
  OVERRIDE_FILE="$(mktemp -t smartperfetto-lan-env.XXXXXX)"
  trap 'rm -f "$OVERRIDE_FILE"' EXIT INT TERM
  cat "$ENV_FILE" > "$OVERRIDE_FILE"
  printf '\n# Added by scripts/start-lan.sh for this run.\nFRONTEND_URL=%s\n' \
    "$RESOLVED_FRONTEND_URL" >> "$OVERRIDE_FILE"
  export SMARTPERFETTO_ENV_FILE="$OVERRIDE_FILE"
fi

# The bind hosts must be real environment variables: frontend/server.js does
# not read them from the env file.
export SMARTPERFETTO_BIND_HOST="${SMARTPERFETTO_BIND_HOST:-0.0.0.0}"
export SMARTPERFETTO_FRONTEND_BIND_HOST="${SMARTPERFETTO_FRONTEND_BIND_HOST:-0.0.0.0}"
export SMARTPERFETTO_NO_OPEN=1
export FRONTEND_URL="$RESOLVED_FRONTEND_URL"

exec "$PROJECT_ROOT/start.sh" "$@"
