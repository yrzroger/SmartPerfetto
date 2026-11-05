#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2024-2026 Gracker (Chris)
# This file is part of SmartPerfetto. See LICENSE for details.

# SmartPerfetto Development Stop Script
# Stops all SmartPerfetto services and cleans up processes

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SERVICE_PORT_HELPERS="$PROJECT_ROOT/scripts/service-ports.sh"
SERVICE_LIFECYCLE_HELPERS="$PROJECT_ROOT/scripts/service-lifecycle.sh"
# shellcheck source=scripts/service-ports.sh
. "$SERVICE_PORT_HELPERS"
# shellcheck source=scripts/service-lifecycle.sh
. "$SERVICE_LIFECYCLE_HELPERS"
BACKEND_PORT="$(smartperfetto_resolve_backend_port)"
FRONTEND_PORT="$(smartperfetto_resolve_frontend_port)"
BACKEND_CWD="$PROJECT_ROOT/backend"
FRONTEND_SOURCE_CWD="$PROJECT_ROOT/frontend"
FRONTEND_DEV_CWD="$PROJECT_ROOT/perfetto/ui"
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=true
      ;;
    --help|-h)
      echo "Usage: ./scripts/stop-dev.sh [--force]"
      echo ""
      echo "Without --force, only processes whose PID metadata proves ownership by"
      echo "this checkout are stopped. --force additionally stops listeners on the"
      echo "configured backend/frontend ports after printing their exact owners."
      exit 0
      ;;
    *)
      echo "ERROR: unknown option '$1'." >&2
      exit 1
      ;;
  esac
  shift
done

for required_command in pgrep ss; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: required command '$required_command' is not installed." >&2
    exit 1
  fi
done

echo "=============================================="
echo "Stopping SmartPerfetto Services"
echo "=============================================="

STOP_ERROR=0
if ! smartperfetto_stop_owned_pid_file \
  "$PROJECT_ROOT/.backend.pid" "backend" "$PROJECT_ROOT" "$BACKEND_CWD"; then
  STOP_ERROR=1
fi

# Source and dev launchers use different frontend working directories.
if ! smartperfetto_stop_owned_pid_file_for_allowed_cwds \
  "$PROJECT_ROOT/.frontend.pid" "frontend" "$PROJECT_ROOT" \
  "$FRONTEND_SOURCE_CWD" "$FRONTEND_DEV_CWD"; then
  STOP_ERROR=1
fi

if [ "$FORCE" = true ]; then
  if ! smartperfetto_force_stop_port "$BACKEND_PORT" "backend"; then
    STOP_ERROR=1
  fi
  if ! smartperfetto_force_stop_port "$FRONTEND_PORT" "frontend"; then
    STOP_ERROR=1
  fi
else
  if ! smartperfetto_assert_port_available "$BACKEND_PORT" "backend"; then
    STOP_ERROR=1
  fi
  if ! smartperfetto_assert_port_available "$FRONTEND_PORT" "frontend"; then
    STOP_ERROR=1
  fi
fi

echo ""
echo "=============================================="
if [ "$STOP_ERROR" -ne 0 ]; then
  echo "Some listeners were not stopped because ownership could not be proven."
  echo "Inspect the owners above; use --force only after confirming they should stop."
  echo "=============================================="
  exit 1
fi
echo "All launcher-owned SmartPerfetto services stopped."
echo "=============================================="
