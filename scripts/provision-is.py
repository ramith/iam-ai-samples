#!/usr/bin/env python3
"""
Automated WSO2 IS 7.3.0 provisioner for the fully-local demo (Stage 2).

Configures a FRESH WSO2 IS instance to suit the CIBA-based OBO multi-agent demo,
entirely via the IS REST/SCIM APIs, then writes the generated client-ids/secrets
and agent ids/secrets into the five service .env files.

Reverse-engineered from the app code + docs + check-is-config.py, and
empirically validated against IS 7.3.0 GA. See
docs/architecture/fully-local-is-provisioning-spec.md.

Idempotent: re-running reuses existing API resources / users / roles / apps by
name. Agents are one-shot-secret, so a re-run rotates the agent secret. Intended
for a fresh instance though (destroy the mysql volume first for a clean slate).

Usage:
    python3 scripts/provision-is.py                 # provision + write .env files
    # Bake the WSO2 Agent Manager AI Gateway creds (OpenAI-compatible) while provisioning:
    OPENAI_BASE_URL=https://<wso2-agent-manager-gateway>/<route> \
    OPENAI_API_KEY=<gateway-key> \
    IS_ADMIN_USER=admin IS_ADMIN_PASS=admin python3 scripts/provision-is.py

Talks to IS at IS_BASE_URL (host-facing, default https://localhost:9443) but
writes WSO2_IS_BASE_URL=https://wso2is:9443 (container-facing) into the .env files.
"""
from __future__ import annotations
import base64, json, os, secrets, ssl, sys, urllib.error, urllib.parse, urllib.request
from pathlib import Path

# ── Connection ───────────────────────────────────────────────────────────────
IS_BASE   = os.environ.get("IS_BASE_URL", "https://localhost:9443").rstrip("/")
ADMIN_USER = os.environ.get("IS_ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("IS_ADMIN_PASS", "admin")
ADMIN_AUTH = "Basic " + base64.b64encode(f"{ADMIN_USER}:{ADMIN_PASS}".encode()).decode()
_CTX = ssl.create_default_context(); _CTX.check_hostname = False; _CTX.verify_mode = ssl.CERT_NONE
ROOT = Path(__file__).resolve().parent.parent

# ── In-container values written into the .env files ──────────────────────────
IS_INTERNAL_BASE = "https://wso2is:9443"          # docker network alias (D5)
EMAIL_CLAIM      = "http://wso2.org/claims/emailaddress"
MCP_REDIRECT     = "http://localhost:8090/agent-callback"
MCP_AUTH_CB      = "http://localhost:8090/auth/callback"
POST_LOGOUT      = "http://localhost:8090/"
AGENT_REDIRECT   = "http://localhost:9999/agent-callback"
BCL_URL          = "http://orchestrator:8080/backchannel-logout"   # in-network, no tunnel
CIBA_EXPIRY      = 300

# ── Desired state ────────────────────────────────────────────────────────────
HR_SCOPES = [
    ("hr_basic_rest",        "View company HR info"),
    ("hr_self_rest",         "View own leave info"),
    ("hr_read_rest",         "View all leave requests and cubicles"),
    ("hr_approve_rest",      "Approve or reject leave"),
    ("hr_assets_write_rest", "Assign cubicles and seats"),
]
IT_SCOPES = [
    ("it_assets_read_rest",  "View IT asset info"),
    ("it_assets_self_rest",  "View own IT assets"),
    ("it_assets_write_rest", "Issue IT assets to employees"),
]
HR_API = {"name": "HR API", "identifier": "urn:hr:api", "scopes": HR_SCOPES}
IT_API = {"name": "IT API", "identifier": "urn:it:api", "scopes": IT_SCOPES}
ALL_HR = [s for s, _ in HR_SCOPES]
ALL_IT = [s for s, _ in IT_SCOPES]

ROLE_SCOPES = {
    "employee": ["hr_basic_rest", "hr_self_rest", "it_assets_read_rest", "it_assets_self_rest"],
    "HR Admin": ALL_HR + ALL_IT,            # superset
}
USERS = [
    {"username": "employee@example.com", "password": "NewsMax@1234",
     "given": "Demo", "family": "Employee", "role": "employee"},
    {"username": "hradmin@example.com",  "password": "NewsMax@1234",
     "given": "HR",   "family": "Admin",    "role": "HR Admin"},
]

# ── HTTP ─────────────────────────────────────────────────────────────────────
def _req(method, path, body=None, accept="application/json", auth=ADMIN_AUTH,
         form=None, ctype="application/json"):
    url = path if path.startswith("http") else IS_BASE + path
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode(); ctype = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
    r = urllib.request.Request(url, data=data, method=method)
    if auth:   r.add_header("Authorization", auth)
    r.add_header("Accept", accept)
    if data is not None: r.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(r, context=_CTX, timeout=60) as resp:
            return resp.status, dict(resp.headers), resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()
    except Exception as e:                                       # noqa: BLE001
        return 0, {}, f"<network-error: {e}>"

def _j(text):
    try: return json.loads(text)
    except Exception: return None

def die(msg, status=None, body=None):
    print(f"\n✗ FATAL: {msg}")
    if status is not None: print(f"   HTTP {status}: {str(body)[:600]}")
    sys.exit(1)

OK, WARN, INFO = "✓", "!", "→"
def log(sym, msg): print(f"  {sym} {msg}")

# ── Generic discovery helpers ────────────────────────────────────────────────
def mgmt_get(path):           return _req("GET", path)
def scim_get(path):           return _req("GET", path, accept="application/scim+json")

def app_id_by_name(name):
    st, _, bd = mgmt_get(f"/api/server/v1/applications?filter=" + urllib.parse.quote(f"name eq {name}"))
    j = _j(bd) or {}
    for a in j.get("applications", []):
        if a.get("name") == name:
            return a["id"]
    return None

def app_oidc(app_id):
    st, _, bd = mgmt_get(f"/api/server/v1/applications/{app_id}/inbound-protocols/oidc")
    if st != 200: die(f"reading OIDC config of app {app_id}", st, bd)
    return _j(bd)

# ── API resources ────────────────────────────────────────────────────────────
def ensure_api_resource(api):
    st, _, bd = mgmt_get("/api/server/v1/api-resources?limit=200")
    for r in (_j(bd) or {}).get("apiResources", []):
        if r.get("identifier") == api["identifier"] or r.get("name") == api["name"]:
            log(OK, f"API resource exists: {api['name']} ({api['identifier']})")
            return r["id"]
    body = {
        "name": api["name"], "identifier": api["identifier"],
        "requiresAuthorization": True,
        "scopes": [{"name": s, "displayName": d} for s, d in api["scopes"]],
    }
    st, _, bd = _req("POST", "/api/server/v1/api-resources", body)
    if st not in (200, 201): die(f"creating API resource {api['name']}", st, bd)
    log(OK, f"created API resource: {api['name']} ({len(api['scopes'])} scopes)")
    return _j(bd)["id"]

# ── Organisation id (for Organization-audience roles) ────────────────────────
def _org_id_from(resources):
    for r in resources:
        aud = r.get("audience") or {}
        if (aud.get("type") or "").lower() == "organization" and aud.get("value"):
            return aud["value"]
    return None

def org_id():
    # Prefer the built-in Organization-audience "everyone" role (deterministic);
    # fall back to scanning all roles. audience is nested: {type, value, display}.
    st, _, bd = scim_get("/scim2/v2/Roles?filter=" + urllib.parse.quote("displayName eq everyone"))
    oid = _org_id_from((_j(bd) or {}).get("Resources", []))
    if oid:
        return oid
    st, _, bd = scim_get("/scim2/v2/Roles?count=200")
    return _org_id_from((_j(bd) or {}).get("Resources", []))

# ── Roles (SCIM2 v2, Organization audience, permissions = scope names) ───────
def ensure_role(name, scopes, oid, user_ids):
    st, _, bd = scim_get("/scim2/v2/Roles?filter=" + urllib.parse.quote(f"displayName eq {name}"))
    existing = (_j(bd) or {}).get("Resources", [])
    perms = [{"value": s} for s in scopes]
    if existing:
        rid = existing[0]["id"]
        log(OK, f"role exists: {name} (id {rid[:8]}…) — leaving as-is")
        return rid
    body = {
        "schemas": ["urn:ietf:params:scim:schemas:extension:2.0:Role"],
        "displayName": name,
        "audience": {"value": oid, "display": "Organization"},
        "permissions": perms,
        "users": [{"value": uid} for uid in user_ids],
    }
    st, _, bd = _req("POST", "/scim2/v2/Roles", body,
                     accept="application/scim+json", ctype="application/scim+json")
    if st not in (200, 201): die(f"creating role {name}", st, bd)
    log(OK, f"created role: {name} ({len(scopes)} scopes, {len(user_ids)} member(s))")
    return _j(bd)["id"]

# ── Users (SCIM2, username == email) ─────────────────────────────────────────
def ensure_user(u):
    st, _, bd = scim_get("/scim2/Users?filter=" + urllib.parse.quote(f"userName eq {u['username']}"))
    res = (_j(bd) or {}).get("Resources", [])
    if res:
        log(OK, f"user exists: {u['username']} (id {res[0]['id'][:8]}…)")
        return res[0]["id"]
    body = {
        "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName": u["username"], "password": u["password"],
        "name": {"givenName": u["given"], "familyName": u["family"]},
        "emails": [{"primary": True, "value": u["username"]}],
    }
    st, _, bd = _req("POST", "/scim2/Users", body,
                     accept="application/scim+json", ctype="application/scim+json")
    if st not in (200, 201): die(f"creating user {u['username']}", st, bd)
    log(OK, f"created user: {u['username']}")
    return _j(bd)["id"]

# ── OIDC applications ────────────────────────────────────────────────────────
def _callbacks(urls):
    """IS wants multiple callbacks as a single regexp=(...) alternation."""
    if len(urls) == 1:
        return [urls[0]]
    import re
    return ["regexp=(" + "|".join(re.escape(u) for u in urls) + ")"]

def create_app(name, callbacks, grants, *, app_native=False, ciba=False):
    """Create (or reuse) a confidential OIDC app. Returns (app_id, client_id, client_secret)."""
    existing = app_id_by_name(name)
    if existing:
        o = app_oidc(existing)
        cid, csec = o.get("clientId"), o.get("clientSecret")
        if not cid or not csec:
            die(f"app '{name}' already exists but IS did not return its clientId/clientSecret "
                f"(often redacted on read) — a re-run cannot recover the real secret. "
                f"Destroy the MySQL volume (docker compose down -v) and re-provision from scratch.")
        log(OK, f"app exists: {name} (client_id {cid})")
        return existing, cid, csec

    oidc = {
        "grantTypes": grants,
        "callbackURLs": _callbacks(callbacks),
        "publicClient": False,
        "pkce": {"mandatory": True, "supportPlainTransformAlgorithm": False},  # both keys (APP-65006 NPE otherwise)
        "accessToken": {"type": "JWT", "userAccessTokenExpiryInSeconds": 3600,
                        "applicationAccessTokenExpiryInSeconds": 3600, "bindingType": "None"},
        "clientAuthentication": {"tokenEndpointAuthMethod": "client_secret_basic"},
    }
    if ciba:
        oidc["cibaAuthenticationRequest"] = {
            "authReqExpiryTime": CIBA_EXPIRY, "notificationChannels": ["external"],
            "skipUserValidation": False, "allowFederatedUsers": False,
        }
    body = {"name": name, "templateId": "custom-application-oidc",
            "inboundProtocolConfiguration": {"oidc": oidc}}
    if app_native:
        body["advancedConfigurations"] = {"enableAPIBasedAuthentication": True}
    st, hd, bd = _req("POST", "/api/server/v1/applications", body)
    if st not in (200, 201): die(f"creating app {name}", st, bd)
    app_id = hd.get("Location", "").rstrip("/").split("/")[-1]
    o = app_oidc(app_id)
    log(OK, f"created app: {name} (client_id {o['clientId']}"
            f"{', App-Native' if app_native else ''}{', CIBA' if ciba else ''})")
    return app_id, o["clientId"], o.get("clientSecret")

def set_subject_email(app_id, name):
    """Make the app assert the user's email as the OIDC subject."""
    patch = {"claimConfiguration": {
        "dialect": "LOCAL",
        "subject": {"claim": {"uri": EMAIL_CLAIM}, "includeUserDomain": False,
                    "includeTenantDomain": False, "useMappedLocalSubject": False,
                    "mappedLocalSubjectMandatory": False},
        "requestedClaims": [{"claim": {"uri": EMAIL_CLAIM}}],
    }}
    st, _, bd = _req("PATCH", f"/api/server/v1/applications/{app_id}", patch)
    if st not in (200, 204): die(f"setting subject=email on {name}", st, bd)
    log(OK, f"   subject=email on {name}")

def set_role_audience_org(app_id, name):
    patch = {"associatedRoles": {"allowedAudience": "ORGANIZATION"}}
    st, _, bd = _req("PATCH", f"/api/server/v1/applications/{app_id}", patch)
    if st not in (200, 204): die(f"setting role audience ORGANIZATION on {name}", st, bd)
    log(OK, f"   role-audience=ORGANIZATION on {name}")

def enable_app_native(app_id, name):
    patch = {"advancedConfigurations": {"enableAPIBasedAuthentication": True}}
    st, _, bd = _req("PATCH", f"/api/server/v1/applications/{app_id}", patch)
    if st not in (200, 204): die(f"enabling App-Native auth on {name}", st, bd)
    log(OK, f"   App-Native authentication on {name}")

def set_bcl(app_id, name, url):
    o = app_oidc(app_id); o.pop("state", None); o.pop("clientSecret", None)
    o.setdefault("logout", {})["backChannelLogoutUrl"] = url
    st, _, bd = _req("PUT", f"/api/server/v1/applications/{app_id}/inbound-protocols/oidc", o)
    if st not in (200, 204): die(f"setting BCL url on {name}", st, bd)
    log(OK, f"   back-channel-logout = {url}")

def subscribe(app_id, name, api_id, scopes):
    body = {"id": api_id, "policyIdentifier": "RBAC", "scopes": scopes}
    st, _, bd = _req("POST", f"/api/server/v1/applications/{app_id}/authorized-apis", body)
    if st not in (200, 201, 409): die(f"subscribing {name} to API {api_id}", st, bd)
    log(OK, f"   subscribed {name} → {len(scopes)} scope(s)")

# ── Agents (SCIM2 Agents; one-shot secret) ───────────────────────────────────
def create_agent(display_name, owner_id):
    # reuse if present (cannot recover the one-shot secret → rotate)
    st, _, bd = scim_get("/scim2/Agents?count=100")
    for r in (_j(bd) or {}).get("Resources", []):
        nm = (r.get("urn:scim:wso2:agent:schema") or {}).get("DisplayName") or r.get("displayName")
        if nm == display_name:
            aid = r["id"]
            # The one-shot create-secret is unrecoverable, so rotate to a KNOWN
            # value and return THAT (so it actually lands in .env — returning
            # None here would write `*_AGENT_SECRET=None` and break auth).
            new_secret = _gen_secret()
            st2, _, bd2 = _req("PATCH", f"/scim2/Agents/{aid}",
                               {"schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
                                "Operations": [{"op": "replace", "path": "password",
                                                "value": new_secret}]},
                               accept="application/scim+json", ctype="application/scim+json")
            if st2 not in (200, 204):
                die(f"rotating secret for existing agent {display_name} (re-run on a non-fresh "
                    f"IS). Destroy the MySQL volume (docker compose down -v) and re-provision.",
                    st2, bd2)
            log(WARN, f"agent exists: {display_name} — rotated secret (re-run)")
            return aid, new_secret
    body = {"urn:scim:wso2:agent:schema": {
        "DisplayName": display_name, "Description": f"{display_name} (demo)",
        "Owner": f"{owner_id}@carbon.super"}}
    st, _, bd = _req("POST", "/scim2/Agents", body,
                     accept="application/scim+json", ctype="application/scim+json")
    if st not in (200, 201): die(f"creating agent {display_name}", st, bd)
    j = _j(bd)
    log(OK, f"created agent: {display_name} (id {j['id'][:8]}…)")
    return j["id"], j.get("password")

def _gen_secret(n=16):
    import string
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n)) + "@1A"

# ── .env emission ────────────────────────────────────────────────────────────
def write_env(service, overlay):
    # Guard: never persist a None — that means a generated value (e.g. an agent
    # secret on a botched re-run) went missing, and `KEY=None` would silently
    # break auth. Fail loudly with remediation instead.
    none_keys = [k for k, v in overlay.items() if v is None]
    if none_keys:
        die(f"refusing to write {service}/.env — missing value(s): {', '.join(none_keys)}. "
            f"Likely a re-run against a non-fresh IS; destroy the MySQL volume and re-provision.")
    example = ROOT / service / ".env.example"
    out = ROOT / service / ".env"
    lines = example.read_text().splitlines()
    seen = set()
    result = []
    for line in lines:
        s = line.strip()
        if s and not s.startswith("#") and "=" in s:
            key = s.split("=", 1)[0].strip()
            if key in overlay:
                result.append(f"{key}={overlay[key]}")
                seen.add(key); continue
        result.append(line)
    # append any overlay keys not present in the template
    extra = [k for k in overlay if k not in seen]
    if extra:
        result.append("")
        result.append("# ─── added by scripts/provision-is.py (fully-local) ───")
        for k in extra:
            result.append(f"{k}={overlay[k]}")
    out.write_text("\n".join(result) + "\n")
    log(OK, f"wrote {service}/.env ({len(overlay)} values)")

# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    print(f"\nProvisioning WSO2 IS for the local demo  →  {IS_BASE}\n")
    st, _, bd = mgmt_get("/api/server/v1/api-resources?limit=1")
    if st != 200:
        die(f"admin auth / connectivity to {IS_BASE} (is it healthy? creds {ADMIN_USER}/****)", st, bd)
    log(OK, f"connected; admin auth OK ({ADMIN_USER})")

    print("\n[1/6] API resources + scopes")
    hr_api_id = ensure_api_resource(HR_API)
    it_api_id = ensure_api_resource(IT_API)

    print("\n[2/6] Demo users (username == email)")
    user_ids = {u["username"]: ensure_user(u) for u in USERS}

    print("\n[3/6] Roles (Organization audience) + scope bindings + membership")
    oid = org_id()
    if not oid: die("could not resolve the organization id for Organization-audience roles")
    log(INFO, f"organization id = {oid}")
    for role, scopes in ROLE_SCOPES.items():
        members = [user_ids[u["username"]] for u in USERS if u["role"] == role]
        ensure_role(role, scopes, oid, members)

    print("\n[4/6] orchestrator-mcp-client (confidential login client)")
    mcp_id, mcp_cid, mcp_sec = create_app(
        "orchestrator-mcp-client",
        [MCP_REDIRECT, MCP_AUTH_CB, POST_LOGOUT],
        ["authorization_code", "refresh_token", "client_credentials"])
    set_subject_email(mcp_id, "orchestrator-mcp-client")
    set_role_audience_org(mcp_id, "orchestrator-mcp-client")
    set_bcl(mcp_id, "orchestrator-mcp-client", BCL_URL)
    subscribe(mcp_id, "orchestrator-mcp-client", hr_api_id, ALL_HR)
    subscribe(mcp_id, "orchestrator-mcp-client", it_api_id, ALL_IT)

    print("\n[5/6] Agents (identity + per-agent OIDC app)")
    owner = user_ids["hradmin@example.com"]            # any user works as Owner
    agents = {}
    # orchestrator-agent: App-Native only (no CIBA, no API subs, no email-subject)
    oa_aid, oa_sec = create_agent("orchestrator-agent", owner)
    oa_app, oa_cid, oa_csec = create_app("orchestrator-agent", [MCP_REDIRECT],
                                         ["authorization_code", "refresh_token"], app_native=True)
    set_role_audience_org(oa_app, "orchestrator-agent")
    agents["orchestrator"] = dict(agent_id=oa_aid, agent_secret=oa_sec, client_id=oa_cid, client_secret=oa_csec)

    # hr-agent / it-agent: App-Native + CIBA + email-subject + API subscription
    for key, disp, api_id, scopes in (
        ("hr", "hr-agent", hr_api_id, ALL_HR),
        ("it", "it-agent", it_api_id, ALL_IT),
    ):
        aid, asec = create_agent(disp, owner)
        app, cid, csec = create_app(disp, [AGENT_REDIRECT],
                                    ["authorization_code", "refresh_token",
                                     "urn:openid:params:grant-type:ciba"],
                                    app_native=True, ciba=True)
        set_subject_email(app, disp)
        set_role_audience_org(app, disp)
        subscribe(app, disp, api_id, scopes)
        agents[key] = dict(agent_id=aid, agent_secret=asec, client_id=cid, client_secret=csec)

    print("\n[6/6] Writing service .env files")
    shared_secret = secrets.token_hex(20)
    openai_key = os.environ.get("OPENAI_API_KEY", "__SET_WSO2_AI_GATEWAY_KEY__")
    # Observability: the AI workloads (orchestrator + 2 agents) export OTEL traces
    # to the WSO2 Agent Manager observability endpoint, authenticating with their
    # per-workload AMP agent key in a custom header. The endpoint is shared
    # (configurable via env); the keys rotate, so they're read per-workload from
    # AMP_KEY_* env (placeholder otherwise — paste the fresh key into the .env).
    # The MCP servers (hr_server/it_server) are plain resource servers — no AMP.
    amp_endpoint = os.environ.get("AMP_OTEL_ENDPOINT",
                                  "https://opentelemetry.obs.dp.cloud.wso2.com/v1/traces")
    common_idp = {
        "WSO2_IS_BASE_URL": IS_INTERNAL_BASE,
        "WSO2_IS_ISSUER": f"{IS_INTERNAL_BASE}/oauth2/token",
        "WSO2_IS_JWKS_URL": f"{IS_INTERNAL_BASE}/oauth2/jwks",
        "IDP_INSECURE_TLS": "1",
        "INTERNAL_REVOKE_SHARED_SECRET": shared_secret,
        "AMP_OTEL_ENDPOINT": amp_endpoint,
    }
    write_env("orchestrator", {**common_idp,
        "ORCHESTRATOR_MCP_CLIENT_ID": mcp_cid, "ORCHESTRATOR_MCP_CLIENT_SECRET": mcp_sec,
        "ORCHESTRATOR_MCP_CLIENT_REDIRECT_URI": MCP_REDIRECT,
        "ORCHESTRATOR_AGENT_ID": agents["orchestrator"]["agent_id"],
        "ORCHESTRATOR_AGENT_SECRET": agents["orchestrator"]["agent_secret"],
        "ORCHESTRATOR_AGENT_OAUTH_CLIENT_ID": agents["orchestrator"]["client_id"],
        "ORCHESTRATOR_AGENT_OAUTH_CLIENT_SECRET": agents["orchestrator"]["client_secret"],
        "HR_AGENT_OAUTH_CLIENT_ID": agents["hr"]["client_id"],
        "IT_AGENT_OAUTH_CLIENT_ID": agents["it"]["client_id"],
        "TRUSTED_SPECIALIST_SUBS": f'{agents["hr"]["agent_id"]},{agents["it"]["agent_id"]}',
        "POST_LOGOUT_REDIRECT_URI": POST_LOGOUT,
        # LLM goes through the WSO2 Agent Manager (SaaS) AI Gateway — OpenAI-
        # compatible, NOT api.openai.com. The gateway issues OPENAI_BASE_URL +
        # OPENAI_API_KEY; the key rides in the "api-key" header (not Bearer).
        # Pass these in the provisioner's env to bake them, else placeholders.
        "LLM_FALLBACK_MODE": "llm",
        "OPENAI_BASE_URL": os.environ.get("OPENAI_BASE_URL", "__SET_WSO2_AI_GATEWAY_BASE_URL__"),
        "OPENAI_API_HEADER": os.environ.get("OPENAI_API_HEADER", "api-key"),
        "OPENAI_API_KEY": openai_key, "OPENAI_MODEL": os.environ.get("OPENAI_MODEL", "gpt-4.1"),
        "AMP_AGENT_API_KEY": os.environ.get("AMP_KEY_ORCHESTRATOR", "__SET_ORCHESTRATOR_AMP_AGENT_KEY__"),
    })
    write_env("hr_agent", {**common_idp,
        "HR_AGENT_ID": agents["hr"]["agent_id"], "HR_AGENT_SECRET": agents["hr"]["agent_secret"],
        "HR_AGENT_OAUTH_CLIENT_ID": agents["hr"]["client_id"],
        "HR_AGENT_OAUTH_CLIENT_SECRET": agents["hr"]["client_secret"],
        "HR_AGENT_REDIRECT_URI": AGENT_REDIRECT,
        "HR_EXPECTED_INBOUND_AUD": mcp_cid,
        "HR_TRUSTED_PEER_AGENTS": agents["orchestrator"]["agent_id"],
        "HR_CIBA_SCOPE": "openid hr_self_rest",
        "AMP_AGENT_API_KEY": os.environ.get("AMP_KEY_HR_AGENT", "__SET_HR_AGENT_AMP_AGENT_KEY__")})
    write_env("it_agent", {**common_idp,
        "IT_AGENT_ID": agents["it"]["agent_id"], "IT_AGENT_SECRET": agents["it"]["agent_secret"],
        "IT_AGENT_OAUTH_CLIENT_ID": agents["it"]["client_id"],
        "IT_AGENT_OAUTH_CLIENT_SECRET": agents["it"]["client_secret"],
        "IT_AGENT_REDIRECT_URI": AGENT_REDIRECT,
        "IT_EXPECTED_INBOUND_AUD": mcp_cid,
        "IT_TRUSTED_PEER_AGENTS": agents["orchestrator"]["agent_id"],
        "IT_CIBA_SCOPE": "openid it_assets_read_rest",
        "AMP_AGENT_API_KEY": os.environ.get("AMP_KEY_IT_AGENT", "__SET_IT_AGENT_AMP_AGENT_KEY__")})
    srv_idp = {"WSO2_IS_BASE_URL": IS_INTERNAL_BASE,
               "AUTH_ISSUER": f"{IS_INTERNAL_BASE}/oauth2/token",
               "JWKS_URL": f"{IS_INTERNAL_BASE}/oauth2/jwks",
               "WSO2_IS_INTROSPECT_URL": f"{IS_INTERNAL_BASE}/oauth2/introspect",
               "DISABLE_SSL_VERIFY": "true",
               "INTERNAL_REVOKE_SHARED_SECRET": shared_secret}
    # REST_VALID_AUDIENCES lets the /api/* REST surface also accept token-A
    # (aud = orchestrator-mcp-client); the MCP-tool validator stays strict on
    # the agent's own client id. Emitted into the .env so compose needs no
    # hard-coded override.
    write_env("hr_server", {**srv_idp,
        "HR_SERVER_EXPECTED_AUD": agents["hr"]["client_id"],
        "HR_SERVER_TRUSTED_PEER_AGENTS": agents["hr"]["agent_id"],
        "HR_SERVER_REST_VALID_AUDIENCES": mcp_cid})
    write_env("it_server", {**srv_idp,
        "IT_SERVER_EXPECTED_AUD": agents["it"]["client_id"],
        "IT_SERVER_TRUSTED_PEER_AGENTS": agents["it"]["agent_id"],
        "IT_SERVER_REST_VALID_AUDIENCES": mcp_cid})

    # creds JSON for inspection (gitignored)
    creds = {"orchestrator_mcp_client": {"client_id": mcp_cid, "client_secret": mcp_sec},
             "agents": agents, "shared_secret": shared_secret,
             "api_resources": {"hr": hr_api_id, "it": it_api_id}}
    (ROOT / "infra" / "generated-is-creds.json").write_text(json.dumps(creds, indent=2))

    print("\n" + "=" * 70)
    print("✓ Provisioning complete.")
    print("  orchestrator-mcp-client:", mcp_cid)
    print("  orchestrator-agent     :", agents["orchestrator"]["agent_id"], "/ app", agents["orchestrator"]["client_id"])
    print("  hr-agent               :", agents["hr"]["agent_id"], "/ app", agents["hr"]["client_id"])
    print("  it-agent               :", agents["it"]["agent_id"], "/ app", agents["it"]["client_id"])
    print("\n  Verify:  IS_BASE_URL=%s ./scripts/check-is-config.py" % IS_BASE)
    if openai_key.startswith("__SET") or os.environ.get("OPENAI_BASE_URL", "").startswith("__SET"):
        print("\n  NOTE: LLM uses the WSO2 Agent Manager AI Gateway. Set OPENAI_BASE_URL +"
              "\n        OPENAI_API_KEY (api-key header) in orchestrator/.env, or re-run with"
              "\n        OPENAI_BASE_URL=… OPENAI_API_KEY=… in the provisioner env.")

if __name__ == "__main__":
    main()
