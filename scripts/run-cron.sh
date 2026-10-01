#!/usr/bin/env bash
set -euo pipefail
export OSTICKET_ENV_FILE="${OSTICKET_ENV_FILE:-${HOME}/osticket/.env}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "${ROOT}/scripts/compose-production.sh" exec -T web php /var/www/html/ticket/api/cron.php
