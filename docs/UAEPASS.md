# UAEPass federated login

The client app's login page offers **"Sign in with UAEPass"** alongside local Basic
auth. Federated users are JIT-mapped to local accounts so they inherit local roles and
scopes, and per-action CIBA consent works for them.

## What the bootstrap configures

All of this is reproduced on a clean start by `scripts/bootstrap-wso2is-entrypoint.sh`:

1. **Connector deployment** (`wso2-is/Dockerfile`) — the UAEPass OIDC authenticator
   JAR into `repository/components/dropins/`, the branded error JSP, and the logo.
2. **UAEPass IdP** (`ensure_uaepass_idp`) — staging mode (`IsStagingEnv=true`, so the
   connector uses `stg-id.uaepass.ae` endpoints), public sandbox creds (`sandbox_stage`),
   callback `https://localhost:9443/commonauth`, `acr_values`, logout enabled, and
   **JIT provisioning** (`PROVISION_SILENTLY`, `associateLocalUser`).
3. **Claim mapping** (`set_uaepass_claims`) — maps UAEPass `email` → local
   `emailaddress` and sets the **user-id claim to `email`**, so JIT resolves the
   federated user to the email-named local account.
4. **App wiring** — UAEPass added to the login sequence of `orchestrator-mcp-client`
   (the SPA's login app) **and** the agent apps (so the CIBA consent window can
   authenticate federated users). All apps set `useMappedLocalSubject=true` and
   `skipLoginConsent=true`.
5. **Branding** (`set_app_branding`) — UAE PASS logo/title/colour/links applied at
   **APP scope** on the client login app only (not org-wide / Console). Both branding
   functions build on WSO2's full default theme (`wso2-is/default/sample-payload.json`)
   so the login page is always fully styled; `set_app_branding` overlays only the UAE
   PASS specifics.
6. **JIT target users** — `sivanoly@wso2.com` (HR Admin) and `ramith@wso2.com`
   (employee) are pre-created so federated logins associate to accounts that already
   carry the right roles.

When `ENABLE_UAEPASS=false` the bootstrap instead **detaches** UAEPass from all login
sequences and applies neutral **Smart Employee** branding (`set_generic_branding`):
the same default theme overlaid only with the Smart Employee logo
(`wso2-is/default/smart-employee-logo.jpeg`, deployed into the IS image) and a
`© {{currentYear}} Smart Employee` copyright. The flag's single source of truth is
`config/master.env` — the IS bootstrap reads it from the mounted file and the
orchestrator gets it rendered into its `.env`.

## Connector compatibility (IS 7.3 / Nimbus 10)

The published UAEPass connector **v1.1.6** is built against Nimbus ≤ 8 and calls
`JSONObjectUtils.parse(String) → net.minidev.json.JSONObject`, a method **removed in
Nimbus 9**. IS 7.3 ships **Nimbus 10.3.0**, so the stock JAR either fails OSGi
resolution (manifest caps `com.nimbusds.* < 8.0.0`) or, if forced, throws
`NoSuchMethodError` at the userinfo step.

**Fix applied (baked into `wso2-is/`):** the connector's 6 source files were
**recompiled against IS 7.3's own Nimbus 10 jars** (the source is already
forward-compatible — `parse(...).entrySet()` works on the `Map` Nimbus 10 returns),
and the manifest import ranges were widened. A side-by-side Nimbus approach does **not**
work (OSGi uses-constraint conflict with the IS framework that also exposes Nimbus 10).

The recompiled JAR is the 44 KB `org.wso2.carbon.identity.authenticator.uaepass-1.1.6.jar`
in `wso2-is/uaepass/` and is committed.

## Why each setting matters (failure modes)

| Setting | Without it |
|---|---|
| Claim mapping `email` → user-id | Federated subject is the UAEPass UUID → JIT makes a parallel account; CIBA login_hint (email) ≠ consent user → **401** "authenticated user is not the same as resolved user". |
| `useMappedLocalSubject=true` (login app) | token-A has only `email openid profile` → reports/sidebar **403 insufficient_scope** (local roles not applied to the federated session). |
| `useMappedLocalSubject=true` (agent apps) | CIBA consent window resolves to the UUID → **401** on approval. |
| `skipLoginConsent=true` | The programmatic Pattern-C flow can't drive a consent page for a "new" federated user → only OIDC default scopes granted. |
| UAEPass on agent apps' login sequence | A federated user (no local password) is shown a Basic login they can't complete in the consent window. |

## Requirements / notes

- **Outbound internet** to `stg-id.uaepass.ae` is required for the token exchange.
- JIT association matches by **email**; if UAEPass staging returns an email different
  from the pre-created usernames, update the pre-created users to match.
- Branding logo `imgURL` points to the asset deployed on IS
  (`…/authenticationendpoint/…/uaepass-logo.png`), loaded by the browser from
  `localhost:9443`; change it if IS is served on another host.

## References

- https://medium.com/identity-beyond-borders/federate-uaepass-for-authentication-in-wso2-identity-server-from-v5-11-0-e7594c63e8f2
- https://github.com/wso2-extensions/identity-outbound-auth-uaepass/blob/main/docs/config.md
