#!/usr/bin/env bash
# backup (default), check, or retention. All actions require the production NFS
# repository and share one lock; failed runs preserve the last complete archive.
set -euo pipefail
umask 077

# shellcheck source=lib-production.sh
source "$(dirname "$0")/lib-production.sh"
osticket_load_env
action="${1:-backup}"
case "${action}" in backup|check|retention) ;; *) echo "Usage: $0 [backup|check|retention]" >&2; exit 2 ;; esac
if (( $# > 1 )); then echo "Usage: $0 [backup|check|retention]" >&2; exit 2; fi

export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-}"
BACKUP_STAGING="${BACKUP_STAGING:-${OSTICKET_STATE_DIR}/backups/staging}"
BACKUP_LOCK="${BACKUP_LOCK:-${OSTICKET_STATE_DIR}/backup.lock}"
BACKUP_METRICS_FILE="${BACKUP_METRICS_FILE:-${OSTICKET_STATE_DIR}/metrics/backup.prom}"
NFS_MOUNT_POINT="${NFS_MOUNT_POINT:-}"
NFS_EXPECTED_SOURCE="${NFS_EXPECTED_SOURCE:-}"
NFS_EXPECTED_FSTYPE="${NFS_EXPECTED_FSTYPE:-}"

mkdir -p "$(dirname "${BACKUP_LOCK}")"
exec 9>"${BACKUP_LOCK}"
if ! flock -n 9; then
    echo "Backup maintenance already running; no new backup was taken." >&2
    exit 75
fi

last_attempt=0
last_success=0
last_attempt_success=0
maintenance_success=1
repository_free=-1
payload_dir=
archive_tmp=
metrics_tmp=
if [[ -f "${BACKUP_METRICS_FILE}" ]]; then
    while read -r metric value _; do
        [[ "${value:-}" =~ ^[0-9]+$ ]] || continue
        case "${metric}" in
            osticket_backup_last_attempt_timestamp_seconds) last_attempt="${value}" ;;
            osticket_backup_last_success_timestamp_seconds) last_success="${value}" ;;
            osticket_backup_last_attempt_success) last_attempt_success="${value}" ;;
            osticket_backup_maintenance_success) maintenance_success="${value}" ;;
        esac
    done < "${BACKUP_METRICS_FILE}"
fi

write_metrics() {
    local metrics_dir
    metrics_dir="$(dirname "${BACKUP_METRICS_FILE}")"
    mkdir -p -m 0755 "${metrics_dir}" || return 1
    metrics_tmp="$(mktemp "${metrics_dir}/.backup.prom.XXXXXX")" || return 1
    {
        printf 'osticket_backup_last_attempt_success %s\n' "${last_attempt_success}"
        printf 'osticket_backup_last_attempt_timestamp_seconds %s\n' "${last_attempt}"
        printf 'osticket_backup_last_success_timestamp_seconds %s\n' "${last_success}"
        printf 'osticket_backup_repository_free_bytes %s\n' "${repository_free}"
        printf 'osticket_backup_maintenance_success %s\n' "${maintenance_success}"
    } > "${metrics_tmp}" || return 1
    chmod 0644 "${metrics_tmp}" || return 1
    mv -f "${metrics_tmp}" "${BACKUP_METRICS_FILE}" || return 1
    metrics_tmp=
}

finish() {
    local result="$1"
    trap - EXIT
    if (( result != 0 )); then
        if [[ "${action}" == backup ]]; then last_attempt_success=0; fi
        maintenance_success=0
    fi
    if ! write_metrics; then
        echo "Failed to publish backup metrics." >&2
        if (( result == 0 )); then result=1; fi
    fi
    [[ -z "${payload_dir}" ]] || rm -rf -- "${payload_dir}"
    [[ -z "${archive_tmp}" ]] || rm -f -- "${archive_tmp}"
    [[ -z "${metrics_tmp}" ]] || rm -f -- "${metrics_tmp}"
    exit "${result}"
}
trap 'finish "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ "${action}" == backup ]]; then
    last_attempt="$(date +%s)"
    last_attempt_success=0
fi
write_metrics

validate_repository_mount() {
    local mount_path repository_path actual
    : "${RESTIC_REPOSITORY:?Set RESTIC_REPOSITORY}" "${RESTIC_PASSWORD_FILE:?Set RESTIC_PASSWORD_FILE}"
    : "${NFS_MOUNT_POINT:?Set NFS_MOUNT_POINT}" "${NFS_EXPECTED_SOURCE:?Set NFS_EXPECTED_SOURCE}"
    case "${NFS_EXPECTED_FSTYPE}" in nfs|nfs4) ;; *) echo "Expected filesystem type must be nfs or nfs4." >&2; return 1 ;; esac
    mount_path="$(realpath -m "${NFS_MOUNT_POINT}")"
    repository_path="$(realpath -m "${RESTIC_REPOSITORY}")"
    if [[ "${RESTIC_REPOSITORY}" != /* || "${repository_path}" != "${mount_path}/"* ]]; then
        echo "Restic repository must be a local path inside the expected NFS mount." >&2
        return 1
    fi
    if ! actual="$(findmnt -rn -M "${mount_path}" -o SOURCE,FSTYPE,TARGET)" ||
        [[ "${actual}" != "${NFS_EXPECTED_SOURCE} ${NFS_EXPECTED_FSTYPE} ${mount_path}" ]]; then
        echo "Expected NFS source, filesystem type, or mount point does not match; backup aborted." >&2
        return 1
    fi
    # Reject a repository behind a nested local mount or symlink out of NFS.
    if ! actual="$(findmnt -rn -T "${repository_path}" -o SOURCE,FSTYPE,TARGET)" ||
        [[ "${actual}" != "${NFS_EXPECTED_SOURCE} ${NFS_EXPECTED_FSTYPE} ${mount_path}" ]]; then
        echo "Repository is not backed by the validated NFS mount; backup aborted." >&2
        return 1
    fi
    [[ -d "${repository_path}" ]] || { echo "Restic repository directory is missing." >&2; return 1; }
    [[ -r "${RESTIC_PASSWORD_FILE}" ]] || { echo "Restic password file is unreadable." >&2; return 1; }
    repository_free="$(df -B1 --output=avail "${repository_path}" | tail -n 1 | tr -d ' ')"
    [[ "${repository_free}" =~ ^[0-9]+$ ]]
}
validate_repository_mount

case "${action}" in
    check)
        restic check --read-data
        maintenance_success=1
        ;;
    retention)
        restic forget --keep-within 7d --prune
        maintenance_success=1
        ;;
    backup)
        : "${MYSQL_USER:?Set MYSQL_USER}" "${MYSQL_PASSWORD:?Set MYSQL_PASSWORD}" "${OSTICKET_CONFIG_PATH:?Set OSTICKET_CONFIG_PATH}"
        MYSQL_DATABASE="${MYSQL_DATABASE:-osticket}"
        if ! osticket_is_installed; then
            echo "osTicket is not installed; refusing to archive an incomplete installation." >&2
            exit 1
        fi
        mkdir -p "${BACKUP_STAGING}"
        payload_dir="$(mktemp -d "${BACKUP_STAGING}/.payload.XXXXXX")"
        archive_tmp="$(mktemp "${BACKUP_STAGING}/.osticket-backup.tar.XXXXXX")"
        export MYSQL_PWD="${MYSQL_PASSWORD}"
        nontransactional="$("${OSTICKET_SCRIPT_ROOT}/scripts/compose-production.sh" exec -T -e MYSQL_PWD db \
            mariadb --user="${MYSQL_USER}" --batch --skip-column-names "${MYSQL_DATABASE}" \
            --execute="SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' AND ENGINE <> 'InnoDB';")"
        if [[ "${nontransactional}" != 0 ]]; then
            echo "Database is not InnoDB-only; a quiesced backup procedure is required." >&2
            exit 1
        fi
        "${OSTICKET_SCRIPT_ROOT}/scripts/compose-production.sh" exec -T -e MYSQL_PWD db \
            mariadb-dump --user="${MYSQL_USER}" --single-transaction --skip-lock-tables --hex-blob "${MYSQL_DATABASE}" \
            > "${payload_dir}/osticket.sql"
        [[ -s "${payload_dir}/osticket.sql" ]] || { echo "Database dump is empty." >&2; exit 1; }
        unset MYSQL_PWD
        cp "${OSTICKET_CONFIG_PATH}" "${payload_dir}/ost-config.php"
        {
            printf 'timestamp=%s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
            printf 'git_sha=%s\n' "$(git -C "${OSTICKET_SCRIPT_ROOT}" rev-parse HEAD 2>/dev/null || printf unknown)"
            printf 'image_tag=%s\n' "${OSTICKET_IMAGE_TAG:-local}"
            printf 'database=%s\n' "${MYSQL_DATABASE}"
        } > "${payload_dir}/metadata.txt"
        (cd "${payload_dir}" && sha256sum osticket.sql ost-config.php metadata.txt > SHA256SUMS)
        tar -C "${payload_dir}" -cf "${archive_tmp}" osticket.sql ost-config.php metadata.txt SHA256SUMS
        mv -f "${archive_tmp}" "${BACKUP_STAGING}/osticket-backup.tar"
        archive_tmp=
        restic backup "${BACKUP_STAGING}/osticket-backup.tar" --tag osticket
        last_success="$(date +%s)"
        write_metrics
        restic forget --keep-within 7d --prune
        maintenance_success=1
        last_attempt_success=1
        ;;
esac
echo "osTicket ${action} completed."
