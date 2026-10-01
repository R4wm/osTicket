#!/usr/bin/env bash
# Wrapper: always pass deployment --env-file for Compose interpolation.
set -euo pipefail

ENV_FILE="${OSTICKET_ENV_FILE:-/var/lib/osticket/.env}"
COMPOSE_FILE="${OSTICKET_COMPOSE_FILE:-docker-compose.production.yml}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}. Copy .env.example and set secrets." >&2
    exit 1
fi

exec docker compose --env-file "${ENV_FILE}" -f "${ROOT}/${COMPOSE_FILE}" "$@"
