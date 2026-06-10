#!/usr/bin/env bash
#
# generate-master-env.sh — (re)build config/master.env from live WSO2 IS state.
#
#   ./scripts/generate-master-env.sh [output-file]   # default config/master.env
#
# Starts from config/master.env.template, carries operator-supplied values
# (LLM/AMP keys, URLs) over from any previous master.env, then — when IS is
# reachable and jq is present — looks up the current client IDs/secrets and
# agent IDs by app/display name and writes them in. Keeping each ID and its
# secret in lock-step avoids first-run drift when duplicate app names exist.
# A timestamped backup of the prior file is kept until the run succeeds.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

TEMPLATE_FILE="$ROOT_DIR/config/master.env.template"
OUTPUT_FILE="${1:-$ROOT_DIR/config/master.env}"

ORCH_ENV="$ROOT_DIR/apps/orchestrator/.env"
HR_AGENT_ENV="$ROOT_DIR/apps/hr_agent/.env"
IT_AGENT_ENV="$ROOT_DIR/apps/it_agent/.env"

IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASS="${IS_ADMIN_PASS:-admin}"
IS_BASE_URL="${IS_BASE_URL:-https://localhost:9443}"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
  echo "Missing template: $TEMPLATE_FILE" >&2
  exit 1
fi

OLD_FILE=""
if [[ -f "$OUTPUT_FILE" ]]; then
  OLD_FILE="${OUTPUT_FILE}.bak.$$"
  cp "$OUTPUT_FILE" "$OLD_FILE"
fi

cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Drop the prior-file backup once the run completes successfully.
cleanup() {
  [[ -n "$OLD_FILE" && -f "$OLD_FILE" ]] && rm -f "$OLD_FILE"
}
trap cleanup EXIT

# Write KEY=VALUE into the output master.env, but only when VALUE is non-empty.
set_if_present() {
  upsert_env_if_nonempty "$OUTPUT_FILE" "$1" "$2"
}

# True when the IS admin endpoints are up (JWKS responds).
wso2_reachable() {
  curl -skf "${IS_BASE_URL}/oauth2/jwks" >/dev/null 2>&1
}

# Resolve an OAuth app's clientId from its display name (Application Mgmt API).
wso2_app_client_id_by_name() {
  local app_name="$1"
  local app_id
  app_id="$(curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" "${IS_BASE_URL}/api/server/v1/applications?limit=500" \
    | jq -r --arg n "$app_name" '.applications[]? | select(.name==$n) | .id' | head -n1)"
  [[ -n "$app_id" ]] || return 1
  curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" "${IS_BASE_URL}/api/server/v1/applications/${app_id}" \
    | jq -r '.clientId // empty'
}

# Fetch an app's client_secret by clientId via the DCR register endpoint.
wso2_dcr_client_secret_by_client_id() {
  local client_id="$1"
  [[ -n "$client_id" ]] || return 1
  curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" \
    "${IS_BASE_URL}/api/identity/oauth2/dcr/v1.1/register/${client_id}" \
    | jq -r '.client_secret // empty'
}

# Resolve a WSO2 "Agent" identity's id from its SCIM DisplayName.
wso2_agent_id_by_display_name() {
  local display_name="$1"
  curl -sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}" -H "Accept: application/scim+json" \
    "${IS_BASE_URL}/scim2/Agents?startIndex=1&count=500" \
    | jq -r --arg dn "$display_name" --arg schema "urn:scim:wso2:agent:schema" \
      '.Resources[]? | select((.[$schema].DisplayName // "") == $dn) | .id' \
    | head -n1
}

# Copy a key's value from the previous master.env into the new one, if present.
carry_old_value() {
  local key="$1"
  [[ -n "$OLD_FILE" && -f "$OLD_FILE" ]] || return 0
  local value
  value="$(read_env "$key" "$OLD_FILE" || true)"
  [[ -n "$value" ]] || return 0
  upsert_env "$OUTPUT_FILE" "$key" "$value"
}

# Carry operator-supplied values from previous master env.
for key in \
  LLM_FALLBACK_MODE OPENAI_BASE_URL OPENAI_API_HEADER OPENAI_API_KEY OPENAI_MODEL \
  AMP_OTEL_ENDPOINT AMP_AGENT_API_KEY INTERNAL_REVOKE_SHARED_SECRET ENABLE_UAEPASS \
  MASTER_WSO2_IS_BASE_URL_HOST MASTER_WSO2_IS_BASE_URL_SERVICE MASTER_ORCHESTRATOR_PUBLIC_URL MASTER_ALLOWED_ORIGINS
  do
  carry_old_value "$key"
done

ORCH_CLIENT_ID="$(read_env ORCHESTRATOR_MCP_CLIENT_ID "$ORCH_ENV" || true)"
ORCH_CLIENT_SECRET="$(read_env ORCHESTRATOR_MCP_CLIENT_SECRET "$ORCH_ENV" || true)"
ORCH_REDIRECT="$(read_env ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI "$ORCH_ENV" || true)"
ORCH_POST_LOGOUT="$(read_env POST_LOGOUT_REDIRECT_URI "$ORCH_ENV" || true)"
ORCH_AGENT_ID="$(read_env ORCHESTRATOR_AGENT_ID "$ORCH_ENV" || true)"
ORCH_AGENT_SECRET="$(read_env ORCHESTRATOR_AGENT_SECRET "$ORCH_ENV" || true)"
ORCH_AGENT_OAUTH_ID="$(read_env ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID "$ORCH_ENV" || true)"
ORCH_AGENT_OAUTH_SECRET="$(read_env ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET "$ORCH_ENV" || true)"

HR_AGENT_ID="$(read_env HR_AGENT_ID "$HR_AGENT_ENV" || true)"
HR_AGENT_SECRET="$(read_env HR_AGENT_SECRET "$HR_AGENT_ENV" || true)"
HR_AGENT_OAUTH_ID="$(read_env HR_AGENT_OAUTH_CLIENT_ID "$HR_AGENT_ENV" || true)"
HR_AGENT_OAUTH_SECRET="$(read_env HR_AGENT_OAUTH_CLIENT_SECRET "$HR_AGENT_ENV" || true)"
HR_AGENT_REDIRECT="$(read_env HR_AGENT_REDIRECT_URI "$HR_AGENT_ENV" || true)"

IT_AGENT_ID="$(read_env IT_AGENT_ID "$IT_AGENT_ENV" || true)"
IT_AGENT_SECRET="$(read_env IT_AGENT_SECRET "$IT_AGENT_ENV" || true)"
IT_AGENT_OAUTH_ID="$(read_env IT_AGENT_OAUTH_CLIENT_ID "$IT_AGENT_ENV" || true)"
IT_AGENT_OAUTH_SECRET="$(read_env IT_AGENT_OAUTH_CLIENT_SECRET "$IT_AGENT_ENV" || true)"
IT_AGENT_REDIRECT="$(read_env IT_AGENT_REDIRECT_URI "$IT_AGENT_ENV" || true)"


if command -v jq >/dev/null 2>&1 && wso2_reachable; then
  ORCH_CLIENT_ID="$(wso2_app_client_id_by_name "orchestrator-mcp-client" || true)"
  ORCH_AGENT_OAUTH_ID="$(wso2_app_client_id_by_name "orchestrator-agent-oauth" || true)"
  HR_AGENT_OAUTH_ID="$(wso2_app_client_id_by_name "hr-agent-oauth" || true)"
  IT_AGENT_OAUTH_ID="$(wso2_app_client_id_by_name "it-agent-oauth" || true)"

  # Keep selected IDs and secrets in lock-step to avoid first-run drift when
  # duplicate app names exist in IS and lookup order changes.
  ORCH_CLIENT_SECRET="$(wso2_dcr_client_secret_by_client_id "$ORCH_CLIENT_ID" || true)"
  ORCH_AGENT_OAUTH_SECRET="$(wso2_dcr_client_secret_by_client_id "$ORCH_AGENT_OAUTH_ID" || true)"
  HR_AGENT_OAUTH_SECRET="$(wso2_dcr_client_secret_by_client_id "$HR_AGENT_OAUTH_ID" || true)"
  IT_AGENT_OAUTH_SECRET="$(wso2_dcr_client_secret_by_client_id "$IT_AGENT_OAUTH_ID" || true)"

  ORCH_AGENT_ID="$(wso2_agent_id_by_display_name "orchestrator-agent" || true)"
  HR_AGENT_ID="$(wso2_agent_id_by_display_name "hr-agent" || true)"
  IT_AGENT_ID="$(wso2_agent_id_by_display_name "it-agent" || true)"
fi

set_if_present ORCHESTRATOR_MCP_CLIENT_ID "$ORCH_CLIENT_ID"
set_if_present ORCHESTRATOR_MCP_CLIENT_SECRET "$ORCH_CLIENT_SECRET"
set_if_present ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI "$ORCH_REDIRECT"
set_if_present POST_LOGOUT_REDIRECT_URI "$ORCH_POST_LOGOUT"
set_if_present ORCHESTRATOR_AGENT_ID "$ORCH_AGENT_ID"
set_if_present ORCHESTRATOR_AGENT_SECRET "$ORCH_AGENT_SECRET"
set_if_present ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID "$ORCH_AGENT_OAUTH_ID"
set_if_present ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET "$ORCH_AGENT_OAUTH_SECRET"

set_if_present HR_AGENT_ID "$HR_AGENT_ID"
set_if_present HR_AGENT_SECRET "$HR_AGENT_SECRET"
set_if_present HR_AGENT_OAUTH_CLIENT_ID "$HR_AGENT_OAUTH_ID"
set_if_present HR_AGENT_OAUTH_CLIENT_SECRET "$HR_AGENT_OAUTH_SECRET"
set_if_present HR_AGENT_REDIRECT_URI "$HR_AGENT_REDIRECT"

set_if_present IT_AGENT_ID "$IT_AGENT_ID"
set_if_present IT_AGENT_SECRET "$IT_AGENT_SECRET"
set_if_present IT_AGENT_OAUTH_CLIENT_ID "$IT_AGENT_OAUTH_ID"
set_if_present IT_AGENT_OAUTH_CLIENT_SECRET "$IT_AGENT_OAUTH_SECRET"
set_if_present IT_AGENT_REDIRECT_URI "$IT_AGENT_REDIRECT"


if [[ -n "$HR_AGENT_ID" || -n "$IT_AGENT_ID" ]]; then
  upsert_env "$OUTPUT_FILE" TRUSTED_SPECIALIST_SUBS "${HR_AGENT_ID},${IT_AGENT_ID}"
fi
set_if_present HR_EXPECTED_INBOUND_AUD "$ORCH_CLIENT_ID"
set_if_present IT_EXPECTED_INBOUND_AUD "$ORCH_CLIENT_ID"
set_if_present HR_SERVER_EXPECTED_AUD "$HR_AGENT_OAUTH_ID"
set_if_present IT_SERVER_EXPECTED_AUD "$IT_AGENT_OAUTH_ID"

echo "Generated master env: $OUTPUT_FILE"
