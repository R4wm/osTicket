#!/usr/bin/env bash
# Wrapper: always pass deployment --env-file for Compose interpolation.
set -euo pipefail

# shellcheck source=lib-production.sh
source "$(dirname "$0")/lib-production.sh"
osticket_load_env
exec docker compose --env-file "${OSTICKET_ENV_FILE}" \
    -f "$(osticket_compose_file)" -p "${OSTICKET_PROJECT_NAME:-osticket}" "$@"
