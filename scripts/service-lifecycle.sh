#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2024-2026 Gracker (Chris)
# This file is part of SmartPerfetto. See LICENSE for details.

# Shared lifecycle primitives for SmartPerfetto source launchers.
#
# Keep this file compatible with the macOS system Bash (3.2): do not use
# associative arrays, namerefs, mapfile, wait -n, or Bash 4 case conversion.

SMARTPERFETTO_PID=""
SMARTPERFETTO_PID_GENERATION=""
SMARTPERFETTO_PID_FILE_ERROR=""

smartperfetto_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

smartperfetto_process_start_identity() {
  local pid="$1"
  local value=""

  if [ -r "/proc/$pid/stat" ]; then
    # Linux /proc starttime is field 22, measured in clock ticks since boot.
    # Strip through the final ") " first because comm may contain spaces.
    value=$(sed -n 's/^.*) //p' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}')
    if [ -n "$value" ]; then
      printf 'linux:%s\n' "$value"
      return 0
    fi
  fi

  value=$(ps -p "$pid" -o lstart= 2>/dev/null || true)
  value=$(smartperfetto_trim "$value")
  if [ -n "$value" ]; then
    printf 'ps:%s\n' "$value"
    return 0
  fi
  return 1
}

smartperfetto_process_command() {
  local pid="$1"
  local value
  value=$(ps -p "$pid" -o command= 2>/dev/null || true)
  value=$(smartperfetto_trim "$value")
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

smartperfetto_process_executable() {
  local pid="$1"
  local value=""

  if [ -L "/proc/$pid/exe" ]; then
    value=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
  fi
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

smartperfetto_process_cwd() {
  local pid="$1"
  local value
  value=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
  [ -n "$value" ] || return 1
  (
    cd "$value" 2>/dev/null || exit 1
    pwd -P
  )
}

smartperfetto_new_launch_generation() {
  local role="$1"
  printf '%s-%s-%s-%s\n' "$role" "$$" "$(date +%s)" "${RANDOM:-0}"
}

smartperfetto_pid_file_field() {
  local file="$1"
  local key="$2"
  awk -v prefix="$key=" '
    index($0, prefix) == 1 {
      print substr($0, length(prefix) + 1)
      exit
    }
  ' "$file" 2>/dev/null
}

smartperfetto_write_pid_file() {
  local file="$1"
  local pid="$2"
  local role="$3"
  local project_root="$4"
  local expected_cwd="$5"
  local generation="$6"
  local start_identity
  local command
  local executable
  local actual_cwd
  local tmp="${file}.tmp.$$"

  kill -0 "$pid" 2>/dev/null || {
    echo "ERROR: cannot record $role PID $pid because it is no longer alive." >&2
    return 1
  }
  start_identity=$(smartperfetto_process_start_identity "$pid") || {
    echo "ERROR: cannot determine process identity for $role PID $pid." >&2
    return 1
  }
  command=$(smartperfetto_process_command "$pid") || {
    echo "ERROR: cannot determine command for $role PID $pid." >&2
    return 1
  }
  executable=$(smartperfetto_process_executable "$pid") || {
    echo "ERROR: cannot determine executable for $role PID $pid." >&2
    return 1
  }
  actual_cwd=$(smartperfetto_process_cwd "$pid") || {
    echo "ERROR: cannot determine cwd for $role PID $pid." >&2
    return 1
  }
  if [ "$actual_cwd" != "$expected_cwd" ]; then
    echo "ERROR: $role PID $pid started in unexpected cwd '$actual_cwd'." >&2
    return 1
  fi

  if ! (
    umask 077
    {
      printf 'version=1\n'
      printf 'pid=%s\n' "$pid"
      printf 'role=%s\n' "$role"
      printf 'project_root=%s\n' "$project_root"
      printf 'cwd=%s\n' "$actual_cwd"
      printf 'start_identity=%s\n' "$start_identity"
      printf 'command=%s\n' "$command"
      printf 'executable=%s\n' "$executable"
      printf 'generation=%s\n' "$generation"
    } > "$tmp"
  ); then
    rm -f "$tmp"
    echo "ERROR: cannot write PID metadata for $role." >&2
    return 1
  fi
  mv "$tmp" "$file"
}

# Return values:
#   0: live process identity matches the metadata and expected service
#   1: no live owned process (missing/stale file is cleaned up)
#   2: metadata exists but ownership cannot be proven; caller must not kill
smartperfetto_load_owned_pid_file() {
  local file="$1"
  local expected_role="$2"
  local expected_root="$3"
  local expected_cwd="$4"
  local expected_generation="${5:-}"
  local first_line
  local version
  local pid
  local role
  local project_root
  local cwd
  local start_identity
  local command
  local executable
  local generation
  local actual_start
  local actual_executable
  local actual_cwd

  SMARTPERFETTO_PID=""
  SMARTPERFETTO_PID_GENERATION=""
  SMARTPERFETTO_PID_FILE_ERROR=""
  [ -f "$file" ] || return 1

  first_line=$(head -n 1 "$file" 2>/dev/null || true)
  if [[ "$first_line" =~ ^[0-9]+$ ]]; then
    if kill -0 "$first_line" 2>/dev/null; then
      SMARTPERFETTO_PID_FILE_ERROR="legacy PID file '$file' points to live PID $first_line; ownership cannot be proven"
      return 2
    fi
    rm -f "$file"
    return 1
  fi

  version=$(smartperfetto_pid_file_field "$file" version)
  pid=$(smartperfetto_pid_file_field "$file" pid)
  role=$(smartperfetto_pid_file_field "$file" role)
  project_root=$(smartperfetto_pid_file_field "$file" project_root)
  cwd=$(smartperfetto_pid_file_field "$file" cwd)
  start_identity=$(smartperfetto_pid_file_field "$file" start_identity)
  command=$(smartperfetto_pid_file_field "$file" command)
  executable=$(smartperfetto_pid_file_field "$file" executable)
  generation=$(smartperfetto_pid_file_field "$file" generation)

  if [ "$version" != "1" ] || [[ ! "$pid" =~ ^[0-9]+$ ]] || \
     [ -z "$start_identity" ] || [ -z "$command" ] || [ -z "$executable" ] || \
     [ -z "$generation" ]; then
    SMARTPERFETTO_PID_FILE_ERROR="PID metadata '$file' is incomplete or unsupported"
    return 2
  fi
  if [ "$role" != "$expected_role" ] || [ "$project_root" != "$expected_root" ] || \
     [ "$cwd" != "$expected_cwd" ]; then
    SMARTPERFETTO_PID_FILE_ERROR="PID metadata '$file' does not belong to $expected_role in $expected_root"
    return 2
  fi
  if [ -n "$expected_generation" ] && [ "$generation" != "$expected_generation" ]; then
    SMARTPERFETTO_PID_FILE_ERROR="PID metadata '$file' belongs to a different launch generation"
    return 2
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$file"
    return 1
  fi

  actual_start=$(smartperfetto_process_start_identity "$pid" || true)
  actual_executable=$(smartperfetto_process_executable "$pid" || true)
  actual_cwd=$(smartperfetto_process_cwd "$pid" || true)
  if [ "$actual_start" != "$start_identity" ] || [ "$actual_executable" != "$executable" ] || \
     [ "$actual_cwd" != "$cwd" ]; then
    SMARTPERFETTO_PID_FILE_ERROR="PID $pid identity no longer matches '$file'; refusing to stop a possibly reused process"
    return 2
  fi

  SMARTPERFETTO_PID="$pid"
  SMARTPERFETTO_PID_GENERATION="$generation"
  return 0
}

smartperfetto_remove_pid_file_if_generation() {
  local file="$1"
  local generation="$2"
  local recorded_generation
  [ -f "$file" ] || return 0
  recorded_generation=$(smartperfetto_pid_file_field "$file" generation)
  if [ "$recorded_generation" = "$generation" ]; then
    rm -f "$file"
  fi
}

smartperfetto_collect_process_tree() {
  local pid="$1"
  local child
  local children

  children=$(pgrep -P "$pid" 2>/dev/null || true)
  for child in $children; do
    smartperfetto_collect_process_tree "$child"
  done
  printf '%s\n' "$pid"
}

smartperfetto_terminate_process_tree() {
  local pid="$1"
  local label="$2"
  local tree
  local current
  local remaining=""
  local attempt

  kill -0 "$pid" 2>/dev/null || return 0
  tree=$(smartperfetto_collect_process_tree "$pid" | awk '!seen[$0]++')
  echo "Stopping $label process tree (root PID: $pid)..."

  # The tree is post-order, so descendants receive the signal before wrappers.
  # Keep the snapshot so reparented descendants can still be escalated.
  for current in $tree; do
    kill -TERM "$current" 2>/dev/null || true
  done

  attempt=0
  while [ "$attempt" -lt 30 ]; do
    remaining=""
    for current in $tree; do
      if kill -0 "$current" 2>/dev/null; then
        remaining="$remaining $current"
      fi
    done
    [ -z "$remaining" ] && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done

  echo "Escalating $label process tree to SIGKILL:$(smartperfetto_trim "$remaining")"
  for current in $remaining; do
    kill -KILL "$current" 2>/dev/null || true
  done
}

smartperfetto_stop_owned_pid_file() {
  local file="$1"
  local role="$2"
  local project_root="$3"
  local expected_cwd="$4"
  local rc
  local pid
  local generation

  if smartperfetto_load_owned_pid_file "$file" "$role" "$project_root" "$expected_cwd"; then
    pid="$SMARTPERFETTO_PID"
    generation="$SMARTPERFETTO_PID_GENERATION"
    smartperfetto_terminate_process_tree "$pid" "$role"
    smartperfetto_remove_pid_file_if_generation "$file" "$generation"
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ]; then
    return 0
  fi
  echo "ERROR: $SMARTPERFETTO_PID_FILE_ERROR." >&2
  return "$rc"
}

smartperfetto_stop_owned_pid_file_for_allowed_cwds() {
  local file="$1"
  local role="$2"
  local project_root="$3"
  shift 3
  local first_line
  local recorded_cwd
  local allowed_cwd

  [ -f "$file" ] || return 0
  first_line=$(head -n 1 "$file" 2>/dev/null || true)
  if [[ "$first_line" =~ ^[0-9]+$ ]]; then
    smartperfetto_stop_owned_pid_file "$file" "$role" "$project_root" "$1"
    return $?
  fi

  recorded_cwd=$(smartperfetto_pid_file_field "$file" cwd)
  for allowed_cwd in "$@"; do
    if [ "$recorded_cwd" = "$allowed_cwd" ]; then
      smartperfetto_stop_owned_pid_file \
        "$file" "$role" "$project_root" "$recorded_cwd"
      return $?
    fi
  done
  echo "ERROR: $role PID metadata has an unexpected cwd; refusing to stop it." >&2
  return 2
}

smartperfetto_listener_pids() {
  local port="$1"
  # ss reads /proc/net/tcp directly; lsof -i can hang on hosts with a very
  # large fd address space, and its output duplicates ss for this query.
  ss -ltnp "sport = :$port" 2>/dev/null \
    | grep -oE 'pid=[0-9]+' \
    | cut -d= -f2 \
    | sort -u
}

smartperfetto_show_port_owner() {
  local port="$1"
  ss -ltnp "sport = :$port" 2>/dev/null || true
}

smartperfetto_assert_port_available() {
  local port="$1"
  local label="$2"
  local pids
  pids=$(smartperfetto_listener_pids "$port" || true)
  [ -z "$pids" ] && return 0

  echo "ERROR: $label port $port is already in use." >&2
  smartperfetto_show_port_owner "$port" >&2
  echo "Refusing to stop an unowned listener. Verify it, then stop it explicitly." >&2
  echo "For SmartPerfetto recovery only: ./scripts/stop-dev.sh --force" >&2
  return 1
}

smartperfetto_force_stop_port() {
  local port="$1"
  local label="$2"
  local pids
  local pid
  local attempt
  pids=$(smartperfetto_listener_pids "$port" || true)
  [ -z "$pids" ] && return 0

  echo "Force-stopping listeners on $label port $port after explicit user request:"
  smartperfetto_show_port_owner "$port"
  for pid in $pids; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    sleep 0.1
    pids=$(smartperfetto_listener_pids "$port" || true)
    [ -z "$pids" ] && return 0
    attempt=$((attempt + 1))
  done

  for pid in $pids; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  sleep 0.2
  pids=$(smartperfetto_listener_pids "$port" || true)
  if [ -n "$pids" ]; then
    echo "ERROR: listeners remain on $label port $port after forced stop." >&2
    smartperfetto_show_port_owner "$port" >&2
    return 1
  fi
}

smartperfetto_tail_log() {
  local log_file="$1"
  [ -f "$log_file" ] || return 0
  echo "---- tail: $log_file ----" >&2
  tail -n 40 "$log_file" >&2 || true
}

smartperfetto_wait_for_predicate() {
  local pid="$1"
  local label="$2"
  local timeout_seconds="$3"
  local log_file="$4"
  shift 4
  local attempts=$((timeout_seconds * 5))
  local attempt=1
  local exit_code

  while [ "$attempt" -le "$attempts" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid" 2>/dev/null; then
        exit_code=0
      else
        exit_code=$?
      fi
      echo "ERROR: $label exited before becoming ready (exit $exit_code)." >&2
      smartperfetto_tail_log "$log_file"
      return 1
    fi
    if "$@"; then
      echo "$label is ready (after approximately $(((attempt + 4) / 5))s)."
      return 0
    fi
    sleep 0.2
    attempt=$((attempt + 1))
  done

  echo "ERROR: $label did not become ready within ${timeout_seconds}s." >&2
  smartperfetto_tail_log "$log_file"
  return 1
}

smartperfetto_http_ready() {
  local url="$1"
  curl -fsS --max-time 2 -o /dev/null "$url" 2>/dev/null
}

smartperfetto_wait_for_http() {
  local pid="$1"
  local label="$2"
  local url="$3"
  local timeout_seconds="$4"
  local log_file="$5"
  smartperfetto_wait_for_predicate \
    "$pid" "$label" "$timeout_seconds" "$log_file" \
    smartperfetto_http_ready "$url"
}

# Bash 3.2-compatible wait-for-either implementation. An unexpected zero exit
# is still a service failure because SmartPerfetto requires both processes.
smartperfetto_wait_for_services() {
  local first_pid="$1"
  local first_label="$2"
  local second_pid="$3"
  local second_label="$4"
  local exited_pid=""
  local exited_label=""
  local exit_code

  while :; do
    if ! kill -0 "$first_pid" 2>/dev/null; then
      exited_pid="$first_pid"
      exited_label="$first_label"
      break
    fi
    if ! kill -0 "$second_pid" 2>/dev/null; then
      exited_pid="$second_pid"
      exited_label="$second_label"
      break
    fi
    sleep 0.5
  done

  if wait "$exited_pid" 2>/dev/null; then
    exit_code=0
  else
    exit_code=$?
  fi
  echo "ERROR: $exited_label exited; stopping the remaining SmartPerfetto service (exit $exit_code)." >&2
  if [ "$exit_code" -eq 0 ]; then
    return 1
  fi
  return "$exit_code"
}
