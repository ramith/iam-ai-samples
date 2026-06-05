#!/usr/bin/env bash
# Deprecated shim — setup is now all-Python. This runs only the prep step
# (fetch the MySQL JDBC driver + extract the version-matched WSO2 schema).
# Full one-command bring-up:  python3 scripts/setup.py
exec python3 "$(dirname "$0")/setup.py" prep "$@"
