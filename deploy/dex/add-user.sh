#!/bin/bash
# Add a password-less account to the SmartPerfetto Dex instance.
#
# Usage:
#   ./add-user.sh <email> [username]
#
# The login form asks for an address only, so every account carries the same
# bcrypt hash of the empty string. Adding a user is therefore: append one entry
# and restart Dex so the new static table is read.
#
# This script ships in the repository and is copied next to config.yaml by
# scripts/deploy-lan.sh, which substitutes __CONTAINER__ and __HEALTH_URL__.

set -euo pipefail

DEX_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$DEX_DIR/config.yaml"
CONTAINER="__CONTAINER__"
HEALTH_URL="__HEALTH_URL__"
EMPTY_HASH='$2y$10$iRGFWAOpw/d9mvR6EH/mNuQlox5khYXrqVsTo47c3SvU3e9bNy0.q'

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <email> [username]" >&2
  exit 2
fi

EMAIL="$1"
USERNAME="${2:-${EMAIL%%@*}}"

case "$EMAIL" in
  *@*.*) ;;
  *) echo "error: '$EMAIL' is not an email address" >&2; exit 2 ;;
esac

if ! printf '%s' "$USERNAME" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "error: username '$USERNAME' may only contain letters, digits, dot, underscore, hyphen" >&2
  exit 2
fi

if [ ! -f "$CONFIG" ]; then
  echo "error: $CONFIG not found" >&2
  exit 1
fi

if grep -qF "email: $EMAIL" "$CONFIG"; then
  echo "error: $EMAIL is already registered" >&2
  exit 1
fi

# userID is the identity primary key: it must never be reused or changed, or the
# person's personal workspace and traces stop matching them.
USER_ID="$USERNAME-$(date +%Y%m%d%H%M%S)"

cp "$CONFIG" "$CONFIG.bak"

# An empty list is written as the flow form `staticPasswords: []`, which cannot
# take appended block items; open it into block form before adding the first one.
sed -i 's/^staticPasswords: \[\]$/staticPasswords:/' "$CONFIG"

cat >> "$CONFIG" <<EOF
  - email: $EMAIL
    hash: "$EMPTY_HASH"
    username: $USERNAME
    userID: $USER_ID
EOF

echo "added $EMAIL (userID $USER_ID)"

# Reading the config needs the same elevation as starting the container: a user
# outside the docker group cannot talk to the daemon at all.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

if ! $DOCKER inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "warning: container $CONTAINER not found; start it with scripts/deploy-lan.sh" >&2
  exit 0
fi

# Dex reads staticPasswords at startup, so the restart is what makes the new
# account usable.
if ! $DOCKER restart "$CONTAINER" >/dev/null 2>&1; then
  echo "error: could not restart $CONTAINER; run: sudo docker restart $CONTAINER" >&2
  exit 1
fi

echo "restarted $CONTAINER"

# The restart still has the old listener closing when the first probe fires, so
# a first-attempt reset is expected. Keep retry noise out of the output and show
# the last real error only if Dex never comes up.
last_error=""
for _ in $(seq 1 20); do
  if last_error=$(curl -fsS -o /dev/null -m 2 "$HEALTH_URL" 2>&1); then
    echo "Dex is serving; $EMAIL can log in now"
    exit 0
  fi
  sleep 1
done

echo "error: Dex did not become reachable: $last_error" >&2
echo "check: sudo docker logs $CONTAINER" >&2
exit 1
