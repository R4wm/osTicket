#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "${ROOT}/scripts/compose-production.sh" exec -T web php /var/www/html/ticket/api/cron.php
