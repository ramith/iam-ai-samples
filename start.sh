#!/usr/bin/env bash
#
# start.sh — interactive bring-up for the full srt-emp stack.
#
# Flow:
#   1. Prompt for a build mode (cache / no-cache / skip) and a cleanup mode.
#   2. Boot WSO2 IS first; its container entrypoint runs the bootstrap that
#      provisions OAuth apps, scopes, roles, demo users and the UAEPass IdP.
#   3. Generate config/master.env from the live IS state, prompt for external
#      secrets (LLM / AMP keys), then render each service's .env from it.
#   4. Build + (re)create the five Python services and verify that the secrets
#      rendered into each .env actually reached the running container.
#
# Env overrides: WSO2IS_VERSION, IS_ADMIN_USER/PASS, RUN_MANUAL_BOOTSTRAP=1,
#   ENABLE_UAEPASS=true|false (skips the login-mode prompt; true = UAEPass
#   federated login + branding, false = plain default IAM).
# Shared helpers (compose detection, env read/write) live in scripts/lib/common.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

MASTER_TEMPLATE="$ROOT_DIR/config/master.env.template"
MASTER_ENV="$ROOT_DIR/config/master.env"
ORCH_ENV="$ROOT_DIR/apps/orchestrator/.env"
HR_AGENT_ENV="$ROOT_DIR/apps/hr_agent/.env"
IT_AGENT_ENV="$ROOT_DIR/apps/it_agent/.env"

IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASS="${IS_ADMIN_PASS:-admin}"

require_docker

if ! docker info >/dev/null 2>&1; then
  if command -v colima >/dev/null 2>&1; then
    echo "docker daemon is not reachable. Starting colima..."
    colima start
  else
    echo "docker daemon is not reachable. Start your Docker runtime and retry." >&2
    exit 1
  fi
fi

detect_compose_cmd || exit 1

# Prompt for an optional master.env value, defaulting to the current value
# (Enter keeps it). Writes the result back to master.env.
prompt_value() {
  local key="$1"
  local prompt_text="$2"
  local default answer
  default="$(read_env "$key" "$MASTER_ENV" || true)"
  read -r -p "$prompt_text [${default:-empty}]: " answer
  upsert_env "$MASTER_ENV" "$key" "${answer:-$default}"
}

# Prompt for a mandatory master.env value, re-asking until non-empty.
ensure_required_value() {
  local key="$1"
  local prompt_text="$2"
  local current answer
  current="$(read_env "$key" "$MASTER_ENV" || true)"
  while [[ -z "$current" ]]; do
    read -r -p "$prompt_text [required]: " answer
    answer="${answer//$'\r'/}"
    if [[ -z "$answer" ]]; then
      echo "$key is required." >&2
      continue
    fi
    upsert_env "$MASTER_ENV" "$key" "$answer"
    current="$answer"
  done
}

# Block until IS serves JWKS and the bootstrap has dropped its ready marker,
# or until max_wait elapses (returns 1 on timeout).
wait_for_wso2() {
  local max_wait=300
  local deadline=$((SECONDS + max_wait))
  echo "Waiting for WSO2 IS readiness (JWKS + bootstrap marker) ..."
  while (( SECONDS < deadline )); do
    if curl -skf https://localhost:9443/oauth2/jwks >/dev/null 2>&1 \
      && [[ -f "$ROOT_DIR/.bootstrap/wso2is.ready" ]]; then
      echo "WSO2 IS is ready."
      return 0
    fi
    sleep 2
  done
  echo "WSO2 IS did not become ready in time." >&2
  return 1
}

# Phase 1: bring up only the WSO2 IS container (per the chosen build mode) so
# its entrypoint can bootstrap before the app services need its OAuth clients.
start_wso2_only() {
  local build_mode="$1"
  # Clear stale marker so readiness reflects the current startup/bootstrap cycle.
  rm -f "$ROOT_DIR/.bootstrap/wso2is.ready"
  case "$build_mode" in
    cache)
      compose_cmd up -d --build wso2is
      ;;
    no-cache)
      compose_cmd build --no-cache wso2is
      compose_cmd up -d --force-recreate wso2is
      ;;
    skip)
      compose_cmd up -d wso2is
      ;;
  esac
}

# Phase 2: build (per build mode) and force-recreate the five Python services
# after their .env files are rendered, so the new env values are picked up.
start_full_stack() {
  local build_mode="$1"
  local app_services=(orchestrator hr_agent it_agent hr_server it_server)
  case "$build_mode" in
    cache)
      # Phase 2: build app images after envs are rendered.
      compose_cmd build "${app_services[@]}"
      # Start from built images and force container recreation so env_file is re-read.
      compose_cmd up -d --force-recreate --no-build "${app_services[@]}"
      ;;
    no-cache)
      # Phase 2: no-cache app builds after envs are rendered.
      compose_cmd build --no-cache "${app_services[@]}"
      compose_cmd up -d --force-recreate --no-build "${app_services[@]}"
      ;;
    skip)
      # Skip image builds but still recreate app services to pick up new env values.
      compose_cmd up -d --force-recreate --no-build "${app_services[@]}"
      ;;
  esac
}

# Read an env var as seen inside a running service container (printenv).
container_env_value() {
  local service="$1"
  local key="$2"
  compose_cmd exec -T "$service" /bin/sh -lc "printenv $key 2>/dev/null || true"
}

# Confirm each service container actually received the secret rendered into its
# .env (catches stale containers that weren't recreated after a regen).
verify_runtime_env_sync() {
  # rows: "<service> <env-file> <key>"
  local rows=(
    "orchestrator $ORCH_ENV ORCHESTRATOR_MCP_CLIENT_SECRET"
    "orchestrator $ORCH_ENV ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET"
    "hr_agent $HR_AGENT_ENV HR_AGENT_OAUTH_CLIENT_SECRET"
    "it_agent $IT_AGENT_ENV IT_AGENT_OAUTH_CLIENT_SECRET"
  )
  local row service env_file key expected actual
  for row in "${rows[@]}"; do
    read -r service env_file key <<<"$row"
    expected="$(read_env "$key" "$env_file" || true)"
    [[ -n "$expected" ]] || continue
    actual="$(container_env_value "$service" "$key")"
    if [[ "$expected" != "$actual" ]]; then
      echo "runtime env mismatch: $service $key" >&2
      return 1
    fi
  done
  return 0
}

echo "⚙️  Choose build option:"
echo "  1) Build with cache   (default)"
echo "  2) Build without cache"
echo "  3) Skip build"
read -r -p "Select build option [1-3] (Enter = 1): " build_choice

BUILD_MODE="cache"
case "$build_choice" in
  1|"") BUILD_MODE="cache" ;;
  2) BUILD_MODE="no-cache" ;;
  3) BUILD_MODE="skip" ;;
  *) echo "Invalid build option" >&2; exit 1 ;;
esac

echo "🧹 Choose cleanup option before starting:"
echo "  1) Clean start (stop and remove all existing containers, volumes)   (default)"
echo "  2) Keep existing (start alongside running containers)"
echo "  3) Exit"
read -r -p "Select cleanup option [1-3] (Enter = 1): " cleanup_choice

case "$cleanup_choice" in
  1|"")
    compose_cmd down --volumes --remove-orphans || true
    ;;
  2)
    ;;
  3)
    echo "Exiting."
    exit 0
    ;;
  *)
    echo "Invalid cleanup option" >&2
    exit 1
    ;;
esac

# Login mode: UAEPass federated login + branding, or plain default IAM.
# config/master.env (ENABLE_UAEPASS, default false) is the SINGLE SOURCE OF TRUTH:
# the IS bootstrap reads it from the mounted master.env and the orchestrator gets
# it rendered into its .env — neither relies on a shell/compose env var.
# Precedence: a pre-set ENABLE_UAEPASS env (non-interactive) wins and is written
# back to master.env; otherwise the prompt default comes from master.env.
if [[ -z "${ENABLE_UAEPASS:-}" ]]; then
  _uaepass_default="$(read_env ENABLE_UAEPASS "$MASTER_ENV" 2>/dev/null || true)"
  [[ "$_uaepass_default" == "true" ]] || _uaepass_default="false"
  echo "🔐 Choose login mode (default from master.env: ENABLE_UAEPASS=${_uaepass_default}):"
  echo "  1) UAEPass     (UAEPass federated login + UAE PASS branding)"
  echo "  2) Default IAM (local Basic auth only, neutral Smart Employee branding)"
  read -r -p "Select login mode [1-2] (Enter = keep default): " login_choice
  case "$login_choice" in
    1) ENABLE_UAEPASS="true" ;;
    2) ENABLE_UAEPASS="false" ;;
    "") ENABLE_UAEPASS="$_uaepass_default" ;;
    *) echo "Invalid login mode" >&2; exit 1 ;;
  esac
fi
# Persist the resolved value into master.env so it's the source of truth that the
# IS bootstrap (reads master.env) and render step (orchestrator .env) consume.
upsert_env "$MASTER_ENV" ENABLE_UAEPASS "$ENABLE_UAEPASS"
# Export too as a fallback for host-side steps (e.g. RUN_MANUAL_BOOTSTRAP) — the
# container itself reads master.env, not this shell var.
export ENABLE_UAEPASS
if [[ "$ENABLE_UAEPASS" == "true" ]]; then
  echo "Login mode: UAEPass (federated login + branding)."
else
  echo "Login mode: default IAM (local Basic auth, Smart Employee branding)."
fi

if [[ ! -f "$MASTER_TEMPLATE" ]]; then
  echo "Missing master template: $MASTER_TEMPLATE" >&2
  exit 1
fi

echo "Preparing WSO2 baseline (startup + bootstrap + env generation)..."
start_wso2_only "$BUILD_MODE"
wait_for_wso2
# WSO2 container entrypoint already runs bootstrap on startup.
# To force an extra manual bootstrap, run with RUN_MANUAL_BOOTSTRAP=1 ./start.sh
if [[ "${RUN_MANUAL_BOOTSTRAP:-0}" == "1" ]]; then
  echo "RUN_MANUAL_BOOTSTRAP=1 -> running manual bootstrap pass..."
  "$ROOT_DIR/scripts/bootstrap-wso2is-entrypoint.sh"
else
  echo "Skipping manual bootstrap (entrypoint bootstrap already completed)."
fi
"$ROOT_DIR/scripts/generate-master-env.sh" "$MASTER_ENV"

echo
echo "Enter external configuration values (press Enter to keep current/default)."
prompt_value OPENAI_API_KEY "OPENAI_API_KEY (LLM key)"
prompt_value AMP_AGENT_API_KEY "AMP_AGENT_API_KEY"

"$ROOT_DIR/scripts/render-envs-from-master.sh" "$MASTER_ENV"

echo "Starting full stack..."
start_full_stack "$BUILD_MODE"

echo "Verifying runtime env sync..."
verify_runtime_env_sync || {
  echo "runtime env sync verification failed; refusing to continue." >&2
  exit 1
}

echo
echo "Stack started."
