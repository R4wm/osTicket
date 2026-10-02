#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib-production.sh
source "$(dirname "$0")/lib-production.sh"
osticket_load_env
if ! osticket_is_installed; then
    echo "osTicket is not installed; cron skipped."
    exit 0
fi
umask 077
cron_lock="${CRON_LOCK:-${OSTICKET_STATE_DIR}/cron.lock}"
mkdir -p "$(dirname "${cron_lock}")"
exec 9>"${cron_lock}"
if ! flock -n 9; then
    echo "Cron already running; skipped."
    exit 0
fi
exec "${OSTICKET_SCRIPT_ROOT}/scripts/compose-production.sh" exec -T --user www-data web php /var/www/html/ticket/api/cron.php
