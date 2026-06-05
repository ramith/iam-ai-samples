#!/usr/bin/env python3
"""
One-command, all-Python setup for the fully-local stack.

Orchestrates the whole bring-up with fail-fast preflights so a fresh machine
goes from clone → running demo in a single command:

    python3 scripts/setup.py            # full: preflight → prep → infra → provision → fleet → smoke
    python3 scripts/setup.py prep       # just fetch the JDBC driver + extract the WSO2 schema
    python3 scripts/setup.py provision  # just (re)configure IS + rewrite the .env files
    python3 scripts/setup.py up         # just bring up the app fleet (assumes IS provisioned)

LLM/AI-gateway creds (optional) are read from the environment and passed through
to the provisioner, e.g.:

    OPENAI_BASE_URL=https://<wso2-agent-manager-gateway>/<route> OPENAI_API_KEY=<key> \
    AMP_KEY_ORCHESTRATOR=<jwt> AMP_KEY_HR_AGENT=<jwt> AMP_KEY_IT_AGENT=<jwt> \
        python3 scripts/setup.py

See docs/architecture/fully-local-setup-plan.md.  Stdlib only — no pip deps.
"""
from __future__ import annotations

import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IS_IMAGE = "wso2/wso2is:7.3.0"
IS_HOME = "/home/wso2carbon/wso2is-7.3.0"
MYSQL_CONNECTOR_VERSION = "8.4.0"
IS_HEALTH = "https://localhost:9443/api/health-check/v1.0/health"
SERVICES = ["orchestrator", "hr_agent", "it_agent", "hr_server", "it_server"]
_CTX = ssl.create_default_context(); _CTX.check_hostname = False; _CTX.verify_mode = ssl.CERT_NONE


# ── tiny console helpers ──────────────────────────────────────────────────────
def step(msg): print(f"\n\033[1m▶ {msg}\033[0m")
def ok(msg):   print(f"  ✓ {msg}")
def info(msg): print(f"  → {msg}")
def die(msg):  print(f"\n\033[31m✗ {msg}\033[0m"); sys.exit(1)


def run(cmd, **kw):
    """Run a command in ROOT, streaming output; die on failure."""
    print(f"  $ {' '.join(cmd)}")
    r = subprocess.run(cmd, cwd=ROOT, **kw)
    if r.returncode != 0:
        die(f"command failed ({r.returncode}): {' '.join(cmd)}")
    return r


# ── preflight ─────────────────────────────────────────────────────────────────
def preflight():
    step("Preflight")
    if subprocess.run(["docker", "compose", "version"],
                      cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        die("Docker Compose v2 not found — install Docker Desktop / `docker compose`.")
    ok("docker compose available")

    # The browser must resolve the IS hostname (token iss / auth_url / login
    # redirects are all https://wso2is:9443). This is the one manual host step.
    try:
        hosts = Path("/etc/hosts").read_text()
    except OSError:
        hosts = ""
    resolves = any(
        line.split("#", 1)[0].split() and line.split("#", 1)[0].split()[0] == "127.0.0.1"
        and "wso2is" in line.split("#", 1)[0].split()[1:]
        for line in hosts.splitlines()
    )
    if not resolves:
        die("/etc/hosts is missing the wso2is alias your browser needs for IS login.\n"
            "  Add it once with:\n"
            '      echo "127.0.0.1 wso2is" | sudo tee -a /etc/hosts')
    ok("/etc/hosts maps wso2is → 127.0.0.1")


# ── prep: JDBC driver + version-matched WSO2 schema (ported from local-setup.sh)
def _cat_from_image(path: str) -> str:
    r = subprocess.run(["docker", "run", "--rm", "--entrypoint", "/bin/cat", IS_IMAGE, path],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"extracting {path} from {IS_IMAGE}:\n{r.stderr[:400]}")
    return r.stdout


def prep():
    step("Prep: released image + JDBC driver + WSO2 schema")
    lib = ROOT / "infra" / "wso2is" / "lib"
    initdb = ROOT / "infra" / "mysql" / "initdb"
    lib.mkdir(parents=True, exist_ok=True); initdb.mkdir(parents=True, exist_ok=True)

    if subprocess.run(["docker", "image", "inspect", IS_IMAGE],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        run(["docker", "pull", IS_IMAGE])
    ok(f"image present: {IS_IMAGE}")

    jar = lib / f"mysql-connector-j-{MYSQL_CONNECTOR_VERSION}.jar"
    if not jar.exists():
        url = (f"https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/"
               f"{MYSQL_CONNECTOR_VERSION}/mysql-connector-j-{MYSQL_CONNECTOR_VERSION}.jar")
        info(f"downloading MySQL Connector/J {MYSQL_CONNECTOR_VERSION}")
        try:
            urllib.request.urlretrieve(url, jar)
        except Exception as e:  # noqa: BLE001
            die(f"downloading JDBC driver: {e}")
    ok(f"driver: infra/wso2is/lib/{jar.name}")

    # 7.3.0 layout: no uma/ script; identity/agent/ schema → its own WSO2_AGENT_DB;
    # consent → identity DB; root mysql.sql → shared DB. (USE prefix per file.)
    mapping = [
        ("10-identity.sql",         f"{IS_HOME}/dbscripts/identity/mysql.sql",       "WSO2_IDENTITY_DB"),
        ("20-agent.sql",            f"{IS_HOME}/dbscripts/identity/agent/mysql.sql", "WSO2_AGENT_DB"),
        ("30-identity-consent.sql", f"{IS_HOME}/dbscripts/consent/mysql.sql",        "WSO2_IDENTITY_DB"),
        ("40-shared.sql",           f"{IS_HOME}/dbscripts/mysql.sql",                "WSO2_SHARED_DB"),
    ]
    for out_name, src, db in mapping:
        info(f"extracting {src} → infra/mysql/initdb/{out_name} (USE {db})")
        body = _cat_from_image(src)
        (initdb / out_name).write_text(
            f"-- Extracted from {IS_IMAGE}:{src} by scripts/setup.py — do not edit.\n"
            f"USE {db};\n{body}")
    ok("schema: infra/mysql/initdb/{00,10,20,30,40}-*.sql")


# ── infra: MySQL + WSO2 IS, wait for IS health ────────────────────────────────
def _is_healthy() -> bool:
    try:
        with urllib.request.urlopen(IS_HEALTH, context=_CTX, timeout=5) as r:
            return r.status == 200
    except Exception:  # noqa: BLE001
        return False


def infra(wait_seconds: int = 240):
    step("Infra: MySQL + WSO2 IS")
    run(["docker", "compose", "up", "-d", "mysql", "wso2is"])
    info("waiting for WSO2 IS to become healthy …")
    deadline = wait_seconds
    waited = 0
    while waited < deadline:
        if _is_healthy():
            ok(f"WSO2 IS healthy at https://localhost:9443 (~{waited}s)")
            return
        time.sleep(6); waited += 6
        if waited % 30 == 0:
            info(f"  … still starting ({waited}s)")
    die("WSO2 IS did not become healthy in time. Check: docker compose logs wso2is")


# ── provision: configure IS + write the 5 service .env (delegates to provision-is.py)
def provision():
    step("Provision IS (configure apps/agents/roles/users + write .env)")
    env = {**os.environ, "IS_BASE_URL": "https://localhost:9443"}
    run([sys.executable, str(ROOT / "scripts" / "provision-is.py")], env=env)


# ── env preflight: .env present + no unfilled IS placeholders ─────────────────
def check_env():
    step("Preflight: generated .env files")
    missing = [s for s in SERVICES if not (ROOT / s / ".env").exists()]
    if missing:
        die(f"missing .env for: {', '.join(missing)} — run `python3 scripts/setup.py provision` first.")
    is_placeholders = []
    llm_placeholders = []
    for s in SERVICES:
        for line in (ROOT / s / ".env").read_text().splitlines():
            if "__SET_" in line:
                key = line.split("=", 1)[0].strip()
                (llm_placeholders if ("OPENAI" in key or "AMP" in key) else is_placeholders).append(f"{s}:{key}")
    if is_placeholders:
        die("IS credential placeholders remain (provisioning incomplete): " + ", ".join(is_placeholders))
    ok("all 5 .env present; IS credentials populated")
    if llm_placeholders:
        info("note: LLM/gateway key not set (chat falls back to keyword router): "
             + ", ".join(llm_placeholders))


# ── fleet + smoke ─────────────────────────────────────────────────────────────
def fleet():
    step("App fleet: build + start")
    run(["docker", "compose", "up", "-d", "--build"])


def smoke():
    step("Smoke test")
    smoke_py = ROOT / "scripts" / "demo-smoke.py"
    if smoke_py.exists():
        subprocess.run([sys.executable, str(smoke_py)], cwd=ROOT)
    else:
        info("scripts/demo-smoke.py not found — skipping")


def done():
    print("\n" + "=" * 64)
    print("\033[32m✓ Fully-local stack is up.\033[0m  Open: http://localhost:8090")
    print("  Sign in: employee@example.com / hradmin@example.com  (NewsMax@1234)")
    print("=" * 64)


# ── entrypoint ────────────────────────────────────────────────────────────────
def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    if cmd in ("all", "full"):
        preflight(); prep(); infra(); provision(); check_env(); fleet(); smoke(); done()
    elif cmd == "prep":
        prep()
    elif cmd == "provision":
        provision(); check_env()
    elif cmd == "up":
        check_env(); fleet(); smoke(); done()
    elif cmd == "preflight":
        preflight()
    else:
        die(f"unknown command '{cmd}'. Use: all | prep | provision | up | preflight")


if __name__ == "__main__":
    main()
