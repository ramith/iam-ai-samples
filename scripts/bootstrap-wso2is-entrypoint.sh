#!/usr/bin/env bash
#
# bootstrap-wso2is-entrypoint.sh — idempotent provisioning of WSO2 IS for the
# srt-emp demo. Invoked by the IS container entrypoint once the server is up
# (also runnable by hand: RUN_MANUAL_BOOTSTRAP=1 ./start.sh).
#
# It waits for the admin API, then ensures (create-or-update, safe to re-run):
#   - demo users + roles and their role assignments
#   - the WSO2 "Agent" identities (orchestrator / hr / it) + duplicate cleanup
#   - API resources and scopes
#   - the OAuth apps (orchestrator MCP client, agent OAuth clients) with the
#     right grant types, redirect/logout URIs, email-as-subject, JWT access
#     tokens, skip-consent, org-role audience and authorized APIs
#   - the UAEPass IdP (claims, logo) and its attachment + app branding
# Generated client IDs/secrets are written back into apps/*/.env when those
# files are writable (a read-only mount is tolerated with a warning).
#
# Config via env: IS_BASE_URL, IS_ADMIN_USER/PASS, IS_AGENT_OWNER,
# BOOTSTRAP_WAIT_SECONDS. All IS calls go through the single http() helper.
set -euo pipefail

IS_BASE_URL="${IS_BASE_URL:-https://localhost:9443}"
IS_ADMIN_USER="${IS_ADMIN_USER:-admin}"
IS_ADMIN_PASS="${IS_ADMIN_PASS:-admin}"
IS_AGENT_OWNER="${IS_AGENT_OWNER:-admin@carbon.super}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
APPS_ROOT="${PROJECT_ROOT}/apps"
ORCH_ENV_FILE="${APPS_ROOT}/orchestrator/.env"
ORCH_ENV_EXAMPLE="${APPS_ROOT}/orchestrator/.env.example"
HR_ENV_FILE="${APPS_ROOT}/hr_agent/.env"
HR_ENV_EXAMPLE="${APPS_ROOT}/hr_agent/.env.example"
IT_ENV_FILE="${APPS_ROOT}/it_agent/.env"
IT_ENV_EXAMPLE="${APPS_ROOT}/it_agent/.env.example"

PATCH_SCHEMA="urn:ietf:params:scim:api:messages:2.0:PatchOp"
AGENT_SCHEMA="urn:scim:wso2:agent:schema"

log() { echo "[bootstrap] $*" >&2; }
warn() { echo "[bootstrap][warn] $*" >&2; }

# True if the env file (or its dir, when the file is absent) is writable.
can_write_env_file() {
  local env_file="$1"
  local env_dir
  env_dir="$(dirname "$env_file")"
  if [[ -e "$env_file" ]]; then
    [[ -w "$env_file" ]]
    return
  fi
  [[ -d "$env_dir" && -w "$env_dir" ]]
}

# Create a service .env from its .env.example (or empty) if missing; tolerate a
# read-only mount with a warning.
ensure_env_file() {
  local env_file="$1"
  local env_example="$2"
  if [[ -f "$env_file" ]]; then
    return 0
  fi

  if ! can_write_env_file "$env_file"; then
    warn "cannot create ${env_file} (read-only mount); continuing with in-memory/default values"
    return 0
  fi

  if [[ -f "$env_example" ]]; then
    cp "$env_example" "$env_file"
  else
    : > "$env_file"
  fi
}

# Set or append KEY=VALUE in a service .env, skipping (with a warning) when the
# mount is read-only. Container-local variant: keeps secrets out of stdout.
upsert_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  if ! can_write_env_file "$env_file"; then
    warn "cannot update ${env_file} (read-only mount); ${key} will not be persisted"
    return 0
  fi
  if grep -qE "^${key}=" "$env_file"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$env_file" && rm -f "${env_file}.bak"
  else
    echo "${key}=${value}" >> "$env_file"
  fi
}

# Random 32-char alphanumeric client id.
generate_client_id() {
  openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 32
}

# Random base64 client secret.
generate_client_secret() {
  openssl rand -base64 48 | tr -d '\n'
}

# True when a value is still an unrendered <PLACEHOLDER>.
is_placeholder() {
  local value="$1"
  [[ "$value" == '<'*'>' ]]
}

# The single IS admin-API chokepoint. http <METHOD> <PATH> [DATA] [ACCEPT] [CTYPE].
# Sends basic-auth admin creds, captures the response into HTTP_BODY and the
# status into HTTP_CODE (callers branch on HTTP_CODE).
http() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local accept="${4:-application/json}"
  local ctype="${5:-application/json}"
  local url="${IS_BASE_URL}${path}"
  local response

  local args=(-sk -u "${IS_ADMIN_USER}:${IS_ADMIN_PASS}"
    -H "Accept: ${accept}"
    -X "$method" "$url"
    -w $'\n%{http_code}')
  if [[ -n "$data" ]]; then
    args+=(-H "Content-Type: ${ctype}" -d "$data")
  fi
  response="$(curl "${args[@]}")"

  HTTP_CODE="${response##*$'\n'}"
  HTTP_BODY="${response%$'\n'*}"
}

# Print the first non-empty, non-placeholder value of KEY across the given files
# (later args are fallbacks); return 1 if none match.
read_env_value() {
  local key="$1"
  shift
  local file value
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    value="$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
    if [[ -n "$value" ]] && ! is_placeholder "$value"; then
      echo "$value"
      return 0
    fi
  done
  return 1
}

# Poll the admin API until it answers 200 or BOOTSTRAP_WAIT_SECONDS elapses.
wait_for_admin() {
  local max_wait="${BOOTSTRAP_WAIT_SECONDS:-300}"
  local deadline=$((SECONDS + max_wait))
  log "waiting for admin API access on ${IS_BASE_URL}"
  while (( SECONDS < deadline )); do
    http GET "/api/server/v1/api-resources"
    if [[ "$HTTP_CODE" == "200" ]]; then
      log "admin API is reachable"
      return 0
    fi
    sleep 2
  done
  warn "admin API did not become ready in ${max_wait}s"
  return 1
}

# Create a demo user (or no-op if it already exists), setting password/claims.
ensure_user() {
  local username="$1"
  local password="$2"
  local given="$3"
  local family="$4"

  http GET "/scim2/Users?startIndex=1&count=200" "" "application/scim+json"
  if [[ "$HTTP_CODE" == "200" ]]; then
    local uid
    uid="$(jq -r --arg u "$username" '.Resources[]? | select(.userName==$u) | .id' <<<"$HTTP_BODY" | head -n 1)"
    if [[ -n "$uid" ]]; then
      log "user exists: ${username}"
      if [[ -n "$password" ]]; then
        local patch
        patch="$(jq -n --arg schema "$PATCH_SCHEMA" --arg pwd "$password" '{
          schemas:[$schema],
          Operations:[{op:"replace",path:"password",value:$pwd}]
        }')"
        http PATCH "/scim2/Users/${uid}" "$patch" "application/scim+json" "application/scim+json"
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
          log "ensured password for user: ${username}"
        else
          warn "failed to update password for user ${username} (HTTP ${HTTP_CODE})"
        fi
      fi
      echo "$uid"
      return 0
    fi
  fi

  local payload
  payload="$(jq -n --arg username "$username" --arg password "$password" --arg given "$given" --arg family "$family" '{
    schemas:["urn:ietf:params:scim:schemas:core:2.0:User"],
    userName:$username,
    password:$password,
    name:{givenName:$given,familyName:$family},
    emails:[{value:$username,primary:true}],
    active:true
  }')"

  http POST "/scim2/Users" "$payload" "application/scim+json" "application/scim+json"
  if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
    local created_id
    created_id="$(jq -r '.id // empty' <<<"$HTTP_BODY")"
    log "created user: ${username}"
    echo "$created_id"
    return 0
  fi

  warn "failed to create user ${username} (HTTP ${HTTP_CODE})"
  echo ""
}

# Create an organization role with its permissions/scopes if not already present.
ensure_role() {
  local role_name="$1"
  shift
  local expected_scopes=("$@")

  http GET "/scim2/v2/Roles?startIndex=1&count=200" "" "application/scim+json"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not list roles (HTTP ${HTTP_CODE})"
    echo ""
    return 0
  fi

  local role_id
  role_id="$(jq -r --arg name "$role_name" '.Resources[]? | select(.displayName==$name) | .id' <<<"$HTTP_BODY" | head -n 1)"

  if [[ -z "$role_id" ]]; then
    local perm_json payload
    perm_json="$(printf '%s\n' "${expected_scopes[@]}" | jq -R . | jq -s 'map({value:.})')"
    payload="$(jq -n --arg name "$role_name" --argjson perms "$perm_json" '{
      schemas:["urn:ietf:params:scim:schemas:core:2.0:Role"],
      displayName:$name,
      permissions:$perms
    }')"
    http POST "/scim2/v2/Roles" "$payload" "application/scim+json" "application/scim+json"
    if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
      # Some IS builds reject permissions on create; retry with minimal payload.
      payload="$(jq -n --arg name "$role_name" '{
        schemas:["urn:ietf:params:scim:schemas:core:2.0:Role"],
        displayName:$name
      }')"
      http POST "/scim2/v2/Roles" "$payload" "application/scim+json" "application/scim+json"
      if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
        warn "failed to create role ${role_name} (HTTP ${HTTP_CODE})"
        echo ""
        return 0
      fi
    fi
    role_id="$(jq -r '.id // empty' <<<"$HTTP_BODY")"
    log "created role: ${role_name}"
  else
    log "role exists: ${role_name}"
  fi

  [[ -n "$role_id" ]] || { echo ""; return 0; }

  http GET "/scim2/v2/Roles/${role_id}" "" "application/scim+json"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read role details for ${role_name} (HTTP ${HTTP_CODE})"
    echo "$role_id"
    return 0
  fi

  local current=() missing=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && current+=("$line")
  done < <(jq -r '.permissions[]? | if type=="string" then . else (.value // .display // .name // empty) end' <<<"$HTTP_BODY")

  local scope found
  for scope in "${expected_scopes[@]}"; do
    found=0
    for c in "${current[@]:-}"; do
      [[ "$c" == "$scope" ]] && found=1 && break
    done
    [[ "$found" -eq 1 ]] || missing+=("$scope")
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    log "role permissions aligned: ${role_name}"
    echo "$role_id"
    return 0
  fi

  local missing_json patch_payload
  missing_json="$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s 'map({value:.})')"
  patch_payload="$(jq -n --arg schema "$PATCH_SCHEMA" --argjson perms "$missing_json" '{
    schemas:[$schema],
    Operations:[{op:"add",path:"permissions",value:$perms}]
  }')"

  http PATCH "/scim2/v2/Roles/${role_id}" "$patch_payload" "application/scim+json" "application/scim+json"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    log "added missing permissions to role: ${role_name}"
  else
    warn "failed to patch role permissions for ${role_name} (HTTP ${HTTP_CODE})"
  fi

  echo "$role_id"
}

# Assign the given roles to a user (idempotent SCIM PATCH).
ensure_user_roles() {
  local user_id="$1"
  shift
  local role_ids=("$@")
  [[ -n "$user_id" ]] || return 0
  [[ "${#role_ids[@]}" -gt 0 ]] || return 0

  local rid
  for rid in "${role_ids[@]}"; do
    [[ -n "$rid" ]] || continue

    http GET "/scim2/v2/Roles/${rid}" "" "application/scim+json"
    if [[ "$HTTP_CODE" != "200" ]]; then
      warn "could not read role ${rid} for user association (HTTP ${HTTP_CODE})"
      continue
    fi

    local already_assigned
    already_assigned="$(jq -r --arg uid "$user_id" '[(.users // [])[] | .value] | index($uid) // empty' <<<"$HTTP_BODY")"
    if [[ -n "$already_assigned" ]]; then
      log "role ${rid} already associated to user ${user_id}"
      continue
    fi

    local users_json payload
    users_json="$(jq -n --arg uid "$user_id" '[{value:$uid}]')"
    payload="$(jq -n --arg schema "$PATCH_SCHEMA" --argjson users "$users_json" '{
      schemas:[$schema],
      Operations:[{op:"add",path:"users",value:$users}]
    }')"

    http PATCH "/scim2/v2/Roles/${rid}" "$payload" "application/scim+json" "application/scim+json"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
      log "associated user ${user_id} to role ${rid}"
    else
      warn "failed to associate user ${user_id} to role ${rid} (HTTP ${HTTP_CODE})"
      [[ -n "$HTTP_BODY" ]] && warn "role ${rid} user-association response: ${HTTP_BODY}"
    fi
  done
}

# Create a WSO2 "Agent" identity (orchestrator/hr/it) and return its id.
ensure_agent() {
  local display_name="$1"
  local owner="$2"
  local desired_secret="$3"

  http GET "/scim2/Agents" "" "application/scim+json"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not list agents (HTTP ${HTTP_CODE})"
    return 0
  fi

  local agent_ids=() agent_id
  while IFS= read -r line; do
    [[ -n "$line" ]] && agent_ids+=("$line")
  done < <(jq -r --arg dn "$display_name" --arg schema "$AGENT_SCHEMA" '.Resources[]? | select((.[$schema].DisplayName // "")==$dn) | .id' <<<"$HTTP_BODY")

  if [[ "${#agent_ids[@]}" -gt 1 ]]; then
    log "duplicate agents found for ${display_name}; keeping ${agent_ids[0]} and removing extras"
    local dup_id
    for dup_id in "${agent_ids[@]:1}"; do
      http DELETE "/scim2/Agents/${dup_id}" "" "application/scim+json"
      if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
        log "removed duplicate agent ${display_name}: ${dup_id}"
      else
        warn "failed to remove duplicate agent ${display_name} (${dup_id}) (HTTP ${HTTP_CODE})"
      fi
    done
  fi

  agent_id="${agent_ids[0]:-}"

  if [[ -z "$agent_id" ]]; then
    local payload
    payload="$(jq -n --arg schema "$AGENT_SCHEMA" --arg dn "$display_name" --arg owner "$owner" '{
      ($schema):{
        DisplayName:$dn,
        Description:("Demo agent: " + $dn),
        Owner:$owner
      }
    }')"
    http POST "/scim2/Agents" "$payload" "application/scim+json" "application/scim+json"
    if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
      warn "failed to create agent ${display_name} (HTTP ${HTTP_CODE})"
      return 0
    fi
    agent_id="$(jq -r '.id // empty' <<<"$HTTP_BODY")"
    log "created agent: ${display_name}"
  else
    log "agent exists: ${display_name}"
  fi

  if [[ -n "$desired_secret" && -n "$agent_id" ]]; then
    local patch
    patch="$(jq -n --arg schema "$PATCH_SCHEMA" --arg secret "$desired_secret" '{
      schemas:[$schema],
      Operations:[{op:"replace",path:"password",value:$secret}]
    }')"
    http PATCH "/scim2/Agents/${agent_id}" "$patch" "application/scim+json" "application/scim+json"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
      log "ensured agent secret: ${display_name}"
    else
      warn "failed to set agent secret for ${display_name} (HTTP ${HTTP_CODE})"
    fi
  fi

  echo "$agent_id"
}

# Remove extra Agent identities sharing a display name, keeping a single canonical one.
reconcile_agent_duplicates() {
  local display_name="$1"

  http GET "/scim2/Agents?startIndex=1&count=500" "" "application/scim+json"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not list agents for duplicate reconciliation (HTTP ${HTTP_CODE})"
    return 0
  fi

  local ids=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && ids+=("$line")
  done < <(jq -r --arg dn "$display_name" --arg schema "$AGENT_SCHEMA" '.Resources[]? | select((.[$schema].DisplayName // "") == $dn) | .id' <<<"$HTTP_BODY")

  if [[ "${#ids[@]}" -le 1 ]]; then
    return 0
  fi

  log "post-check duplicates for ${display_name}; keeping ${ids[0]} and removing extras"
  local dup_id
  for dup_id in "${ids[@]:1}"; do
    http DELETE "/scim2/Agents/${dup_id}" "" "application/scim+json"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
      log "removed duplicate agent ${display_name}: ${dup_id}"
    else
      warn "failed to remove duplicate agent ${display_name} (${dup_id}) (HTTP ${HTTP_CODE})"
    fi
  done
}

# Create an API resource and its scopes (identified by identifier/URI) if absent.
ensure_api_resource() {
  local name="$1"
  local identifier="$2"
  shift 2
  local scopes=("$@")

  http GET "/api/server/v1/api-resources?limit=200"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not list API resources (HTTP ${HTTP_CODE})"
    echo ""
    return 0
  fi

  local api_id
  api_id="$(jq -r --arg n "$name" --arg i "$identifier" '.apiResources[]? | select(.name==$n or .identifier==$i) | .id' <<<"$HTTP_BODY" | head -n 1)"

  if [[ -z "$api_id" ]]; then
    local scopes_json payload
    scopes_json="$(printf '%s\n' "${scopes[@]}" | jq -R . | jq -s 'map({name:.,displayName:.,description:.})')"
    payload="$(jq -n --arg n "$name" --arg i "$identifier" --argjson scopes "$scopes_json" '{
      name:$n,
      identifier:$i,
      description:("" + $n + " resource for smart-employee demo"),
      requiresAuthorization:true,
      scopes:$scopes
    }')"
    http POST "/api/server/v1/api-resources" "$payload"
    if [[ "$HTTP_CODE" != "201" && "$HTTP_CODE" != "200" ]]; then
      warn "failed to create API resource ${name} (HTTP ${HTTP_CODE})"
      echo ""
      return 0
    fi
    api_id="$(jq -r '.id // empty' <<<"$HTTP_BODY")"
    log "created API resource: ${name}"
  else
    log "API resource exists: ${name}"
  fi

  [[ -n "$api_id" ]] || { echo ""; return 0; }

  http GET "/api/server/v1/api-resources/${api_id}/scopes"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not list scopes for ${name} (HTTP ${HTTP_CODE})"
    echo "$api_id"
    return 0
  fi

  local current=() missing=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && current+=("$line")
  done < <(jq -r '.[]? | .name // empty' <<<"$HTTP_BODY")

  local s found
  for s in "${scopes[@]}"; do
    found=0
    for c in "${current[@]:-}"; do
      [[ "$c" == "$s" ]] && found=1 && break
    done
    [[ "$found" -eq 1 ]] || missing+=("$s")
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    local add_json patch
    add_json="$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s 'map({name:.,displayName:.,description:.})')"
    patch="$(jq -n --argjson adds "$add_json" '{addedScopes:$adds}')"
    http PATCH "/api/server/v1/api-resources/${api_id}" "$patch"
    if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
      log "added missing scopes to API resource: ${name}"
    else
      warn "failed to patch scopes for API resource ${name} (HTTP ${HTTP_CODE})"
    fi
  else
    log "API scopes aligned: ${name}"
  fi

  echo "$api_id"
}

# Echo the application id whose inbound OAuth clientId matches, or nothing.
find_app_by_client_id() {
  local client_id="$1"
  http GET "/api/server/v1/applications?filter=clientId+eq+${client_id}"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo ""
    return 0
  fi
  jq -r --arg cid "$client_id" '.applications[]? | select(.clientId==$cid) | .id' <<<"$HTTP_BODY" | head -n 1
}

# Echo the application id whose display name matches, or nothing.
find_app_by_name() {
  local app_name="$1"
  http GET "/api/server/v1/applications?limit=200"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo ""
    return 0
  fi
  jq -r --arg n "$app_name" '.applications[]? | select(.name==$n) | .id' <<<"$HTTP_BODY" | head -n 1
}

# Fetch an app's client_secret by clientId via the DCR register endpoint.
dcr_client_secret_by_client_id() {
  local client_id="$1"
  [[ -n "$client_id" ]] || { echo ""; return 0; }
  http GET "/api/identity/oauth2/dcr/v1.1/register/${client_id}"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo ""
    return 0
  fi
  jq -r '.client_secret // empty' <<<"$HTTP_BODY"
}

# Disable the login consent prompt for an app (skipConsent=true).
ensure_skip_login_consent() {
  # Skip the OAuth login-consent prompt so IS auto-grants all role-permitted
  # scopes. Required for federated (UAEPass) users: the programmatic Pattern-C
  # flow can't drive a consent page, so without this IS only issues the OIDC
  # default scopes (email/openid/profile) and role scopes like hr_read_rest are
  # dropped -> reports 403.
  local app_id="$1"
  local app_name="$2"
  [[ -n "$app_id" ]] || return 0
  http PATCH "/api/server/v1/applications/${app_id}" '{"advancedConfigurations":{"skipLoginConsent":true}}'
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "skip login consent enabled: ${app_name:-$app_id}"
  else
    warn "failed to set skipLoginConsent for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# Enable app-native (API-based) authentication for the app.
ensure_app_native_auth_enabled() {
  local app_id="$1"
  local app_name="$2"
  [[ -n "$app_id" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read application ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local enabled
  enabled="$(jq -r '.advancedConfigurations.enableAPIBasedAuthentication // false' <<<"$HTTP_BODY")"
  if [[ "$enabled" == "true" ]]; then
    log "app-native auth already enabled: ${app_name:-$app_id}"
    return 0
  fi

  local payload
  payload='{"advancedConfigurations":{"enableAPIBasedAuthentication":true}}'
  http PATCH "/api/server/v1/applications/${app_id}" "$payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "enabled app-native auth: ${app_name:-$app_id}"
  else
    warn "failed to enable app-native auth for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# Make the app assert email as the OIDC subject (stable sub across tokens).
ensure_email_subject() {
  # Set the OIDC subject identifier to emailaddress so that token-A.sub == email
  # for users with an emailaddress attribute. Without this, sub is the user-id UUID
  # and the sidebar/reports store lookups fail because data is keyed by email.
  local app_id="$1"
  local app_name="$2"
  [[ -n "$app_id" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read application ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local current_claim current_mapped
  current_claim="$(jq -r '.claimConfiguration.subject.claim.uri // ""' <<<"$HTTP_BODY")"
  current_mapped="$(jq -r '.claimConfiguration.subject.useMappedLocalSubject // false' <<<"$HTTP_BODY")"
  if [[ "$current_claim" == "http://wso2.org/claims/emailaddress" && "$current_mapped" == "true" ]]; then
    log "email subject + mapped-local-subject already set: ${app_name:-$app_id}"
    return 0
  fi

  # useMappedLocalSubject=true: a federated (UAEPass) user is resolved to its
  # linked local account, so the LOCAL account's roles drive OAuth scope
  # authorization. Without it, federated logins get only OIDC default scopes
  # (no hr_read_rest/hr_self_rest) -> reports/sidebar 403. Local logins are
  # unaffected (their mapped local subject is themselves).
  local payload
  payload='{"claimConfiguration":{"subject":{"claim":{"uri":"http://wso2.org/claims/emailaddress"},"includeUserDomain":false,"includeTenantDomain":false,"useMappedLocalSubject":true,"mappedLocalSubjectMandatory":false}}}'
  http PATCH "/api/server/v1/applications/${app_id}" "$payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "set email subject + mapped-local-subject: ${app_name:-$app_id}"
  else
    warn "failed to set email subject for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# Set allowedAudience=ORGANIZATION so org roles map into token scopes.
ensure_org_role_audience() {
  # Set associatedRoles.allowedAudience=ORGANIZATION so that organization-level
  # roles (HR Admin, employee) are used for CIBA scope resolution. Without this,
  # IS only considers APPLICATION-audience roles and strips all business API
  # scopes from the issued token-B, producing ERR-MCP-003 on every tool call.
  local app_id="$1"
  local app_name="$2"
  [[ -n "$app_id" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read application ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local current_audience
  current_audience="$(jq -r '.associatedRoles.allowedAudience // "APPLICATION"' <<<"$HTTP_BODY")"
  if [[ "$current_audience" == "ORGANIZATION" ]]; then
    log "org role audience already set: ${app_name:-$app_id}"
    return 0
  fi

  local payload
  payload='{"associatedRoles":{"allowedAudience":"ORGANIZATION"}}'
  http PATCH "/api/server/v1/applications/${app_id}" "$payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "set org role audience: ${app_name:-$app_id}"
  else
    warn "failed to set org role audience for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# Apply the OIDC inbound settings an agent OAuth client needs (grants, etc.).
ensure_agent_oidc_settings() {
  local app_id="$1"
  local app_name="$2"
  local redirect_uri="$3"
  # Optional 4th arg: agent OBO access-token lifetime in seconds (default 120s / 2 min).
  local token_expiry="${4:-120}"
  [[ -n "$app_id" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}/inbound-protocols/oidc"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read OIDC inbound settings for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local desired
  desired="$(jq -c --arg redir "$redirect_uri" --argjson exp "$token_expiry" '
    .accessToken.type = "JWT"
    | .accessToken.userAccessTokenExpiryInSeconds = $exp
    | .accessToken.applicationAccessTokenExpiryInSeconds = $exp
    | .grantTypes = (((.grantTypes // []) + ["urn:openid:params:grant-type:ciba"]) | unique)
    | .callbackURLs = (if ($redir|length) > 0 then (((.callbackURLs // []) + [$redir]) | unique) else (.callbackURLs // []) end)
    | .cibaAuthenticationRequest.authReqExpiryTime = ((.cibaAuthenticationRequest.authReqExpiryTime // 0) | if . > 0 then . else 300 end)
    | .cibaAuthenticationRequest.notificationChannels = (((.cibaAuthenticationRequest.notificationChannels // []) + ["external", "poll"]) | unique)
  ' <<<"$HTTP_BODY")"

  if [[ "$desired" == "$(jq -c . <<<"$HTTP_BODY")" ]]; then
    log "OIDC inbound already aligned: ${app_name:-$app_id}"
    return 0
  fi

  http PUT "/api/server/v1/applications/${app_id}/inbound-protocols/oidc" "$desired"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "reconciled OIDC inbound settings: ${app_name:-$app_id}"
  else
    warn "failed to reconcile OIDC inbound settings for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# Switch the app's access-token type to self-contained JWT.
ensure_oidc_access_token_jwt() {
  local app_id="$1"
  local app_name="$2"
  local redirect_uri="${3:-}"
  [[ -n "$app_id" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}/inbound-protocols/oidc"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read OIDC inbound settings for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local desired
  desired="$(jq -c --arg redir "$redirect_uri" '
    .accessToken.type = "JWT"
    | .callbackURLs = (if ($redir|length) > 0 then (((.callbackURLs // []) + [$redir]) | unique) else (.callbackURLs // []) end)
  ' <<<"$HTTP_BODY")"

  if [[ "$desired" == "$(jq -c . <<<"$HTTP_BODY")" ]]; then
    log "OIDC access token type already aligned: ${app_name:-$app_id}"
    return 0
  fi

  http PUT "/api/server/v1/applications/${app_id}/inbound-protocols/oidc" "$desired"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "reconciled OIDC access token type: ${app_name:-$app_id}"
  else
    warn "failed to reconcile OIDC access token type for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# WSO2 IS validates the RP-initiated logout `post_logout_redirect_uri` against
# the app's OAuth callbackURL (OIDCLogoutServlet: "Provided Post logout redirect
# URL does not match the registered callback url"). The login redirect
# (.../agent-callback) and the post-logout redirect (the SPA root, e.g.
# http://localhost:8090/) differ, so a single literal callbackURL cannot match
# both. Set a regex callbackURL alternating the two so login AND logout pass.
# Register the RP-initiated-logout callback URL (regex) on the app.
ensure_logout_callback_regex() {
  local app_id="$1"
  local app_name="$2"
  local redirect_uri="$3"
  local post_logout_uri="$4"
  [[ -n "$app_id" ]] || return 0
  [[ -n "$redirect_uri" && -n "$post_logout_uri" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}/inbound-protocols/oidc"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not read OIDC inbound settings for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local regex desired
  regex="regexp=(${redirect_uri}|${post_logout_uri})"
  desired="$(jq -c --arg re "$regex" '.callbackURLs = [$re]' <<<"$HTTP_BODY")"

  if [[ "$desired" == "$(jq -c . <<<"$HTTP_BODY")" ]]; then
    log "OIDC logout callback regex already aligned: ${app_name:-$app_id}"
    return 0
  fi

  http PUT "/api/server/v1/applications/${app_id}/inbound-protocols/oidc" "$desired"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "set OIDC logout callback regex: ${app_name:-$app_id}"
  else
    warn "failed to set OIDC logout callback regex for ${app_name:-$app_id} (HTTP ${HTTP_CODE})"
  fi
}

# Build a DCR (dynamic client registration) JSON body. Confidential clients pass
# a client_secret; public clients pass "" and set auth_method=none. Optional
# fields (secret, redirect, post-logout, auth-method) are included only when set,
# so this one helper covers every register payload the bootstrap needs.
build_dcr_payload() {
  local name="$1" cid="$2" csec="$3" redir="$4" post="$5" grants_json="$6" auth_method="${7:-}"
  jq -n --arg name "$name" --arg cid "$cid" --arg csec "$csec" \
        --arg redir "$redir" --arg post "$post" --arg am "$auth_method" --argjson grants "$grants_json" '
    {client_name:$name, client_id:$cid, grant_types:$grants}
    + (if ($csec|length)  > 0 then {client_secret:$csec}                 else {} end)
    + (if ($redir|length) > 0 then {redirect_uris:[$redir]}              else {} end)
    + (if ($post|length)  > 0 then {post_logout_redirect_uris:[$post]}   else {} end)
    + (if ($am|length)    > 0 then {token_endpoint_auth_method:$am}      else {} end)
  '
}

# Provision an agent OAuth client app (hr/it/orchestrator-agent) with CIBA + JWT settings.
ensure_service_provider_app() {
  local app_name="$1"
  local client_id="$2"
  local client_secret="$3"
  local redirect_uri="$4"
  local post_logout_uri="$5"
  shift 5
  local grant_types=("$@")

  [[ -n "$client_id" ]] || { warn "missing client_id for ${app_name}; skipping"; return 0; }

  local existing_id
  existing_id="$(find_app_by_client_id "$client_id")"
  if [[ -n "$existing_id" ]]; then
    log "service provider exists: ${app_name}"
    return 0
  fi

  existing_id="$(find_app_by_name "$app_name")"
  if [[ -n "$existing_id" ]]; then
    log "service provider exists by name: ${app_name}"
    return 0
  fi

  [[ -n "$client_secret" ]] || { warn "missing client_secret for ${app_name}; skipping create"; return 0; }

  local grants_json payload
  grants_json="$(printf '%s\n' "${grant_types[@]}" | sed '/^$/d' | jq -R . | jq -s '.')"
  payload="$(build_dcr_payload "$app_name" "$client_id" "$client_secret" "$redirect_uri" "$post_logout_uri" "$grants_json")"

  http POST "/api/identity/oauth2/dcr/v1.1/register" "$payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "created service provider: ${app_name}"
    return 0
  fi

  # Fallback for IS builds that reject non-default grant types via DCR.
  local fallback_payload
  fallback_payload="$(build_dcr_payload "$app_name" "$client_id" "$client_secret" "$redirect_uri" "$post_logout_uri" '["authorization_code","refresh_token"]')"
  http POST "/api/identity/oauth2/dcr/v1.1/register" "$fallback_payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "created service provider with fallback grants: ${app_name}"
  elif [[ "$HTTP_CODE" == "400" ]] && jq -e '.error=="invalid_client_metadata" and ((.error_description // "") | test("already exist"; "i"))' >/dev/null 2>&1 <<<"$HTTP_BODY"; then
    log "service provider already exists by name: ${app_name}"
  else
    warn "failed to create service provider ${app_name} (HTTP ${HTTP_CODE})"
    [[ -n "$HTTP_BODY" ]] && warn "${app_name} response: ${HTTP_BODY}"
  fi
}

# Authorize an app to call an API resource with the given scopes (UC-06 grants).
ensure_authorized_api() {
  local app_id="$1"
  local api_id="$2"
  shift 2
  local expected_scopes=("$@")

  [[ -n "$app_id" && -n "$api_id" ]] || return 0

  http GET "/api/server/v1/applications/${app_id}/authorized-apis"
  if [[ "$HTTP_CODE" != "200" ]]; then
    warn "could not list authorized APIs for app ${app_id} (HTTP ${HTTP_CODE})"
    return 0
  fi

  local found
  found="$(jq -r --arg aid "$api_id" '.[]? | select(.id==$aid) | .id' <<<"$HTTP_BODY" | head -n 1)"

  if [[ -z "$found" ]]; then
    local scopes_json payload
    scopes_json="$(printf '%s\n' "${expected_scopes[@]}" | jq -R . | jq -s '.')"
    payload="$(jq -n --arg aid "$api_id" --argjson scopes "$scopes_json" '{id:$aid,policyIdentifier:"RBAC",scopes:$scopes}')"
    http POST "/api/server/v1/applications/${app_id}/authorized-apis" "$payload"
    if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
      log "authorized API ${api_id} for app ${app_id}"
    else
      warn "failed to authorize API ${api_id} for app ${app_id} (HTTP ${HTTP_CODE})"
    fi
    return 0
  fi

  local current=() add=() remove=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && current+=("$line")
  done < <(jq -r --arg aid "$api_id" '.[]? | select(.id==$aid) | .authorizedScopes[]?.name' <<<"$HTTP_BODY")

  local s c exists
  for s in "${expected_scopes[@]}"; do
    exists=0
    for c in "${current[@]:-}"; do
      [[ "$c" == "$s" ]] && exists=1 && break
    done
    [[ "$exists" -eq 1 ]] || add+=("$s")
  done

  for c in "${current[@]:-}"; do
    exists=0
    for s in "${expected_scopes[@]}"; do
      [[ "$s" == "$c" ]] && exists=1 && break
    done
    [[ "$exists" -eq 1 ]] || remove+=("$c")
  done

  if [[ "${#add[@]}" -eq 0 && "${#remove[@]}" -eq 0 ]]; then
    log "authorized scopes aligned for app ${app_id} / api ${api_id}"
    return 0
  fi

  local add_json rem_json patch
  add_json="$(printf '%s\n' "${add[@]:-}" | sed '/^$/d' | jq -R . | jq -s '.')"
  rem_json="$(printf '%s\n' "${remove[@]:-}" | sed '/^$/d' | jq -R . | jq -s '.')"
  patch="$(jq -n --argjson a "$add_json" --argjson r "$rem_json" '{addedScopes:$a,removedScopes:$r}')"
  http PATCH "/api/server/v1/applications/${app_id}/authorized-apis/${api_id}" "$patch"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "updated authorized scopes for app ${app_id} / api ${api_id}"
  else
    warn "failed to patch authorized scopes for app ${app_id} / api ${api_id} (HTTP ${HTTP_CODE})"
  fi
}

# ── UAEPass federated IdP (staging) ─────────────────────────────────────────
#
# Creates a UAEPass OIDC federated IdP using the connector deployed in dropins
# (org.wso2.carbon.identity.authenticator.uaepass-1.1.6.jar). Staging endpoints
# + public sandbox credentials (sandbox_stage). JIT provisioning is enabled so
# UAEPass logins map to local accounts (pre-created for sivanoly@/ramith@) whose
# roles drive scopes. Idempotent: skips if an IdP named "UAEPass" exists.
# Create/update the UAEPass federated IdP (OIDC endpoints, secrets).
ensure_uaepass_idp() {
  local idp_name="UAEPass"
  # Registered authenticator: name "UAEPassAuthenticator", id = base64url(name)
  # with no padding (verified against /meta/federated-authenticators).
  local auth_name="UAEPassAuthenticator"
  local auth_id
  auth_id="$(printf '%s' "$auth_name" | base64 | tr '+/' '-_' | tr -d '=\n')"

  local client_id="${UAEPASS_CLIENT_ID:-sandbox_stage}"
  local client_secret="${UAEPASS_CLIENT_SECRET:-sandbox_stage}"
  local callback="${UAEPASS_CALLBACK_URL:-https://localhost:9443/commonauth}"
  local acr="${UAEPASS_ACR:-urn:safelayer:tws:policies:authentication:level:low}"

  # Already present?
  http GET "/api/server/v1/identity-providers?limit=100"
  if [[ "$HTTP_CODE" == "200" ]] && jq -e --arg n "$idp_name" '.identityProviders[]?|select(.name==$n)' >/dev/null 2>&1 <<<"$HTTP_BODY"; then
    log "idp exists: ${idp_name}"
    UAEPASS_IDP_ID="$(jq -r --arg n "$idp_name" '.identityProviders[]|select(.name==$n)|.id' <<<"$HTTP_BODY" | head -n1)"
    return 0
  fi

  local payload
  payload="$(jq -n \
    --arg name "$idp_name" \
    --arg authId "$auth_id" \
    --arg cid "$client_id" --arg csec "$client_secret" --arg cb "$callback" \
    --arg acr "$acr" \
    '{
      name: $name,
      description: "UAEPass federated IdP (staging sandbox).",
      image: "assets/images/logos/uaepass-logo.png",
      isPrimary: false,
      isFederationHub: false,
      certificate: { certificates: [] },
      claims: {
        userIdClaim: { uri: "http://wso2.org/claims/username" },
        provisioningClaims: []
      },
      federatedAuthenticators: {
        defaultAuthenticatorId: $authId,
        authenticators: [
          {
            authenticatorId: $authId,
            isEnabled: true,
            properties: [
              { key: "client_id", value: $cid },
              { key: "ClientSecret", value: $csec },
              { key: "callbackUrl", value: $cb },
              { key: "IsStagingEnv", value: "true" },
              { key: "IsLogoutEnable", value: "true" },
              { key: "commonAuthQueryParams", value: ("acr_values=" + $acr + "&ui_locales=en") }
            ]
          }
        ]
      },
      provisioning: {
        jit: { isEnabled: true, scheme: "PROVISION_SILENTLY", userstore: "PRIMARY", associateLocalUser: true }
      }
    }')"

  http POST "/api/server/v1/identity-providers" "$payload"
  if [[ "$HTTP_CODE" == "201" || "$HTTP_CODE" == "200" ]]; then
    UAEPASS_IDP_ID="$(jq -r '.id // empty' <<<"$HTTP_BODY")"
    log "created idp: ${idp_name} (id=${UAEPASS_IDP_ID})"
  else
    warn "failed to create UAEPass idp (HTTP ${HTTP_CODE})"
    [[ -n "$HTTP_BODY" ]] && warn "uaepass idp response: ${HTTP_BODY:0:400}"
    return 0
  fi
}

# Attach UAEPass as a federated login option on an application (alongside the
# local Basic authenticator) so the client SPA shows a "Sign in with UAEPass"
# button. ``app_id`` is the IS application UUID.
# Add UAEPass to an app's login step with useMappedLocalSubject set.
attach_uaepass_to_app() {
  local app_id="$1"
  [[ -n "$app_id" && -n "${UAEPASS_IDP_ID:-}" ]] || { warn "attach_uaepass: missing app_id/idp_id"; return 0; }

  local seq
  seq="$(jq -n '{
    authenticationSequence: {
      type: "USER_DEFINED",
      steps: [
        {
          id: 1,
          options: [
            { idp: "LOCAL", authenticator: "BasicAuthenticator" },
            { idp: "UAEPass", authenticator: "UAEPassAuthenticator" }
          ]
        }
      ]
    }
  }')"
  http PATCH "/api/server/v1/applications/${app_id}" "$seq"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    log "attached UAEPass login option to app ${app_id}"
  else
    warn "failed to attach UAEPass to app ${app_id} (HTTP ${HTTP_CODE})"
    [[ -n "$HTTP_BODY" ]] && warn "attach response: ${HTTP_BODY:0:300}"
  fi
}

# Reset an app's login to local Basic auth only — removing any UAEPass option a
# prior UAEPass-mode run may have attached. Makes ENABLE_UAEPASS=false take
# effect even on an existing IS volume (without it, the hosted login page keeps
# showing "Sign in with UAEPass"). ``app_id`` is the IS application UUID.
detach_uaepass_from_app() {
  local app_id="$1"
  [[ -n "$app_id" ]] || { warn "detach_uaepass: missing app_id"; return 0; }

  local seq
  seq="$(jq -n '{
    authenticationSequence: {
      type: "DEFAULT",
      steps: [
        {
          id: 1,
          options: [
            { idp: "LOCAL", authenticator: "BasicAuthenticator" }
          ]
        }
      ]
    }
  }')"
  http PATCH "/api/server/v1/applications/${app_id}" "$seq"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    log "reset app ${app_id} to local-only login (UAEPass detached)"
  else
    warn "failed to reset login sequence for app ${app_id} (HTTP ${HTTP_CODE})"
    [[ -n "$HTTP_BODY" ]] && warn "detach response: ${HTTP_BODY:0:300}"
  fi
}

# Apply branding to a SINGLE application's login page (APP scope) so only that
# app's IS-hosted sign-in reflects it — the WSO2 Console and other apps keep the
# default IS branding. ``app_id`` is the IS application UUID. Only used in
# UAEPass mode — default-IAM mode clears branding instead (see delete_app_branding).
# Idempotent: POST if absent, PUT if already configured.
set_app_branding() {
  local app_id="$1"
  [[ -n "$app_id" ]] || { warn "set_app_branding: missing app_id"; return 0; }
  local logo="https://localhost:9443/authenticationendpoint/libs/themes/default/assets/images/identity-providers/uaepass-logo.png"
  local sample="${PROJECT_ROOT}/wso2-is/default/sample-payload.json"
  if [[ ! -f "$sample" ]]; then
    warn "UAEPass branding base payload not found: ${sample}"
    return 0
  fi

  # Start from WSO2's FULL default theme (complete borders/fonts/colours) so the
  # login page renders properly, then overlay only the UAE PASS specifics: scope
  # (APP / this app), logo, name, copyright, primary colour and policy URLs.
  local logo_obj payload
  logo_obj="$(jq -n --arg url "$logo" '{imgURL:$url, altText:"UAE PASS"}')"
  payload="$(jq --arg app "$app_id" --argjson logo "$logo_obj" '
      .type = "APP"
    | .name = $app
    | .locale = "en-US"
    | .preference.organizationDetails.displayName = "UAE PASS"
    | .preference.organizationDetails.siteTitle = "UAE PASS"
    | .preference.organizationDetails.copyrightText = "© {{currentYear}} UAE PASS"
    | .preference.organizationDetails.supportEmail = "support@uaepass.ae"
    | .preference.theme.LIGHT.images.logo = $logo
    | .preference.theme.DARK.images.logo = $logo
    | .preference.theme.LIGHT.colors.primary.main = "#00754A"
    | .preference.theme.DARK.colors.primary.main = "#00754A"
    | .preference.urls.privacyPolicyURL = "https://uaepass.ae/"
    | .preference.urls.termsOfUseURL = "https://uaepass.ae/"
    | .preference.urls.cookiePolicyURL = "https://uaepass.ae/"
  ' "$sample")"

  # Wipe any existing preference first, then create fresh — a PUT can MERGE with
  # the previous mode's fields (e.g. leftover generic copyright), so delete-then-
  # POST guarantees the stored branding is EXACTLY this UAEPass payload.
  http DELETE "/api/server/v1/branding-preference?type=APP&name=${app_id}&locale=en-US"
  http POST "/api/server/v1/branding-preference" "$payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "applied UAE PASS app branding to ${app_id}"
  else
    warn "failed to apply app branding to ${app_id} (HTTP ${HTTP_CODE}): ${HTTP_BODY:0:200}"
  fi
}

# Remove any APP-scope branding preference for an app so its login reverts to
# the stock default WSO2 IS look. Used in default-IAM mode (ENABLE_UAEPASS=false)
# to clear branding a prior UAEPass-mode run may have applied. Idempotent: a 404
# (nothing to delete) is treated as success. ``app_id`` is the IS application UUID.
delete_app_branding() {
  local app_id="$1"
  [[ -n "$app_id" ]] || { warn "delete_app_branding: missing app_id"; return 0; }
  http DELETE "/api/server/v1/branding-preference?type=APP&name=${app_id}&locale=en-US"
  if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" || "$HTTP_CODE" == "404" ]]; then
    log "cleared app branding for ${app_id} (default WSO2 IS look)"
  else
    warn "failed to clear app branding for ${app_id} (HTTP ${HTTP_CODE}): ${HTTP_BODY:0:200}"
  fi
}

# Default-IAM (ENABLE_UAEPASS=false) branding. Uses WSO2's FULL default theme
# (wso2-is/default/sample-payload.json — complete borders/fonts/colours so the
# login page renders exactly like the stock WSO2 default) and overrides only:
#   - scope: APP / this app (the sample is ORG-scoped; we never touch the org)
#   - the page logo (smart-employee-logo.jpeg, served by URL)
#   - the footer copyright (``{{currentYear}}`` is a WSO2 token expanded at render)
# Idempotent: delete-then-POST so nothing from a prior mode lingers.
set_generic_branding() {
  local app_id="$1"
  [[ -n "$app_id" ]] || { warn "set_generic_branding: missing app_id"; return 0; }
  local logo="https://localhost:9443/authenticationendpoint/libs/themes/default/assets/images/smart-employee-logo.jpeg"
  local sample="${PROJECT_ROOT}/wso2-is/default/sample-payload.json"
  if [[ ! -f "$sample" ]]; then
    warn "generic branding base payload not found: ${sample}"
    return 0
  fi

  local logo_obj payload
  logo_obj="$(jq -n --arg url "$logo" '{imgURL:$url, altText:"Smart Employee"}')"
  payload="$(jq --arg app "$app_id" --argjson logo "$logo_obj" '
      .type = "APP"
    | .name = $app
    | .locale = "en-US"
    | .preference.organizationDetails.copyrightText = "© {{currentYear}} Smart Employee"
    | .preference.theme.LIGHT.images.logo = $logo
    | .preference.theme.DARK.images.logo = $logo
  ' "$sample")"

  http DELETE "/api/server/v1/branding-preference?type=APP&name=${app_id}&locale=en-US"
  http POST "/api/server/v1/branding-preference" "$payload"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" ]]; then
    log "applied default-theme branding (logo + copyright) to ${app_id}"
  else
    warn "failed to apply generic branding to ${app_id} (HTTP ${HTTP_CODE}): ${HTTP_BODY:0:200}"
  fi
}

# Map the UAEPass ``email`` claim to local emailaddress and use it as the user
# identifier. Without this the federated subject is the UAEPass UUID, so the
# CIBA consent (authenticated user) won't match the agent's login_hint (the
# user's email) -> 401 "authenticated user is not the same as resolved user".
# Using email as the user-id makes JIT resolve to the pre-created local account.
# Configure the UAEPass IdP claim mapping (email → local user id).
set_uaepass_claims() {
  [[ -n "${UAEPASS_IDP_ID:-}" ]] || return 0
  local email_id
  email_id="$(printf '%s' "http://wso2.org/claims/emailaddress" | base64 | tr '+/' '-_' | tr -d '=\n')"
  local body
  body="$(jq -n --arg eid "$email_id" '{
    userIdClaim: { uri: "email" },
    mappings: [
      { idpClaim: "email", localClaim: { uri: "http://wso2.org/claims/emailaddress", id: $eid } }
    ],
    provisioningClaims: []
  }')"
  http PUT "/api/server/v1/identity-providers/${UAEPASS_IDP_ID}/claims" "$body"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    log "set UAEPass claim mapping (email -> emailaddress, user-id=email)"
  else
    warn "failed to set UAEPass claims (HTTP ${HTTP_CODE}): ${HTTP_BODY:0:200}"
  fi
}

# Ensure the IdP logo (already deployed to the Console logo dir by the image)
# is referenced on the IdP record.
# Set the UAEPass IdP logo/image used on the login page.
set_uaepass_logo() {
  [[ -n "${UAEPASS_IDP_ID:-}" ]] || return 0
  local body
  body="$(jq -n '[{operation:"REPLACE",path:"/image",value:"assets/images/logos/uaepass-logo.png"}]')"
  http PATCH "/api/server/v1/identity-providers/${UAEPASS_IDP_ID}" "$body"
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "204" ]]; then
    log "set UAEPass idp logo"
  else
    warn "failed to set UAEPass idp logo (HTTP ${HTTP_CODE})"
  fi
}

# Orchestrate the full provisioning sequence (waits for the admin API first).
main() {
  wait_for_admin || return 0

  # Resolve the login-mode flag from master.env (the single source of truth),
  # not the shell/compose env. An explicitly-exported ENABLE_UAEPASS still wins
  # (e.g. a manual run); otherwise read config/master.env (mounted under
  # /workspace) and default to false.
  if [[ -z "${ENABLE_UAEPASS:-}" ]]; then
    local _master="/workspace/config/master.env"
    if [[ -f "$_master" ]]; then
      ENABLE_UAEPASS="$(grep -E '^ENABLE_UAEPASS=' "$_master" | tail -1 | cut -d= -f2- | tr -d '[:space:]')"
    fi
    ENABLE_UAEPASS="${ENABLE_UAEPASS:-false}"
    export ENABLE_UAEPASS
  fi
  log "login mode: ENABLE_UAEPASS=${ENABLE_UAEPASS}"

  ensure_env_file "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE"
  ensure_env_file "$HR_ENV_FILE" "$HR_ENV_EXAMPLE"
  ensure_env_file "$IT_ENV_FILE" "$IT_ENV_EXAMPLE"

  local ORCH_CLIENT_ID ORCH_CLIENT_SECRET ORCH_REDIRECT ORCH_POST_LOGOUT
  local ORCH_AGENT_CLIENT_ID ORCH_AGENT_CLIENT_SECRET ORCH_AGENT_SECRET
  local HR_AGENT_SECRET HR_AGENT_CLIENT_ID HR_AGENT_CLIENT_SECRET HR_AGENT_REDIRECT
  local IT_AGENT_SECRET IT_AGENT_CLIENT_ID IT_AGENT_CLIENT_SECRET IT_AGENT_REDIRECT

  ORCH_CLIENT_ID="$(read_env_value ORCHESTRATOR_MCP_CLIENT_ID "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"
  ORCH_CLIENT_SECRET="$(read_env_value ORCHESTRATOR_MCP_CLIENT_SECRET "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"
  ORCH_REDIRECT="$(read_env_value ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"
  ORCH_POST_LOGOUT="$(read_env_value ORCHESTRATOR_POST_LOGOUT_REDIRECT_URI "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"

  ORCH_AGENT_CLIENT_ID="$(read_env_value ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"
  ORCH_AGENT_CLIENT_SECRET="$(read_env_value ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"
  ORCH_AGENT_SECRET="$(read_env_value ORCHESTRATOR_AGENT_SECRET "$ORCH_ENV_FILE" "$ORCH_ENV_EXAMPLE" || true)"

  HR_AGENT_SECRET="$(read_env_value HR_AGENT_SECRET "$HR_ENV_FILE" "$HR_ENV_EXAMPLE" || true)"
  HR_AGENT_CLIENT_ID="$(read_env_value HR_AGENT_OAUTH_CLIENT_ID "$HR_ENV_FILE" "$HR_ENV_EXAMPLE" || true)"
  HR_AGENT_CLIENT_SECRET="$(read_env_value HR_AGENT_OAUTH_CLIENT_SECRET "$HR_ENV_FILE" "$HR_ENV_EXAMPLE" || true)"
  HR_AGENT_REDIRECT="$(read_env_value HR_AGENT_REDIRECT_URI "$HR_ENV_FILE" "$HR_ENV_EXAMPLE" || true)"

  IT_AGENT_SECRET="$(read_env_value IT_AGENT_SECRET "$IT_ENV_FILE" "$IT_ENV_EXAMPLE" || true)"
  IT_AGENT_CLIENT_ID="$(read_env_value IT_AGENT_OAUTH_CLIENT_ID "$IT_ENV_FILE" "$IT_ENV_EXAMPLE" || true)"
  IT_AGENT_CLIENT_SECRET="$(read_env_value IT_AGENT_OAUTH_CLIENT_SECRET "$IT_ENV_FILE" "$IT_ENV_EXAMPLE" || true)"
  IT_AGENT_REDIRECT="$(read_env_value IT_AGENT_REDIRECT_URI "$IT_ENV_FILE" "$IT_ENV_EXAMPLE" || true)"

  ORCH_REDIRECT="${ORCH_REDIRECT:-http://localhost:8090/agent-callback}"
  ORCH_POST_LOGOUT="${ORCH_POST_LOGOUT:-http://localhost:8090/}"
  HR_AGENT_REDIRECT="${HR_AGENT_REDIRECT:-http://localhost:9999/agent-callback}"
  IT_AGENT_REDIRECT="${IT_AGENT_REDIRECT:-http://localhost:9999/agent-callback}"

  if [[ -z "$ORCH_CLIENT_ID" ]]; then
    ORCH_CLIENT_ID="$(generate_client_id)"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_MCP_CLIENT_ID" "$ORCH_CLIENT_ID"
    log "generated ORCHESTRATOR_MCP_CLIENT_ID"
  fi
  if [[ -z "$ORCH_CLIENT_SECRET" ]]; then
    ORCH_CLIENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_MCP_CLIENT_SECRET" "$ORCH_CLIENT_SECRET"
    log "generated ORCHESTRATOR_MCP_CLIENT_SECRET"
  fi

  if [[ -z "$ORCH_AGENT_CLIENT_ID" ]]; then
    ORCH_AGENT_CLIENT_ID="$(generate_client_id)"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID" "$ORCH_AGENT_CLIENT_ID"
    log "generated ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID"
  fi
  if [[ -z "$ORCH_AGENT_CLIENT_SECRET" ]]; then
    ORCH_AGENT_CLIENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET" "$ORCH_AGENT_CLIENT_SECRET"
    log "generated ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET"
  fi
  if [[ -z "$ORCH_AGENT_SECRET" ]]; then
    ORCH_AGENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_AGENT_SECRET" "$ORCH_AGENT_SECRET"
    log "generated ORCHESTRATOR_AGENT_SECRET"
  fi

  if [[ -z "$HR_AGENT_CLIENT_ID" ]]; then
    HR_AGENT_CLIENT_ID="$(generate_client_id)"
    upsert_env_value "$HR_ENV_FILE" "HR_AGENT_OAUTH_CLIENT_ID" "$HR_AGENT_CLIENT_ID"
    log "generated HR_AGENT_OAUTH_CLIENT_ID"
  fi
  if [[ -z "$HR_AGENT_CLIENT_SECRET" ]]; then
    HR_AGENT_CLIENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$HR_ENV_FILE" "HR_AGENT_OAUTH_CLIENT_SECRET" "$HR_AGENT_CLIENT_SECRET"
    log "generated HR_AGENT_OAUTH_CLIENT_SECRET"
  fi
  if [[ -z "$HR_AGENT_SECRET" ]]; then
    HR_AGENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$HR_ENV_FILE" "HR_AGENT_SECRET" "$HR_AGENT_SECRET"
    log "generated HR_AGENT_SECRET"
  fi

  if [[ -z "$IT_AGENT_CLIENT_ID" ]]; then
    IT_AGENT_CLIENT_ID="$(generate_client_id)"
    upsert_env_value "$IT_ENV_FILE" "IT_AGENT_OAUTH_CLIENT_ID" "$IT_AGENT_CLIENT_ID"
    log "generated IT_AGENT_OAUTH_CLIENT_ID"
  fi
  if [[ -z "$IT_AGENT_CLIENT_SECRET" ]]; then
    IT_AGENT_CLIENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$IT_ENV_FILE" "IT_AGENT_OAUTH_CLIENT_SECRET" "$IT_AGENT_CLIENT_SECRET"
    log "generated IT_AGENT_OAUTH_CLIENT_SECRET"
  fi
  if [[ -z "$IT_AGENT_SECRET" ]]; then
    IT_AGENT_SECRET="$(generate_client_secret)"
    upsert_env_value "$IT_ENV_FILE" "IT_AGENT_SECRET" "$IT_AGENT_SECRET"
    log "generated IT_AGENT_SECRET"
  fi


  local hr_api_id it_api_id
  hr_api_id="$(ensure_api_resource "HR API" "urn:hr:api" "hr_basic_rest" "hr_self_rest" "hr_read_rest" "hr_approve_rest" "hr_assets_write_rest")"
  it_api_id="$(ensure_api_resource "IT API" "urn:it:api" "it_assets_read_rest" "it_assets_self_rest" "it_assets_write_rest")"

  local employee_id hradmin_id employee_role_id hr_admin_role_id
  employee_id="$(ensure_user "employee@example.com" "${DEMO_EMPLOYEE_PASSWORD:-NewsMax@1234}" "Demo" "Employee")"
  hradmin_id="$(ensure_user "hradmin@example.com" "${DEMO_HRADMIN_PASSWORD:-NewsMax@1234}" "Demo" "HR Admin")"

  employee_role_id="$(ensure_role "employee" "hr_basic_rest" "hr_self_rest" "it_assets_self_rest")"
  hr_admin_role_id="$(ensure_role "HR Admin" "hr_basic_rest" "hr_self_rest" "it_assets_read_rest" "it_assets_self_rest" "hr_read_rest" "hr_approve_rest" "it_assets_write_rest" "hr_assets_write_rest")"

  ensure_user_roles "$employee_id" "$employee_role_id"
  ensure_user_roles "$hradmin_id" "$employee_role_id" "$hr_admin_role_id"

  # UAEPass JIT targets: pre-create local accounts so UAEPass-federated logins
  # associate (by email/username) to an existing account that already carries
  # the right roles -> scopes. sivanoly@wso2.com -> HR Admin, ramith@wso2.com -> employee.
  local uaepass_hradmin_id uaepass_employee_id
  uaepass_hradmin_id="$(ensure_user "sivanoly@wso2.com" "${DEMO_HRADMIN_PASSWORD:-NewsMax@1234}" "Sivanoly" "HR Admin")"
  uaepass_employee_id="$(ensure_user "ramith@wso2.com" "${DEMO_EMPLOYEE_PASSWORD:-NewsMax@1234}" "Ramith" "Employee")"
  ensure_user_roles "$uaepass_hradmin_id" "$employee_role_id" "$hr_admin_role_id"
  ensure_user_roles "$uaepass_employee_id" "$employee_role_id"

  local orchestrator_agent_id hr_agent_id it_agent_id
  orchestrator_agent_id="$(ensure_agent "orchestrator-agent" "$IS_AGENT_OWNER" "$ORCH_AGENT_SECRET")"
  hr_agent_id="$(ensure_agent "hr-agent" "$IS_AGENT_OWNER" "$HR_AGENT_SECRET")"
  it_agent_id="$(ensure_agent "it-agent" "$IS_AGENT_OWNER" "$IT_AGENT_SECRET")"

  upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_AGENT_ID" "$orchestrator_agent_id"
  upsert_env_value "$HR_ENV_FILE" "HR_AGENT_ID" "$hr_agent_id"
  upsert_env_value "$IT_ENV_FILE" "IT_AGENT_ID" "$it_agent_id"

  reconcile_agent_duplicates "orchestrator-agent"
  reconcile_agent_duplicates "hr-agent"
  reconcile_agent_duplicates "it-agent"

  ensure_service_provider_app \
    "orchestrator-mcp-client" \
    "$ORCH_CLIENT_ID" \
    "$ORCH_CLIENT_SECRET" \
    "$ORCH_REDIRECT" \
    "$ORCH_POST_LOGOUT" \
    "authorization_code" "refresh_token"

  ensure_service_provider_app \
    "orchestrator-agent-oauth" \
    "$ORCH_AGENT_CLIENT_ID" \
    "$ORCH_AGENT_CLIENT_SECRET" \
    "$ORCH_REDIRECT" \
    "" \
    "authorization_code" "refresh_token" "urn:openid:params:grant-type:ciba"

  ensure_service_provider_app \
    "hr-agent-oauth" \
    "$HR_AGENT_CLIENT_ID" \
    "$HR_AGENT_CLIENT_SECRET" \
    "$HR_AGENT_REDIRECT" \
    "" \
    "authorization_code" "refresh_token" "urn:openid:params:grant-type:ciba"

  ensure_service_provider_app \
    "it-agent-oauth" \
    "$IT_AGENT_CLIENT_ID" \
    "$IT_AGENT_CLIENT_SECRET" \
    "$IT_AGENT_REDIRECT" \
    "" \
    "authorization_code" "refresh_token" "urn:openid:params:grant-type:ciba"

  # NOTE: app-API authorization (and app-id resolution) happens once, later in a
  # single authoritative pass below — no need to look up / authorize here.

  # NOTE: the standalone client-spa app (legacy :3001 SPA) was removed — the
  # browser SPA is served by the orchestrator and authenticates via the
  # orchestrator-mcp-client BFF, so no separate public SPA client is registered.

  local live_orch_client_secret live_orch_agent_client_secret live_hr_agent_client_secret live_it_agent_client_secret
  live_orch_client_secret="$(dcr_client_secret_by_client_id "$ORCH_CLIENT_ID")"
  live_orch_agent_client_secret="$(dcr_client_secret_by_client_id "$ORCH_AGENT_CLIENT_ID")"
  live_hr_agent_client_secret="$(dcr_client_secret_by_client_id "$HR_AGENT_CLIENT_ID")"
  live_it_agent_client_secret="$(dcr_client_secret_by_client_id "$IT_AGENT_CLIENT_ID")"

  if [[ -n "$live_orch_client_secret" && "$live_orch_client_secret" != "$ORCH_CLIENT_SECRET" ]]; then
    ORCH_CLIENT_SECRET="$live_orch_client_secret"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_MCP_CLIENT_SECRET" "$ORCH_CLIENT_SECRET"
    log "synced ORCHESTRATOR_MCP_CLIENT_SECRET from WSO2 DCR"
  fi
  if [[ -n "$live_orch_agent_client_secret" && "$live_orch_agent_client_secret" != "$ORCH_AGENT_CLIENT_SECRET" ]]; then
    ORCH_AGENT_CLIENT_SECRET="$live_orch_agent_client_secret"
    upsert_env_value "$ORCH_ENV_FILE" "ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET" "$ORCH_AGENT_CLIENT_SECRET"
    log "synced ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET from WSO2 DCR"
  fi
  if [[ -n "$live_hr_agent_client_secret" && "$live_hr_agent_client_secret" != "$HR_AGENT_CLIENT_SECRET" ]]; then
    HR_AGENT_CLIENT_SECRET="$live_hr_agent_client_secret"
    upsert_env_value "$HR_ENV_FILE" "HR_AGENT_OAUTH_CLIENT_SECRET" "$HR_AGENT_CLIENT_SECRET"
    log "synced HR_AGENT_OAUTH_CLIENT_SECRET from WSO2 DCR"
  fi
  if [[ -n "$live_it_agent_client_secret" && "$live_it_agent_client_secret" != "$IT_AGENT_CLIENT_SECRET" ]]; then
    IT_AGENT_CLIENT_SECRET="$live_it_agent_client_secret"
    upsert_env_value "$IT_ENV_FILE" "IT_AGENT_OAUTH_CLIENT_SECRET" "$IT_AGENT_CLIENT_SECRET"
    log "synced IT_AGENT_OAUTH_CLIENT_SECRET from WSO2 DCR"
  fi

  local orchestrator_app_id orchestrator_agent_app_id hr_agent_app_id it_agent_app_id
  orchestrator_app_id="$(find_app_by_client_id "$ORCH_CLIENT_ID")"
  [[ -n "$orchestrator_app_id" ]] || orchestrator_app_id="$(find_app_by_name "orchestrator-mcp-client")"

  orchestrator_agent_app_id="$(find_app_by_client_id "$ORCH_AGENT_CLIENT_ID")"
  [[ -n "$orchestrator_agent_app_id" ]] || orchestrator_agent_app_id="$(find_app_by_name "orchestrator-agent-oauth")"

  hr_agent_app_id="$(find_app_by_client_id "$HR_AGENT_CLIENT_ID")"
  [[ -n "$hr_agent_app_id" ]] || hr_agent_app_id="$(find_app_by_name "hr-agent-oauth")"

  it_agent_app_id="$(find_app_by_client_id "$IT_AGENT_CLIENT_ID")"
  [[ -n "$it_agent_app_id" ]] || it_agent_app_id="$(find_app_by_name "it-agent-oauth")"


  # App-Native /oauth2/authorize flow requires API-based authentication enabled.
  ensure_app_native_auth_enabled "$orchestrator_agent_app_id" "orchestrator-agent-oauth"
  ensure_app_native_auth_enabled "$hr_agent_app_id" "hr-agent-oauth"
  ensure_app_native_auth_enabled "$it_agent_app_id" "it-agent-oauth"

  # Organization-audience roles (HR Admin, employee) must be used for scope resolution
  # at both login time (mcp-client token-A) and CIBA time (agent token-B).
  # Without ORGANIZATION audience, IS strips all business API scopes from every token.
  ensure_org_role_audience "$orchestrator_app_id" "orchestrator-mcp-client"
  ensure_org_role_audience "$orchestrator_agent_app_id" "orchestrator-agent-oauth"
  ensure_org_role_audience "$hr_agent_app_id" "hr-agent-oauth"
  ensure_org_role_audience "$it_agent_app_id" "it-agent-oauth"

  # Agent apps must mint JWT actor tokens and include CIBA grant support.
  ensure_agent_oidc_settings "$orchestrator_agent_app_id" "orchestrator-agent-oauth" "$ORCH_REDIRECT"
  ensure_agent_oidc_settings "$hr_agent_app_id" "hr-agent-oauth" "$HR_AGENT_REDIRECT"
  ensure_agent_oidc_settings "$it_agent_app_id" "it-agent-oauth" "$IT_AGENT_REDIRECT" 180

  # Pattern C validates token-A as JWT; keep orchestrator client token format aligned.
  ensure_oidc_access_token_jwt "$orchestrator_app_id" "orchestrator-mcp-client" "$ORCH_REDIRECT"
  # RP-initiated logout: callbackURL must also match the post-logout redirect URI.
  ensure_logout_callback_regex "$orchestrator_app_id" "orchestrator-mcp-client" "$ORCH_REDIRECT" "$ORCH_POST_LOGOUT"
  # Use emailaddress as OIDC subject so every token's sub == email (matches store keys).
  # token-A (orchestrator-mcp-client) AND token-C (the CIBA agent apps) must all
  # agree, or leave/cubicle/asset records key by UUID on the agent path and by
  # email on the REST path — the report joins then fail (employee shows as "?").
  ensure_email_subject "$orchestrator_app_id" "orchestrator-mcp-client"
  # Auto-grant role-permitted scopes (needed for federated/UAEPass logins).
  ensure_skip_login_consent "$orchestrator_app_id" "orchestrator-mcp-client"
  ensure_email_subject "$orchestrator_agent_app_id" "orchestrator-agent-oauth"
  ensure_email_subject "$hr_agent_app_id" "hr-agent-oauth"
  ensure_email_subject "$it_agent_app_id" "it-agent-oauth"

  # orchestrator-mcp-client: full HR+IT scopes for orchestration flows.
  # orchestrator-mcp-client: only read scopes for reports/sidebar. Write scopes
  # are obtained via agent CIBA (token-B), not the login token-A.
  ensure_authorized_api "$orchestrator_app_id" "$hr_api_id" "hr_basic_rest" "hr_self_rest" "hr_read_rest"
  ensure_authorized_api "$orchestrator_app_id" "$it_api_id" "it_assets_self_rest" "it_assets_read_rest"

  # orchestrator-agent-oauth: same runtime API access envelope as orchestrator orchestration.
  ensure_authorized_api "$orchestrator_agent_app_id" "$hr_api_id" "hr_basic_rest" "hr_self_rest" "hr_read_rest" "hr_approve_rest" "hr_assets_write_rest"
  ensure_authorized_api "$orchestrator_agent_app_id" "$it_api_id" "it_assets_read_rest" "it_assets_self_rest" "it_assets_write_rest"

  # specialist agents: domain-specific scopes.
  ensure_authorized_api "$hr_agent_app_id" "$hr_api_id" "hr_basic_rest" "hr_self_rest" "hr_read_rest" "hr_approve_rest" "hr_assets_write_rest"
  ensure_authorized_api "$it_agent_app_id" "$it_api_id" "it_assets_read_rest" "it_assets_self_rest" "it_assets_write_rest"


  # UAEPass federated login + branding — opt-out via ENABLE_UAEPASS=false to run
  # with a plain "default IAM" experience (local Basic auth only, stock IS
  # branding, no UAEPass IdP). Default is true to preserve the demo's federated
  # login story. The connector JAR is always present in the image; this flag
  # only controls whether it is wired up at bootstrap time.
  if [[ "${ENABLE_UAEPASS:-false}" == "true" ]]; then
    log "UAEPass mode: provisioning federated IdP + UAE PASS branding"
    # UAEPass federated login: create the staging IdP (JIT on), set its logo, and
    # offer it as a login option on the client SPA alongside local Basic auth.
    ensure_uaepass_idp
    set_uaepass_claims
    set_uaepass_logo
    # UAE PASS branding on the client SPA's login app only (not org-wide / Console).
    set_app_branding "$orchestrator_app_id"
    # The browser SPA (served by the orchestrator at :8090) logs in via the
    # orchestrator-mcp-client app's /authorize, so UAEPass must be offered there.
    attach_uaepass_to_app "$orchestrator_app_id"
    # The agent OAuth apps drive the CIBA consent window. A UAEPass-federated user
    # has no local password, so their consent flow must also offer UAEPass (and
    # this lets the IS SSO session from the SPA login be reused -> consent shown
    # directly instead of a login prompt).
    attach_uaepass_to_app "$hr_agent_app_id"
    attach_uaepass_to_app "$it_agent_app_id"
  else
    log "default IAM mode (ENABLE_UAEPASS=false): detaching UAEPass; generic branding (logo + copyright)"
    # Reset every app's login to local Basic auth only — this removes any
    # "Sign in with UAEPass" option left attached by a prior UAEPass-mode run,
    # so switching to default IAM works even on an existing IS volume.
    detach_uaepass_from_app "$orchestrator_app_id"
    detach_uaepass_from_app "$hr_agent_app_id"
    detach_uaepass_from_app "$it_agent_app_id"
    # Only the page logo + copyright — nothing else.
    set_generic_branding "$orchestrator_app_id"
  fi

  log "bootstrap completed"
}

main "$@"
