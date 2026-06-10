#!/usr/bin/env bash
#
# render-envs-from-master.sh — fan config/master.env out into each service .env.
#
#   ./scripts/render-envs-from-master.sh [master-env]   # default config/master.env
#
# Sources master.env, then upserts the per-service WSO2 URLs, client IDs/secrets,
# audiences, trusted-peer lists and feature flags into apps/*/.env (creating each
# from its .env.example when missing). Derived defaults (e.g. resource-server REST
# audiences from the orchestrator MCP client id) keep the services in sync after a
# bootstrap regenerates IDs. Idempotent: safe to re-run. The legacy standalone
# client SPA is intentionally not rendered (the orchestrator serves the SPA).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

MASTER_ENV="${1:-$ROOT_DIR/config/master.env}"

if [[ ! -f "$MASTER_ENV" ]]; then
  echo "Master env not found: $MASTER_ENV" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$MASTER_ENV"
set +a

# Create a service .env from its .env.example (or an empty file) only if absent;
# never clobbers an existing .env.
ensure_file_from_example_if_missing() {
  local file="$1"
  local example="$2"
  if [[ -f "$file" ]]; then
    return 0
  fi
  if [[ -f "$example" ]]; then
    cp "$example" "$file"
  else
    : > "$file"
  fi
}

ORCH_ENV="$ROOT_DIR/apps/orchestrator/.env"
HR_AGENT_ENV="$ROOT_DIR/apps/hr_agent/.env"
IT_AGENT_ENV="$ROOT_DIR/apps/it_agent/.env"
HR_SERVER_ENV="$ROOT_DIR/apps/hr_server/.env"
IT_SERVER_ENV="$ROOT_DIR/apps/it_server/.env"

ensure_file_from_example_if_missing "$ORCH_ENV" "$ROOT_DIR/apps/orchestrator/.env.example"
ensure_file_from_example_if_missing "$HR_AGENT_ENV" "$ROOT_DIR/apps/hr_agent/.env.example"
ensure_file_from_example_if_missing "$IT_AGENT_ENV" "$ROOT_DIR/apps/it_agent/.env.example"
ensure_file_from_example_if_missing "$HR_SERVER_ENV" "$ROOT_DIR/apps/hr_server/.env.example"
ensure_file_from_example_if_missing "$IT_SERVER_ENV" "$ROOT_DIR/apps/it_server/.env.example"

SERVICE_BASE_URL="${MASTER_WSO2_IS_BASE_URL_SERVICE:-https://wso2is:9443}"
HOST_BASE_URL="${MASTER_WSO2_IS_BASE_URL_HOST:-https://localhost:9443}"
PUBLIC_URL="${MASTER_ORCHESTRATOR_PUBLIC_URL:-http://localhost:8090}"
ALLOWED_ORIGINS="${MASTER_ALLOWED_ORIGINS:-http://localhost:8090,http://127.0.0.1:8090}"

# orchestrator
upsert_env "$ORCH_ENV" WSO2_IS_BASE_URL "$SERVICE_BASE_URL"
upsert_env "$ORCH_ENV" WSO2_IS_BROWSER_BASE_URL "$HOST_BASE_URL"
upsert_env "$ORCH_ENV" WSO2_IS_ISSUER "$SERVICE_BASE_URL/oauth2/token"
upsert_env "$ORCH_ENV" WSO2_IS_JWKS_URL "$SERVICE_BASE_URL/oauth2/jwks"
upsert_env "$ORCH_ENV" IDP_INSECURE_TLS "${MASTER_IDP_INSECURE_TLS:-1}"
upsert_env_if_nonempty "$ORCH_ENV" ORCHESTRATOR_MCP_CLIENT_ID "${ORCHESTRATOR_MCP_CLIENT_ID:-}"
upsert_env_if_nonempty "$ORCH_ENV" ORCHESTRATOR_MCP_CLIENT_SECRET "${ORCHESTRATOR_MCP_CLIENT_SECRET:-}"
upsert_env "$ORCH_ENV" ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI "${ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI:-$PUBLIC_URL/agent-callback}"
upsert_env "$ORCH_ENV" POST_LOGOUT_REDIRECT_URI "${POST_LOGOUT_REDIRECT_URI:-$PUBLIC_URL/}"
upsert_env_if_nonempty "$ORCH_ENV" ORCHESTRATOR_AGENT_ID "${ORCHESTRATOR_AGENT_ID:-}"
upsert_env_if_nonempty "$ORCH_ENV" ORCHESTRATOR_AGENT_SECRET "${ORCHESTRATOR_AGENT_SECRET:-}"
upsert_env_if_nonempty "$ORCH_ENV" ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID "${ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID:-}"
upsert_env_if_nonempty "$ORCH_ENV" ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET "${ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET:-}"
upsert_env_if_nonempty "$ORCH_ENV" HR_AGENT_OAUTH_CLIENT_ID "${HR_AGENT_OAUTH_CLIENT_ID:-}"
upsert_env_if_nonempty "$ORCH_ENV" IT_AGENT_OAUTH_CLIENT_ID "${IT_AGENT_OAUTH_CLIENT_ID:-}"
upsert_env_if_nonempty "$ORCH_ENV" TRUSTED_SPECIALIST_SUBS "${TRUSTED_SPECIALIST_SUBS:-}"
upsert_env "$ORCH_ENV" OPENAI_BASE_URL "${OPENAI_BASE_URL:-}"
upsert_env "$ORCH_ENV" OPENAI_API_HEADER "${OPENAI_API_HEADER:-api-key}"
upsert_env_if_nonempty "$ORCH_ENV" OPENAI_API_KEY "${OPENAI_API_KEY:-}"
upsert_env "$ORCH_ENV" OPENAI_MODEL "${OPENAI_MODEL:-gpt-4.1}"
upsert_env "$ORCH_ENV" LLM_FALLBACK_MODE "${LLM_FALLBACK_MODE:-keyword}"
# Feature flag (single source of truth: master.env). Drives the SPA sign-in
# branding via /api/app-config. Defaults to false (stock, no UAEPass).
upsert_env "$ORCH_ENV" ENABLE_UAEPASS "${ENABLE_UAEPASS:-false}"
upsert_env "$ORCH_ENV" ALLOWED_ORIGINS "$ALLOWED_ORIGINS"
upsert_env_if_nonempty "$ORCH_ENV" AMP_OTEL_ENDPOINT "${AMP_OTEL_ENDPOINT:-}"
upsert_env_if_nonempty "$ORCH_ENV" AMP_AGENT_API_KEY "${AMP_AGENT_API_KEY:-}"
upsert_env_if_nonempty "$ORCH_ENV" INTERNAL_REVOKE_SHARED_SECRET "${INTERNAL_REVOKE_SHARED_SECRET:-}"

# hr agent
upsert_env "$HR_AGENT_ENV" WSO2_IS_BASE_URL "$SERVICE_BASE_URL"
upsert_env "$HR_AGENT_ENV" WSO2_IS_ISSUER "$SERVICE_BASE_URL/oauth2/token"
upsert_env "$HR_AGENT_ENV" WSO2_IS_JWKS_URL "$SERVICE_BASE_URL/oauth2/jwks"
upsert_env "$HR_AGENT_ENV" IDP_INSECURE_TLS "${MASTER_IDP_INSECURE_TLS:-1}"
upsert_env_if_nonempty "$HR_AGENT_ENV" HR_AGENT_ID "${HR_AGENT_ID:-}"
upsert_env_if_nonempty "$HR_AGENT_ENV" HR_AGENT_SECRET "${HR_AGENT_SECRET:-}"
upsert_env_if_nonempty "$HR_AGENT_ENV" HR_AGENT_OAUTH_CLIENT_ID "${HR_AGENT_OAUTH_CLIENT_ID:-}"
upsert_env_if_nonempty "$HR_AGENT_ENV" HR_AGENT_OAUTH_CLIENT_SECRET "${HR_AGENT_OAUTH_CLIENT_SECRET:-}"
upsert_env "$HR_AGENT_ENV" HR_AGENT_REDIRECT_URI "${HR_AGENT_REDIRECT_URI:-http://localhost:9999/agent-callback}"
upsert_env "$HR_AGENT_ENV" HR_EXPECTED_INBOUND_AUD "${HR_EXPECTED_INBOUND_AUD:-${ORCHESTRATOR_MCP_CLIENT_ID:-}}"
upsert_env_if_nonempty "$HR_AGENT_ENV" HR_TRUSTED_PEER_AGENTS "${ORCHESTRATOR_AGENT_ID:-}"
upsert_env_if_nonempty "$HR_AGENT_ENV" AMP_OTEL_ENDPOINT "${AMP_OTEL_ENDPOINT:-}"
upsert_env_if_nonempty "$HR_AGENT_ENV" AMP_AGENT_API_KEY "${AMP_AGENT_API_KEY:-}"
upsert_env_if_nonempty "$HR_AGENT_ENV" INTERNAL_REVOKE_SHARED_SECRET "${INTERNAL_REVOKE_SHARED_SECRET:-}"

# it agent
upsert_env "$IT_AGENT_ENV" WSO2_IS_BASE_URL "$SERVICE_BASE_URL"
upsert_env "$IT_AGENT_ENV" WSO2_IS_ISSUER "$SERVICE_BASE_URL/oauth2/token"
upsert_env "$IT_AGENT_ENV" WSO2_IS_JWKS_URL "$SERVICE_BASE_URL/oauth2/jwks"
upsert_env "$IT_AGENT_ENV" IDP_INSECURE_TLS "${MASTER_IDP_INSECURE_TLS:-1}"
upsert_env_if_nonempty "$IT_AGENT_ENV" IT_AGENT_ID "${IT_AGENT_ID:-}"
upsert_env_if_nonempty "$IT_AGENT_ENV" IT_AGENT_SECRET "${IT_AGENT_SECRET:-}"
upsert_env_if_nonempty "$IT_AGENT_ENV" IT_AGENT_OAUTH_CLIENT_ID "${IT_AGENT_OAUTH_CLIENT_ID:-}"
upsert_env_if_nonempty "$IT_AGENT_ENV" IT_AGENT_OAUTH_CLIENT_SECRET "${IT_AGENT_OAUTH_CLIENT_SECRET:-}"
upsert_env "$IT_AGENT_ENV" IT_AGENT_REDIRECT_URI "${IT_AGENT_REDIRECT_URI:-http://localhost:9999/agent-callback}"
upsert_env "$IT_AGENT_ENV" IT_EXPECTED_INBOUND_AUD "${IT_EXPECTED_INBOUND_AUD:-${ORCHESTRATOR_MCP_CLIENT_ID:-}}"
upsert_env_if_nonempty "$IT_AGENT_ENV" IT_TRUSTED_PEER_AGENTS "${ORCHESTRATOR_AGENT_ID:-}"
upsert_env_if_nonempty "$IT_AGENT_ENV" AMP_OTEL_ENDPOINT "${AMP_OTEL_ENDPOINT:-}"
upsert_env_if_nonempty "$IT_AGENT_ENV" AMP_AGENT_API_KEY "${AMP_AGENT_API_KEY:-}"
upsert_env_if_nonempty "$IT_AGENT_ENV" INTERNAL_REVOKE_SHARED_SECRET "${INTERNAL_REVOKE_SHARED_SECRET:-}"

# hr server
upsert_env "$HR_SERVER_ENV" WSO2_IS_BASE_URL "$SERVICE_BASE_URL"
upsert_env "$HR_SERVER_ENV" AUTH_ISSUER "$SERVICE_BASE_URL/oauth2/token"
upsert_env "$HR_SERVER_ENV" JWKS_URL "$SERVICE_BASE_URL/oauth2/jwks"
upsert_env "$HR_SERVER_ENV" WSO2_IS_INTROSPECT_URL "$SERVICE_BASE_URL/oauth2/introspect"
upsert_env_if_nonempty "$HR_SERVER_ENV" HR_SERVER_EXPECTED_AUD "${HR_SERVER_EXPECTED_AUD:-${HR_AGENT_OAUTH_CLIENT_ID:-}}"
# REST reports use the user's token-A (aud=orchestrator-mcp-client). Derive the
# valid REST audience from the MCP client id so it tracks bootstrap regeneration.
upsert_env_if_nonempty "$HR_SERVER_ENV" HR_SERVER_REST_VALID_AUDIENCES "${HR_SERVER_REST_VALID_AUDIENCES:-${ORCHESTRATOR_MCP_CLIENT_ID:-}}"
upsert_env_if_nonempty "$HR_SERVER_ENV" HR_SERVER_TRUSTED_PEER_AGENTS "${HR_AGENT_ID:-}"
upsert_env "$HR_SERVER_ENV" ALLOWED_ORIGINS "$ALLOWED_ORIGINS"
upsert_env_if_nonempty "$HR_SERVER_ENV" INTERNAL_REVOKE_SHARED_SECRET "${INTERNAL_REVOKE_SHARED_SECRET:-}"

# it server
upsert_env "$IT_SERVER_ENV" WSO2_IS_BASE_URL "$SERVICE_BASE_URL"
upsert_env "$IT_SERVER_ENV" AUTH_ISSUER "$SERVICE_BASE_URL/oauth2/token"
upsert_env "$IT_SERVER_ENV" JWKS_URL "$SERVICE_BASE_URL/oauth2/jwks"
upsert_env "$IT_SERVER_ENV" WSO2_IS_INTROSPECT_URL "$SERVICE_BASE_URL/oauth2/introspect"
upsert_env_if_nonempty "$IT_SERVER_ENV" IT_SERVER_EXPECTED_AUD "${IT_SERVER_EXPECTED_AUD:-${IT_AGENT_OAUTH_CLIENT_ID:-}}"
upsert_env_if_nonempty "$IT_SERVER_ENV" IT_SERVER_REST_VALID_AUDIENCES "${IT_SERVER_REST_VALID_AUDIENCES:-${ORCHESTRATOR_MCP_CLIENT_ID:-}}"
upsert_env_if_nonempty "$IT_SERVER_ENV" IT_SERVER_TRUSTED_PEER_AGENTS "${IT_AGENT_ID:-}"
upsert_env "$IT_SERVER_ENV" ALLOWED_ORIGINS "$ALLOWED_ORIGINS"
upsert_env_if_nonempty "$IT_SERVER_ENV" AMP_OTEL_ENDPOINT "${AMP_OTEL_ENDPOINT:-}"
upsert_env_if_nonempty "$IT_SERVER_ENV" AMP_AGENT_API_KEY "${AMP_AGENT_API_KEY:-}"
upsert_env_if_nonempty "$IT_SERVER_ENV" INTERNAL_REVOKE_SHARED_SECRET "${INTERNAL_REVOKE_SHARED_SECRET:-}"

# NOTE: the standalone client SPA (legacy :3001) was removed — the browser SPA
# is served by the orchestrator and authenticates via orchestrator-mcp-client,
# so no client-spa OAuth client / apps/client env is rendered.

echo "Rendered env files from $MASTER_ENV"
