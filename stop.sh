#!/usr/bin/env bash
#
# stop.sh — interactive teardown for the srt-emp stack.
#
# Offers four cleanup levels: graceful stop (keep everything), stop + remove
# volumes, full cleanup (also remove project images and prune networks), or exit.
# Compose-CLI detection and the docker check come from scripts/lib/common.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"

require_docker
detect_compose_cmd || exit 1

echo "Select cleanup level:"
echo "  1) Graceful stop only (preserve everything)"
echo "  2) Stop and remove volumes"
echo "  3) Full cleanup (remove all images and networks)"
echo "  4) Exit"
read -r -p "Choose [1-4]: " choice

case "$choice" in
  1|"")
    compose_cmd stop
    echo "Services stopped (containers/volumes/images preserved)."
    ;;
  2)
    compose_cmd down --volumes --remove-orphans
    echo "Services stopped and project volumes removed."
    ;;
  3)
    compose_cmd down --volumes --remove-orphans --rmi all
    docker network prune -f >/dev/null 2>&1 || true
    echo "Full cleanup completed (project images removed; unused networks pruned)."
    ;;
  4)
    echo "Exit."
    ;;
  *)
    echo "Invalid option." >&2
    exit 1
    ;;
esac
