#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2024-2026 Gracker (Chris)
# This file is part of SmartPerfetto. See LICENSE for details.

# One-shot LAN deployment: generate the backend env file, install a systemd unit
# and start the service so other PCs on the subnet reach the UI at
# http://<server-ip>:10000.
#
# Usage:
#   ./scripts/deploy-lan.sh                    # full deployment (prompts for sudo as needed)
#   ./scripts/deploy-lan.sh --env-only         # only write backend/.env (no sudo)
#   ./scripts/deploy-lan.sh --dry-run          # print what would change (no sudo)
#   ./scripts/deploy-lan.sh --uninstall        # stop and remove the unit
#
# Run this as the service account, NOT with sudo: the script elevates only the
# steps that need root (writing the unit, systemctl). Running the whole script
# under sudo would make a generated backend/.env owned by root, which the
# service account then cannot read.
#
# Options:
#   --address <ipv4>     Bind and advertise this address instead of detecting it
#   --port <n>           Frontend port (default: 10000)
#   --user <name>        Service account (default: the invoking user)
#   --force              Overwrite an existing backend/.env
#   --no-oidc            Skip Dex and keep the shared API key instead of SSO
#   --dns-name <name>    Advertise this hostname in the OIDC issuer and redirect
#                        URI instead of the LAN address
#   --dex-port <n>       Dex port (default: 5556)
#   --yes                Install missing prerequisites without asking
#
# Missing Node.js 24 and Docker are installed automatically after a prompt. Each
# install is announced with the exact commands first; without a terminal (CI,
# piped input) it fails instead of guessing. Pass --yes to skip the prompts.
#
# The env file is never overwritten without --force: existing secrets would be
# lost, and losing SMARTPERFETTO_SECRET_STORE_MASTER_KEY makes every stored
# provider secret permanently undecryptable.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ENV_FILE="$PROJECT_ROOT/backend/.env"
UNIT_NAME="smartperfetto.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
DEX_TEMPLATE_DIR="$PROJECT_ROOT/deploy/dex"
DEX_CONTAINER="smartperfetto-dex"
DEX_IMAGE="dexidp/dex:latest"

DRY_RUN=false
ENV_ONLY=false
UNINSTALL=false
FORCE=false
OIDC_ENABLED=true
ASSUME_YES=false
DNS_NAME=""
LAN_ADDRESS=""
FRONTEND_PORT=""
DEX_PORT=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "  $*"
}

usage() {
  # Print the usage block by content, not by line number: adding an option used
  # to silently truncate the help text. The block starts at the "One-shot" line
  # and ends at the first non-comment line, which skips the license header.
  awk '
    /^# One-shot/ { print_block = 1 }
    print_block && /^#/ { sub(/^# ?/, ""); print; next }
    print_block { exit }
  ' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --env-only) ENV_ONLY=true ;;
    --uninstall) UNINSTALL=true ;;
    --force) FORCE=true ;;
    --address)
      shift
      [ $# -gt 0 ] || die "--address requires a value"
      LAN_ADDRESS="$1"
      ;;
    --port)
      shift
      [ $# -gt 0 ] || die "--port requires a value"
      FRONTEND_PORT="$1"
      ;;
    --user)
      shift
      [ $# -gt 0 ] || die "--user requires a value"
      SERVICE_USER="$1"
      ;;
    --no-oidc) OIDC_ENABLED=false ;;
    --yes|-y) ASSUME_YES=true ;;
    --dns-name)
      shift
      [ $# -gt 0 ] || die "--dns-name requires a value"
      DNS_NAME="$1"
      ;;
    --dex-port)
      shift
      [ $# -gt 0 ] || die "--dex-port requires a value"
      DEX_PORT="$1"
      ;;
    --help|-h) usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ── Preconditions ────────────────────────────────────────────────────────────

require_linux() {
  [ "$(uname -s)" = "Linux" ] || die "this script targets Linux; use ./start.sh on other platforms"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "systemd is not available on this host"
  [ -d /run/systemd/system ] || die "systemd is not running as the init system"
}

detect_address() {
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

validate_address() {
  local address="$1" octet
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "'$address' is not an IPv4 address"
  local IFS=.
  for octet in $address; do
    [ "$octet" -le 255 ] || die "'$address' has an out-of-range octet '$octet'"
  done
  unset IFS
  case "$address" in
    127.*|0.0.0.0) die "'$address' is not a LAN address" ;;
  esac
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "port must be a number, got '$port'"
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "port must be in 1..65535, got '$port'"
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif [ -r /dev/urandom ]; then
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    die "need openssl or /dev/urandom to generate secrets"
  fi
}

# ── Prerequisite installation ────────────────────────────────────────────────

# Installing system packages changes the host beyond this project, so each
# install is described before it runs and needs a deliberate answer. A script
# reading piped input has no one to ask, so it fails rather than assume yes.
confirm_install() {
  local what="$1"
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "$what is missing and this is not an interactive terminal. Re-run with --yes to install it automatically, or install it yourself and retry."
  fi
  printf '  %s is missing. Install it now? [y/N] ' "$what" >&2
  local answer
  read -r answer || answer=""
  case "$answer" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) die "$what is required. Install it and re-run, or pass --yes." ;;
  esac
}

# Node.js ships an official tarball per platform, so this needs no package
# repository, no root and no version manager: unpack it under the service
# account's home and point the systemd unit at the absolute binary path.
node_archive_suffix() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'linux-x64' ;;
    aarch64|arm64) printf 'linux-arm64' ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

install_node24() {
  local suffix service_home dest work archive version expected actual
  suffix="$(node_archive_suffix)" \
    || die "no official Node.js tarball for architecture '$(uname -m)'; install Node.js 24 manually"
  command -v curl >/dev/null 2>&1 || die "curl is required to download Node.js 24"

  service_home="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
  [ -n "$service_home" ] || die "cannot resolve the home directory of '$SERVICE_USER'"
  dest="$service_home/.local/node24"
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # Expand the path now, not at trap time.
  trap "rm -rf '$work'" RETURN

  info "downloading https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt"
  curl -fsSL --max-time 60 "https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt" \
    -o "$work/SHASUMS256.txt" || die "could not download the Node.js checksum list"

  # The checksum file names the exact patch release, so read the version off it
  # instead of pinning one here and drifting out of date.
  archive="$(awk -v s="-${suffix}.tar.xz" '$2 ~ s"$" {print $2; exit}' "$work/SHASUMS256.txt")"
  [ -n "$archive" ] || die "the Node.js checksum list has no '${suffix}' archive"
  expected="$(awk -v a="$archive" '$2 == a {print $1; exit}' "$work/SHASUMS256.txt")"
  version="${archive#node-}"
  version="${version%-"${suffix}".tar.xz}"

  info "downloading $archive"
  curl -fsSL --max-time 300 "https://nodejs.org/dist/latest-v24.x/$archive" \
    -o "$work/$archive" || die "could not download $archive"

  actual="$(sha256_of "$work/$archive")" \
    || die "need sha256sum or shasum to verify the Node.js download"
  [ "$actual" = "$expected" ] \
    || die "$archive failed checksum verification (expected $expected, got $actual)"

  tar -xJf "$work/$archive" -C "$work" || die "could not extract $archive"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  mv "$work/node-${version}-${suffix}" "$dest"
  info "unpacked Node.js $version to $dest"
}

# Debian-based hosts carry docker.io in their own repositories, which avoids
# adding a third-party apt source and its signing key.
install_docker() {
  command -v apt-get >/dev/null 2>&1 \
    || die "Docker is required and this script only knows how to install it with apt-get; install Docker yourself and re-run"
  info "running: sudo apt-get update"
  sudo apt-get update || die "apt-get update failed"
  info "running: sudo apt-get install -y docker.io"
  sudo apt-get install -y docker.io || die "could not install docker.io"
  sudo systemctl enable --now docker 2>/dev/null || true
  info "installed $(docker --version 2>/dev/null || echo docker)"
}

# ── Uninstall ────────────────────────────────────────────────────────────────

if [ "$UNINSTALL" = true ]; then
  require_systemd
  if [ "$DRY_RUN" = true ]; then
    info "would stop and disable $UNIT_NAME"
    info "would remove $UNIT_PATH"
    exit 0
  fi
  sudo systemctl disable --now "$UNIT_NAME" 2>/dev/null || true
  sudo rm -f "$UNIT_PATH"
  sudo systemctl daemon-reload
  echo "Removed $UNIT_NAME. backend/.env is left in place."
  exit 0
fi

# ── Resolve the deployment identity ──────────────────────────────────────────

require_linux
[ "$DRY_RUN" = true ] || require_systemd

# Files this script creates (backend/.env, backend/node_modules marker) belong
# to the account that will run the service. Running everything as root would
# leave them unreadable to that account, so refuse and say what to do instead.
if [ "$(id -u)" = "0" ]; then
  die "do not run this script with sudo. Run it as the service account:
       ./scripts/deploy-lan.sh
     It elevates only the steps that need root (writing the unit, systemctl)."
fi

SERVICE_USER="${SERVICE_USER:-$(id -un)}"

[ -n "$LAN_ADDRESS" ] || LAN_ADDRESS="$(detect_address)"
[ -n "$LAN_ADDRESS" ] || die "could not detect a LAN address; pass --address <ipv4>"
validate_address "$LAN_ADDRESS"

if [ -z "$FRONTEND_PORT" ]; then
  FRONTEND_PORT="$(grep -E '^[[:space:]]*SMARTPERFETTO_FRONTEND_PORT=' "$ENV_FILE" 2>/dev/null \
    | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
fi
FRONTEND_PORT="${FRONTEND_PORT:-10000}"
validate_port "$FRONTEND_PORT"

FRONTEND_ORIGIN="http://${LAN_ADDRESS}:${FRONTEND_PORT}"

# OIDC advertises one origin to browsers in two places: the issuer the backend
# validates tokens against, and the redirect URI the IdP sends users back to.
# Both must match what the browser can reach, so derive them from whatever
# address this host actually has - or from an explicit --dns-name.
DEX_PORT="${DEX_PORT:-5556}"
validate_port "$DEX_PORT"

OIDC_HOST="${DNS_NAME:-$LAN_ADDRESS}"
if [ -n "$DNS_NAME" ]; then
  [[ "$DNS_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "'$DNS_NAME' is not a DNS name"
fi
OIDC_ISSUER="http://${OIDC_HOST}:${DEX_PORT}/dex"
OIDC_REDIRECT_URI="http://${OIDC_HOST}:3000/api/auth/oidc/callback"

# The backend and Dex must agree on one client secret. Reuse the one already in
# backend/.env so a re-run keeps a working login; only a fresh deployment needs
# a new value.
OIDC_CLIENT_SECRET="$(grep -E '^[[:space:]]*SMARTPERFETTO_OIDC_CLIENT_SECRET=' "$ENV_FILE" 2>/dev/null \
  | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
[ -n "$OIDC_CLIENT_SECRET" ] || OIDC_CLIENT_SECRET="$(generate_secret)"

# systemd does not source a login shell, so the unit needs an absolute Node path.
# `sudo` resets PATH to secure_path, where `node` is whatever the distribution
# ships (v12 here) - so resolve Node 24 from the service account's nvm/volta
# installation instead of trusting `command -v node`.
node_major_of() {
  "$1" -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0
}

find_node24() {
  local candidate
  # A Node 24 on PATH wins: the caller activated it deliberately.
  candidate="$(command -v node 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ "$(node_major_of "$candidate")" = "24" ]; then
    printf '%s' "$candidate"
    return 0
  fi
  # Otherwise look where the version managers install it under the service
  # account's home. $HOME is root's under sudo, so use the account's own.
  local service_home
  service_home="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)"
  [ -n "$service_home" ] || service_home="$HOME"
  for candidate in \
    "$service_home"/.nvm/versions/node/v24*/bin/node \
    "$service_home"/.local/node24/bin/node \
    "$service_home"/.volta/bin/node \
    /usr/local/bin/node \
    /usr/bin/node; do
    [ -x "$candidate" ] || continue
    [ "$(node_major_of "$candidate")" = "24" ] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# Resolve both prerequisites before touching anything, so a missing one is
# reported alongside the other instead of after .env and Dex already changed.
NODE_BIN="$(find_node24 || true)"
if [ -z "$NODE_BIN" ]; then
  if [ "$DRY_RUN" = true ]; then
    info "Node.js 24 is missing; a real run would offer to install it"
  else
    confirm_install "Node.js 24"
    install_node24
    NODE_BIN="$(find_node24 || true)"
    [ -n "$NODE_BIN" ] || die "Node.js 24 was installed but could not be located"
  fi
fi
# The banner prints the version, so a dry run has to show something real.
if [ -n "$NODE_BIN" ]; then
  NODE_BIN_DIR="$(dirname "$NODE_BIN")"
else
  NODE_BIN="/nonexistent/node"
  NODE_BIN_DIR="/usr/local/bin"
fi

if [ "$OIDC_ENABLED" = true ] && ! command -v docker >/dev/null 2>&1; then
  if [ "$DRY_RUN" = true ]; then
    info "Docker is missing; a real run would offer to install it"
  else
    confirm_install "Docker"
    install_docker
    command -v docker >/dev/null 2>&1 || die "Docker was installed but is not on PATH"
  fi
fi

echo "=============================================="
echo "SmartPerfetto LAN deployment"
echo "  Project:  $PROJECT_ROOT"
echo "  Address:  $LAN_ADDRESS"
echo "  UI:       $FRONTEND_ORIGIN"
echo "  Service:  $SERVICE_USER @ $UNIT_NAME"
if [ -x "$NODE_BIN" ]; then
  echo "  Node:     $("$NODE_BIN" -v) ($NODE_BIN_DIR)"
else
  echo "  Node:     not found (would be installed)"
fi
if [ "$OIDC_ENABLED" = true ]; then
  echo "  OIDC:     $OIDC_ISSUER (container $DEX_CONTAINER, port $DEX_PORT)"
else
  echo "  Auth:     shared API key (--no-oidc)"
fi
[ "$DRY_RUN" = true ] && echo "  Mode:     dry run"
echo "=============================================="

# ── Step 1: backend/.env ─────────────────────────────────────────────────────

echo ""
echo "[1/5] backend/.env"

write_env_file() {
  local tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  umask 077
  cat > "$tmp" <<EOF
# Generated by scripts/deploy-lan.sh on $(date -Iseconds).
# Back up this file: losing SMARTPERFETTO_SECRET_STORE_MASTER_KEY makes stored
# provider secrets permanently undecryptable.

SMARTPERFETTO_BACKEND_PORT=3000
SMARTPERFETTO_FRONTEND_PORT=${FRONTEND_PORT}
NODE_ENV=development

# Required for LAN access: the browser uses the backend Lease proxy instead of a
# direct trace-processor connection, which is loopback-only.
SMARTPERFETTO_ENTERPRISE=true

SMARTPERFETTO_SERVER_SECRET=$(generate_secret)
SMARTPERFETTO_SECRET_STORE_MASTER_KEY=$(generate_secret)
EOF

  if [ "$OIDC_ENABLED" = true ]; then
    # OIDC and the shared API key are mutually exclusive; setting any OIDC
    # variable puts the backend in OIDC mode. Each person then signs in through
    # Dex and gets their own workspace instead of sharing one operation-level
    # identity.
    cat >> "$tmp" <<EOF

# --- OIDC single sign-on (per-user workspaces) ---
# Setting any of these puts the backend in OIDC mode, which rejects
# SMARTPERFETTO_API_KEY, so this file does not set one.
SMARTPERFETTO_OIDC_ISSUER_URL=${OIDC_ISSUER}
SMARTPERFETTO_OIDC_CLIENT_ID=smartperfetto
SMARTPERFETTO_OIDC_CLIENT_SECRET=${OIDC_CLIENT_SECRET}
SMARTPERFETTO_OIDC_REDIRECT_URI=${OIDC_REDIRECT_URI}
# Plain HTTP inside the LAN. The session cookie then omits Secure and can be
# captured on the wire, so use this only on a trusted network.
SMARTPERFETTO_OIDC_ALLOW_INSECURE_HTTP=true
EOF
  else
    cat >> "$tmp" <<EOF

# Value for the UI's "Backend Access Token".
SMARTPERFETTO_API_KEY=$(generate_secret)
EOF
  fi

  cat >> "$tmp" <<EOF

# Browser-facing origin. scripts/start-lan.sh regenerates this per boot; setting
# it here pins one address (reverse proxy or fixed IP).
# FRONTEND_URL=${FRONTEND_ORIGIN}

# Private provider endpoints must be listed by exact origin (scheme+host+port, no path).
# SMARTPERFETTO_PROVIDER_PRIVATE_ENDPOINT_ALLOWLIST=https://llm.internal.example

# The native directory picker is unavailable on a non-loopback bind.
# SMARTPERFETTO_CODEBASE_ROOTS=/home/user/src
EOF
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

if [ -f "$ENV_FILE" ] && [ "$FORCE" = false ]; then
  info "exists, keeping it (secrets preserved). Use --force to regenerate."
else
  if [ "$DRY_RUN" = true ]; then
    info "would create $ENV_FILE with freshly generated secrets"
  else
    mkdir -p "$(dirname "$ENV_FILE")"
    write_env_file
    info "created $ENV_FILE (mode 600)"
  fi
fi

if [ "$ENV_ONLY" = true ]; then
  echo ""
  echo "Env file ready. Start with: ./scripts/start-lan.sh"
  exit 0
fi

# ── Step 2: Dex (OIDC provider) ──────────────────────────────────────────────

if [ "$OIDC_ENABLED" = true ]; then
  echo ""
  echo "[2/5] Dex OIDC provider"

  # Dex ships ~32 stock assets under /srv/dex/web. Only the login form, its
  # header and the theme overrides differ, so extract the image's copy and lay
  # the tracked files over it instead of committing the whole tree.
  DEX_STAGE="$PROJECT_ROOT/deploy/.runtime/dex"
  DEX_WEB="$DEX_STAGE/web"

  if [ "$DRY_RUN" = true ]; then
    info "would extract $DEX_IMAGE:/srv/dex/web to $DEX_WEB"
    info "would overlay the tracked files from $DEX_TEMPLATE_DIR/web"
    info "would render $DEX_STAGE/config.yaml (issuer $OIDC_ISSUER)"
    info "would run container $DEX_CONTAINER on port $DEX_PORT"
  else
    # The daemon is root-owned; a user outside the docker group needs sudo for
    # every call, so probe once instead of hardcoding either form.
    DOCKER="docker"
    docker info >/dev/null 2>&1 || DOCKER="sudo docker"

    # A previous run through `sudo docker` left root-owned files here, which this
    # account cannot delete. Try unprivileged first so the docker-group path
    # stays free of an extra password prompt, then escalate only if it failed.
    if [ -e "$DEX_STAGE" ] && ! rm -rf "$DEX_STAGE" 2>/dev/null; then
      sudo rm -rf "$DEX_STAGE"
    fi
    mkdir -p "$DEX_STAGE"
    # Dex runs as its own unprivileged user (uid 1001), not as the deploying
    # account, so the mount has to be world-readable and traversable. The
    # secrets live in backend/.env, not here.
    chmod 755 "$DEX_STAGE"

    staging_container="smartperfetto-dex-extract.$$"
    $DOCKER create --name "$staging_container" "$DEX_IMAGE" >/dev/null
    # shellcheck disable=SC2064 # Expand the name now, not at trap time.
    trap "$DOCKER rm -f '$staging_container' >/dev/null 2>&1 || true" RETURN
    $DOCKER cp "${staging_container}:/srv/dex/web" "$DEX_WEB"
    $DOCKER rm -f "$staging_container" >/dev/null
    trap - RETURN
    # `docker cp` writes as whatever user the CLI runs under, so the `sudo
    # docker` fallback (the deploying account is not in the docker group) leaves
    # these files owned by root and the overlay below cannot overwrite them.
    # Hand the tree back to the deploying account first. A `docker`-group run
    # already writes as this account, so it needs no extra elevation.
    if [ "$DOCKER" != "docker" ]; then
      sudo chown -R "$(id -u):$(id -g)" "$DEX_WEB"
    fi
    info "extracted stock web assets from $DEX_IMAGE"

    # Overlay the tracked customisations. cp -a keeps the directory shape so
    # themes/light/smartperfetto.* land beside Dex's own theme files.
    cp -a "$DEX_TEMPLATE_DIR/web/." "$DEX_WEB/"
    # Both `docker cp` and this checkout can carry restrictive modes; normalise
    # them so the container user can read every asset it is asked to serve.
    chmod -R a+rX "$DEX_WEB"
    info "applied the tracked login form and theme"

    # Render the config: substitute every __PLACEHOLDER__ the template declares.
    # Each value is sed-escaped because a secret or URI can contain & or /.
    config_tmp="$DEX_STAGE/config.yaml"
    cp "$DEX_TEMPLATE_DIR/config.yaml.tmpl" "$config_tmp"
    sed_escape() { printf '%s' "$1" | sed -e 's/[&/\]/\\&/g'; }
    sed -i \
      -e "s/__ISSUER__/$(sed_escape "$OIDC_ISSUER")/g" \
      -e "s/__CLIENT_SECRET__/$(sed_escape "$OIDC_CLIENT_SECRET")/g" \
      -e "s/__REDIRECT_URI__/$(sed_escape "$OIDC_REDIRECT_URI")/g" \
      "$config_tmp"
    chmod 644 "$config_tmp"

    # add-user.sh writes to config.yaml next to itself, so give it the rendered
    # file and the values it would otherwise have to rediscover.
    cp "$DEX_TEMPLATE_DIR/add-user.sh" "$DEX_STAGE/add-user.sh"
    sed -i \
      -e "s|__CONTAINER__|$DEX_CONTAINER|g" \
      -e "s|__HEALTH_URL__|http://127.0.0.1:${DEX_PORT}/dex/.well-known/openid-configuration|g" \
      "$DEX_STAGE/add-user.sh"
    chmod 755 "$DEX_STAGE/add-user.sh"
    info "rendered config.yaml and add-user.sh"

    # Replace any previous container so the new config is read. Dex keeps its
    # accounts in memory, so this also clears them.
    if $DOCKER inspect "$DEX_CONTAINER" >/dev/null 2>&1; then
      $DOCKER rm -f "$DEX_CONTAINER" >/dev/null
      info "removed the previous $DEX_CONTAINER"
    fi
    $DOCKER run -d \
      --name "$DEX_CONTAINER" \
      --restart unless-stopped \
      -p "${DEX_PORT}:5556" \
      -v "$DEX_STAGE:/etc/dex" \
      -v "$DEX_WEB:/web" \
      "$DEX_IMAGE" dex serve /etc/dex/config.yaml >/dev/null
    info "started $DEX_CONTAINER on port $DEX_PORT"

    dex_ok=false
    for _ in $(seq 1 20); do
      sleep 1
      if curl -fsS --noproxy '*' --max-time 2 \
        "http://127.0.0.1:${DEX_PORT}/dex/.well-known/openid-configuration" >/dev/null 2>&1; then
        dex_ok=true
        break
      fi
    done
    if [ "$dex_ok" != true ]; then
      echo ""
      echo "Dex did not become reachable. Recent logs:" >&2
      $DOCKER logs "$DEX_CONTAINER" 2>&1 | tail -20 >&2 || true
      die "Dex failed to start"
    fi
    info "Dex is serving"
  fi
fi

# ── Step 3: systemd unit ─────────────────────────────────────────────────────

echo ""
echo "[3/5] systemd unit"

render_unit() {
  cat <<EOF
[Unit]
Description=SmartPerfetto (LAN)
Documentation=file://$PROJECT_ROOT/docs/operations/lan-deployment.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$(id -gn "$SERVICE_USER" 2>/dev/null || echo "$SERVICE_USER")
WorkingDirectory=$PROJECT_ROOT

Environment=HOME=$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)
Environment=SMARTPERFETTO_BIND_HOST=0.0.0.0
Environment=SMARTPERFETTO_FRONTEND_BIND_HOST=0.0.0.0
Environment=SMARTPERFETTO_NO_OPEN=1
Environment=PATH=$NODE_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# No FRONTEND_URL here on purpose: start-lan.sh derives it from the address this
# host has at boot, so a changed or DHCP-assigned IP keeps working.

ExecStart=/bin/bash $PROJECT_ROOT/scripts/start-lan.sh

# start.sh traps SIGTERM and tears down the backend/frontend process tree.
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=90

Restart=on-failure
RestartSec=10

StandardOutput=journal
StandardError=journal
SyslogIdentifier=smartperfetto

[Install]
WantedBy=multi-user.target
EOF
}

if [ "$DRY_RUN" = true ]; then
  info "would write $UNIT_PATH"
  echo ""
  render_unit | sed 's/^/    /'
else
  render_unit | sudo tee "$UNIT_PATH" > /dev/null
  info "wrote $UNIT_PATH"
fi

# ── Step 4: install, enable, start ───────────────────────────────────────────

echo ""
echo "[4/5] enable and start"

# A manually started instance would hold the ports and make the unit fail.
stopped_manual=false
for pid_file in "$PROJECT_ROOT/.backend.pid" "$PROJECT_ROOT/.frontend.pid"; do
  [ -f "$pid_file" ] || continue
  pid="$(grep '^pid=' "$pid_file" 2>/dev/null | cut -d= -f2 || true)"
  [ -n "$pid" ] || continue
  if kill -0 "$pid" 2>/dev/null; then
    stopped_manual=true
    if [ "$DRY_RUN" = true ]; then
      info "would stop manually started process $pid"
    else
      kill "$pid" 2>/dev/null || true
    fi
  fi
done
if [ "$stopped_manual" = true ] && [ "$DRY_RUN" = false ]; then
  sleep 3
  pkill -f "tsx watch --clear-screen=false src/index.ts" 2>/dev/null || true
  pkill -f "frontend/server.js" 2>/dev/null || true
  sleep 1
  info "stopped the manually started instance"
fi

if [ "$DRY_RUN" = true ]; then
  info "would run: systemctl daemon-reload && systemctl enable --now $UNIT_NAME"
else
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$UNIT_NAME" >/dev/null
  info "enabled and started $UNIT_NAME"
fi

# ── Step 5: verify ───────────────────────────────────────────────────────────

echo ""
echo "[5/5] verify"

if [ "$DRY_RUN" = true ]; then
  info "would poll http://127.0.0.1:$FRONTEND_PORT/health and the backend /health"
  exit 0
fi

# A fresh checkout has no backend/node_modules, and start.sh installs them on
# first boot: roughly 1GB and several minutes of npm ci. Waiting the same amount
# on every ordinary restart would be pointless, and a fixed 60s gave up on the
# install instead. Both cases are known before the service starts, so pick the
# deadline from that rather than from whatever the logs happen to say.
#
# The marker check repeats what start.sh decides: a marker from a different Node
# ABI or package-lock hash also triggers a reinstall, so presence alone is not
# proof the next boot is fast.
HEALTH_TIMEOUT_SECONDS=60
NPM_INSTALL_TIMEOUT_SECONDS=1200
needs_install=false
node_modules="$PROJECT_ROOT/backend/node_modules"
if [ ! -d "$node_modules" ]; then
  needs_install=true
elif [ ! -f "$node_modules/.smartperfetto-node-abi" ]; then
  needs_install=true
elif ! grep -qx "node=$("$NODE_BIN" -v)" "$node_modules/.smartperfetto-node-abi" 2>/dev/null; then
  needs_install=true
fi
if [ "$needs_install" = true ]; then
  info "backend dependencies will be (re)installed on first start; allowing up to $(( NPM_INSTALL_TIMEOUT_SECONDS / 60 )) minutes"
  HEALTH_TIMEOUT_SECONDS=$NPM_INSTALL_TIMEOUT_SECONDS
fi

ok=false
started_at=$SECONDS
while [ $(( SECONDS - started_at )) -lt "$HEALTH_TIMEOUT_SECONDS" ]; do
  sleep 2
  if curl -fsS --noproxy '*' --max-time 3 "http://127.0.0.1:${FRONTEND_PORT}/health" >/dev/null 2>&1 \
    && curl -fsS --noproxy '*' --max-time 3 "http://127.0.0.1:3000/health" >/dev/null 2>&1; then
    ok=true
    break
  fi
  # A unit that already died will not recover by waiting out the deadline.
  if ! systemctl is-active --quiet "$UNIT_NAME"; then
    echo ""
    echo "$UNIT_NAME is not running." >&2
    break
  fi
done

if [ "$ok" != true ]; then
  echo ""
  echo "The service did not pass its health checks." >&2
  echo "Recent logs:" >&2
  sudo journalctl -u "$UNIT_NAME" -n 40 --no-pager >&2 || true
  die "deployment failed"
fi

info "frontend and backend are healthy"

echo ""
echo "=============================================="
echo "SmartPerfetto is running"
echo "=============================================="
echo "  UI:      $FRONTEND_ORIGIN"

if [ "$OIDC_ENABLED" = true ]; then
  echo ""
  echo "  First use: add an account, then open the UI and sign in with it."
  echo "    $DEX_STAGE/add-user.sh you@example.com"
  echo ""
  echo "  Dex keeps accounts in memory: recreating the container empties them,"
  echo "  so re-run add-user.sh after any redeploy."
else
  echo "  Token:   sudo grep '^SMARTPERFETTO_API_KEY=' $ENV_FILE"
  echo ""
  echo "  First use: open the UI, expand Advanced backend auth, and paste the"
  echo "  token above into Backend Access Token."
fi

echo ""
echo "  Manage:  sudo systemctl {status,restart,stop} $UNIT_NAME"
echo "  Logs:    sudo journalctl -u $UNIT_NAME -f"
if [ "$OIDC_ENABLED" = true ]; then
  echo "  Dex logs: sudo docker logs $DEX_CONTAINER"
fi
echo "=============================================="
