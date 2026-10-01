#!/usr/bin/env bash
# Daily backup: stage DB + config, restic backup, forget 7d + prune.
set -euo pipefail

ENV_FILE="${OSTICKET_ENV_FILE:-/var/lib/osticket/.env}"
LOCK="${BACKUP_LOCK:-/var/lib/osticket/backup.lock}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?Set RESTIC_REPOSITORY}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:?Set RESTIC_PASSWORD_FILE}"
BACKUP_STAGING="${BACKUP_STAGING:-/var/lib/osticket/backups/staging}"
NFS_MOUNT_POINT="${NFS_MOUNT_POINT:-/mnt/production-backups}"
NFS_EXPECTED_SOURCE="${NFS_EXPECTED_SOURCE:-}"

exec 9>"${LOCK}"
if ! flock -n 9; then
    echo "Backup already running; exiting." >&2
    exit 0
fi

if [[ -n "${NFS_EXPECTED_SOURCE}" ]]; then
    if ! findmnt -rn -T "${NFS_MOUNT_POINT}" >/dev/null 2>&1; then
        echo "NFS mount ${NFS_MOUNT_POINT} not present; aborting (local staging preserved)." >&2
        exit 1
    fi
    actual="$(findmnt -rn -T "${NFS_MOUNT_POINT}" -o SOURCE | head -1)"
    if [[ "${actual}" != "${NFS_EXPECTED_SOURCE}"* ]]; then
        echo "Unexpected mount source ${actual} (wanted ${NFS_EXPECTED_SOURCE}); aborting." >&2
        exit 1
    fi
fi

mkdir -p "${BACKUP_STAGING}/dump"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"

"${ROOT}/scripts/compose-production.sh" exec -T db \
    mysqldump -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --single-transaction "${MYSQL_DATABASE}" \
    > "${BACKUP_STAGING}/dump/${stamp}-osticket.sql"

cp "${OSTICKET_CONFIG_PATH:-/var/lib/osticket/ost-config.php}" \
    "${BACKUP_STAGING}/dump/${stamp}-ost-config.php"

{
    echo "timestamp=${stamp}"
    echo "git_sha=$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "image_tag=${OSTICKET_IMAGE_TAG:-unknown}"
} > "${BACKUP_STAGING}/dump/${stamp}-metadata.txt"

export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE
restic backup "${BACKUP_STAGING}/dump" --tag "osticket,${stamp}"
restic forget --keep-within 7d --prune

echo "Backup completed: ${stamp}"
