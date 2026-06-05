#!/usr/bin/env bash
#
# One-time asset prep for the fully-local stack (Stage 1).
# Idempotent — safe to re-run; cached downloads/extractions are skipped.
#
# Produces (all gitignored):
#   infra/wso2is/lib/mysql-connector-j-<ver>.jar   — JDBC driver mounted into IS
#   infra/mysql/initdb/{10,20,30,40}-*.sql         — version-matched WSO2 schema,
#                                                    extracted from the released
#                                                    image so MySQL initdb loads it
#                                                    before IS first connects.
#
# Uses the RELEASED wso2/wso2is image as-is (no custom build) — config + driver
# + schema are injected via volume mounts / MySQL init, per WSO2's docker pattern.
#
# See docs/architecture/fully-local-setup-plan.md §4 (Stage 1).
set -euo pipefail

IS_IMAGE="wso2/wso2is:7.3.0"
IS_HOME="/home/wso2carbon/wso2is-7.3.0"
MYSQL_CONNECTOR_VERSION="8.4.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT/infra/wso2is/lib"
INITDB_DIR="$ROOT/infra/mysql/initdb"
mkdir -p "$LIB_DIR" "$INITDB_DIR"

echo "→ ensuring released image is present: $IS_IMAGE"
docker image inspect "$IS_IMAGE" >/dev/null 2>&1 || docker pull "$IS_IMAGE"

# 1. MySQL JDBC driver (GPL — fetched at setup, never committed) ──────────────
JAR="$LIB_DIR/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"
if [ ! -f "$JAR" ]; then
  echo "→ downloading MySQL Connector/J ${MYSQL_CONNECTOR_VERSION}"
  curl -fsSL -o "$JAR" \
    "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${MYSQL_CONNECTOR_VERSION}/mysql-connector-j-${MYSQL_CONNECTOR_VERSION}.jar"
else
  echo "✓ driver already present: $(basename "$JAR")"
fi

# 2. Version-matched WSO2 schema → MySQL initdb ───────────────────────────────
# Each WSO2 dbscript assumes a connected DB; MySQL initdb runs as root with no DB
# selected, so we prepend a USE. Numeric prefixes pin load order (initdb is
# alphabetical; 00-create-databases.sql ships in the repo and runs first).
cat_from_image() { docker run --rm --entrypoint /bin/cat "$IS_IMAGE" "$1"; }

declare -a MAP=(
  "10-identity.sql|$IS_HOME/dbscripts/identity/mysql.sql|WSO2_IDENTITY_DB"
  "20-identity-uma.sql|$IS_HOME/dbscripts/uma/mysql.sql|WSO2_IDENTITY_DB"
  "30-identity-consent.sql|$IS_HOME/dbscripts/consent/mysql.sql|WSO2_IDENTITY_DB"
  "40-shared.sql|$IS_HOME/dbscripts/mysql.sql|WSO2_SHARED_DB"
)

for entry in "${MAP[@]}"; do
  IFS='|' read -r out src db <<<"$entry"
  echo "→ extracting $src → infra/mysql/initdb/$out (USE $db)"
  {
    echo "-- Extracted from $IS_IMAGE:$src by scripts/local-setup.sh — do not edit."
    echo "USE $db;"
    cat_from_image "$src"
  } > "$INITDB_DIR/$out"
done

echo ""
echo "✓ local assets ready."
echo "  driver : infra/wso2is/lib/$(basename "$JAR")"
echo "  schema : infra/mysql/initdb/{00,10,20,30,40}-*.sql"
echo ""
echo "Next: bring up the infra tier —"
echo "  docker compose up -d mysql wso2is"
echo "  docker compose logs -f wso2is      # wait for: WSO2 Carbon started"
echo "  open https://wso2is:9443/console   # (needs /etc/hosts: 127.0.0.1 wso2is)"
