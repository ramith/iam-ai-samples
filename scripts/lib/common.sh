#!/usr/bin/env bash
#
# common.sh — shared helpers for the srt-emp shell scripts.
#
# SOURCE this file, do not execute it:
#     source "$(dirname "$0")/lib/common.sh"     # from scripts/*.sh
#     source "$ROOT_DIR/scripts/lib/common.sh"   # from repo-root *.sh
#
# Provides: Docker / Compose CLI detection and .env upsert/read helpers that
# were previously copy-pasted across start.sh, stop.sh, grep-trace.sh,
# generate-master-env.sh and render-envs-from-master.sh.

# Guard against double-sourcing.
[[ -n "${_SRT_COMMON_SH:-}" ]] && return 0
_SRT_COMMON_SH=1

# ---------------------------------------------------------------------------
# Docker / Compose CLI
# ---------------------------------------------------------------------------

# Resolved once into COMPOSE_CMD as an array, e.g. (docker compose) or
# (docker-compose). Prefer v2; fall back to the standalone v1 binary. A host
# with only one of the two would otherwise silently produce zero results.
COMPOSE_CMD=()

require_docker() {
  command -v docker >/dev/null 2>&1 || {
    echo "docker is not installed or not on PATH" >&2
    exit 1
  }
}

detect_compose_cmd() {
  [[ ${#COMPOSE_CMD[@]} -gt 0 ]] && return 0
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    echo "error: neither 'docker compose' (v2) nor 'docker-compose' (v1) is available" >&2
    return 1
  fi
}

# Run a compose subcommand with the detected CLI.
compose_cmd() {
  detect_compose_cmd || exit 1
  "${COMPOSE_CMD[@]}" "$@"
}

# ---------------------------------------------------------------------------
# .env file helpers
# ---------------------------------------------------------------------------

# upsert_env <file> <key> <value> — set KEY=VALUE in-place, or append if absent.
upsert_env() {
  local file="$1" key="$2" value="$3"
  if [[ -f "$file" ]] && grep -qE "^${key}=" "$file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$file" && rm -f "${file}.bak"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# upsert_env_if_nonempty <file> <key> <value> — upsert only when value is set.
upsert_env_if_nonempty() {
  [[ -n "$3" ]] || return 0
  upsert_env "$1" "$2" "$3"
}

# read_env <key> <file> — print the cleaned value of KEY=... (last wins).
# Strips surrounding quotes and a trailing CR. Returns 1 when the file is
# missing, the key is absent/empty, or the value is an unrendered <PLACEHOLDER>.
read_env() {
  local key="$1" file="$2" value
  [[ -f "$file" ]] || return 1
  value="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d'=' -f2- || true)"
  value="${value%$'\r'}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  [[ "$value" == '<'*'>' ]] && return 1
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}
