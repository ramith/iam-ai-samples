#!/usr/bin/env bash
#
# custom-entrypoint.sh — container entrypoint for the WSO2 IS image.
#
# Starts wso2server in the background, then (unless BOOTSTRAP_ON_START=false)
# waits for IS readiness and runs the bootstrap provisioning script, dropping a
# ready marker on success. Forwards TERM/INT to the server for clean shutdown
# and finally waits on the server PID so the container lifecycle tracks IS.
#
# Env: WSO2_START_CMD, BOOTSTRAP_SCRIPT, BOOTSTRAP_ON_START,
#      BOOTSTRAP_WAIT_SECONDS, BOOTSTRAP_READY_FILE.
set -euo pipefail

WSO2_START_CMD="${WSO2_START_CMD:-/opt/wso2is/bin/wso2server.sh}"
BOOTSTRAP_SCRIPT="${BOOTSTRAP_SCRIPT:-/workspace/scripts/bootstrap-wso2is-entrypoint.sh}"
BOOTSTRAP_ON_START="${BOOTSTRAP_ON_START:-true}"
BOOTSTRAP_WAIT_SECONDS="${BOOTSTRAP_WAIT_SECONDS:-300}"
BOOTSTRAP_READY_FILE="${BOOTSTRAP_READY_FILE:-/workspace/.bootstrap/wso2is.ready}"

# Clear any stale ready marker so readiness reflects this startup cycle.
prepare_ready_marker() {
  mkdir -p "$(dirname "${BOOTSTRAP_READY_FILE}")"
  rm -f "${BOOTSTRAP_READY_FILE}" || true
}

# Touch the ready marker that host-side waiters poll for.
mark_bootstrap_ready() {
  mkdir -p "$(dirname "${BOOTSTRAP_READY_FILE}")"
  touch "${BOOTSTRAP_READY_FILE}"
  echo "[entrypoint] bootstrap ready marker: ${BOOTSTRAP_READY_FILE}"
}

"${WSO2_START_CMD}" &
WSO2_PID=$!

# TERM/INT handler: forward the signal to wso2server and wait for it to exit.
terminate() {
  echo "[entrypoint] stopping WSO2 IS (pid=${WSO2_PID})"
  kill -TERM "${WSO2_PID}" 2>/dev/null || true
  wait "${WSO2_PID}" || true
}
trap terminate TERM INT

# Poll JWKS until IS is ready or BOOTSTRAP_WAIT_SECONDS elapses (1 on timeout).
wait_for_wso2() {
  local deadline=$((SECONDS + BOOTSTRAP_WAIT_SECONDS))
  echo "[entrypoint] waiting for WSO2 IS readiness at https://localhost:9443/oauth2/jwks"
  while (( SECONDS < deadline )); do
    if curl -skf "https://localhost:9443/oauth2/jwks" >/dev/null 2>&1; then
      echo "[entrypoint] WSO2 IS is ready"
      return 0
    fi
    sleep 2
  done
  return 1
}

# Wait for readiness, then run the bootstrap script (no-op if disabled/missing);
# a bootstrap failure is logged but never crashes the container.
run_bootstrap() {
  if [[ "${BOOTSTRAP_ON_START}" != "true" ]]; then
    echo "[entrypoint] bootstrap disabled (BOOTSTRAP_ON_START=${BOOTSTRAP_ON_START}); waiting for IS readiness"
    if wait_for_wso2; then
      mark_bootstrap_ready
    fi
    return 0
  fi

  if [[ ! -f "${BOOTSTRAP_SCRIPT}" ]]; then
    echo "[entrypoint] bootstrap script not found: ${BOOTSTRAP_SCRIPT}; skipping"
    return 0
  fi

  if ! wait_for_wso2; then
    echo "[entrypoint] WSO2 IS readiness timeout; skipping bootstrap"
    return 0
  fi

  echo "[entrypoint] running bootstrap script: ${BOOTSTRAP_SCRIPT}"
  if ! bash "${BOOTSTRAP_SCRIPT}"; then
    echo "[entrypoint] bootstrap failed; WSO2 IS will continue running"
    return 0
  fi
  echo "[entrypoint] bootstrap completed"
  mark_bootstrap_ready
}

prepare_ready_marker
run_bootstrap

wait "${WSO2_PID}"
