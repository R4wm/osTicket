#!/usr/bin/env bash
# Exercise the real entrypoints using fake Docker/NFS/Restic at private paths.
set -euo pipefail
script_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "${test_dir}"' EXIT
mkdir -p "${test_dir}/bin" "${test_dir}/nfs/osticket/restic-repo" "${test_dir}/remote"
export PATH="${test_dir}/bin:${PATH}"
export MOCK_TRACE="${test_dir}/trace"
export MOCK_REMOTE="${test_dir}/remote"
export TEST_EXPECTED_PASSWORD='test-only $literal password'
export OSTICKET_ENV_FILE="${test_dir}/deployment.env"
cat > "${test_dir}/config.php" <<'CONFIG'
<?php
define('OSTINSTALLED', TRUE);
define('SECRET_SALT', 'test-salt');
CONFIG
printf 'test-only-restic-password\n' > "${test_dir}/restic-password"
cat > "${test_dir}/base.env" <<ENV
MYSQL_USER=osticket
MYSQL_PASSWORD='test-only \$literal password'
MYSQL_DATABASE=osticket
MYSQL_ROOT_PASSWORD=unused-test-root
OSTICKET_PROJECT_NAME=osticket-test
OSTICKET_CONFIG_PATH='${test_dir}/config.php'
OSTICKET_STATE_DIR='${test_dir}/state'
OSTICKET_IMAGE_TAG=test-image
RESTIC_REPOSITORY='${test_dir}/nfs/osticket/restic-repo'
RESTIC_PASSWORD_FILE='${test_dir}/restic-password'
BACKUP_STAGING='${test_dir}/stage'
BACKUP_LOCK='${test_dir}/locks/backup.lock'
CRON_LOCK='${test_dir}/locks/cron.lock'
BACKUP_METRICS_FILE='${test_dir}/metrics/backup.prom'
NFS_MOUNT_POINT='${test_dir}/nfs'
NFS_EXPECTED_SOURCE='nas:/exports/baser4wm'
NFS_EXPECTED_FSTYPE=nfs
ENV
cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"
cat > "${test_dir}/bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker' >> "${MOCK_TRACE}"
for argument in "$@"; do
    [[ "${argument}" != *"${TEST_EXPECTED_PASSWORD}"* ]] || { echo 'Password leaked to Docker argv.' >&2; exit 90; }
    printf ' %s' "${argument}" >> "${MOCK_TRACE}"
done
printf '\n' >> "${MOCK_TRACE}"
for argument in "$@"; do
    case "${argument}" in
        mariadb)
            [[ "${MYSQL_PWD:-}" == "${TEST_EXPECTED_PASSWORD}" ]] || exit 91
            printf '%s\n' "${MOCK_NONTRANSACTIONAL:-0}"
            exit 0
            ;;
        mariadb-dump)
            [[ "${MYSQL_PWD:-}" == "${TEST_EXPECTED_PASSWORD}" ]] || exit 91
            if [[ "${MOCK_ABORT_DUMP:-0}" == 1 ]]; then kill -TERM "${PPID}"; printf 'partial dump\n'; exit 0; fi
            if [[ "${MOCK_FAIL_DUMP:-0}" == 1 ]]; then printf 'partial dump\n'; exit 3; fi
            if [[ "${MOCK_EMPTY_DUMP:-0}" == 1 ]]; then exit 0; fi
            printf 'CREATE TABLE sample (id int);\nINSERT INTO sample VALUES (%s);\n' "${MOCK_REVISION:-1}"
            exit 0
            ;;
    esac
done
MOCK_DOCKER
cat > "${test_dir}/bin/findmnt" <<'MOCK_FINDMNT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${MOCK_MISSING_MOUNT:-0}" != 1 ]] || exit 1
if [[ " $* " == *' -T '* && "${MOCK_NESTED_LOCAL:-0}" == 1 ]]; then
    printf '/dev/mock ext4 %s/nested\n' "${NFS_MOUNT_POINT}"
else
    printf '%s %s %s\n' "${MOCK_MOUNT_SOURCE:-${NFS_EXPECTED_SOURCE}}" "${MOCK_MOUNT_FSTYPE:-${NFS_EXPECTED_FSTYPE}}" "${NFS_MOUNT_POINT}"
fi
MOCK_FINDMNT
cat > "${test_dir}/bin/df" <<'MOCK_DF'
#!/usr/bin/env bash
printf 'Avail\n104857600\n'
MOCK_DF
cat > "${test_dir}/bin/restic" <<'MOCK_RESTIC'
#!/usr/bin/env bash
set -euo pipefail
printf 'restic %s\n' "$*" >> "${MOCK_TRACE}"
case "$1" in
    backup)
        [[ "${MOCK_FAIL_RESTIC:-0}" != 1 ]] || exit 4
        cp "$2" "${MOCK_REMOTE}/latest.tar"
        ;;
    forget) [[ "${MOCK_FAIL_PRUNE:-0}" != 1 ]] || exit 5 ;;
    check) [[ "${MOCK_FAIL_CHECK:-0}" != 1 ]] || exit 6 ;;
    *) exit 92 ;;
esac
MOCK_RESTIC
chmod +x "${test_dir}/bin/"*
: > "${MOCK_TRACE}"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_exit() {
    local expected="$1" result=0
    shift
    "$@" > "${test_dir}/output" 2>&1 || result=$?
    [[ "${result}" == "${expected}" ]] || fail "expected exit ${expected}, got ${result}"
    ! grep -Fq -- "${TEST_EXPECTED_PASSWORD}" "${test_dir}/output" || fail 'secret appeared in output'
}
metric() { awk -v name="$1" '$1 == name {print $2}' "${test_dir}/metrics/backup.prom"; }
archive_hash() { sha256sum "${test_dir}/stage/osticket-backup.tar" | cut -d ' ' -f 1; }
assert_failure_preserves() {
    local before="$(archive_hash)" success="$(metric osticket_backup_last_success_timestamp_seconds)"
    expect_exit 1 "$@"
    [[ "$(archive_hash)" == "${before}" ]] || fail 'failed staging replaced the complete archive'
    [[ "$(metric osticket_backup_last_success_timestamp_seconds)" == "${success}" ]] || fail 'failure changed the successful backup timestamp'
    [[ "$(metric osticket_backup_last_attempt_success)" == 0 ]] || fail 'failure metric missing'
}
assert_configuration_failure() {
    local setting="$1" invalid_value="$2" trace_lines
    cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"
    expect_exit 0 "${script_root}/scripts/backup-osticket.sh"
    [[ "$(metric osticket_backup_last_attempt_success)" == 1 ]] || fail 'configuration test requires a successful preceding backup'
    trace_lines="$(wc -l < "${MOCK_TRACE}")"
    if [[ "${invalid_value}" == __unset__ ]]; then
        sed "/^${setting}=/d" "${test_dir}/base.env" > "${OSTICKET_ENV_FILE}"
    else
        printf '%s=%q\n' "${setting}" "${invalid_value}" >> "${OSTICKET_ENV_FILE}"
    fi
    assert_failure_preserves env -u "${setting}" "${script_root}/scripts/backup-osticket.sh"
    [[ "$(metric osticket_backup_maintenance_success)" == 0 ]] || fail 'configuration failure did not immediately clear maintenance success'
    [[ "$(metric osticket_backup_repository_free_bytes)" == -1 ]] || fail 'invalid configuration reported repository free space'
    [[ "$(wc -l < "${MOCK_TRACE}")" == "${trace_lines}" ]] || fail 'invalid configuration reached Docker or Restic'
    cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"
}

expect_exit 0 "${script_root}/scripts/compose-production.sh" ps
[[ "$(head -n 1 "${MOCK_TRACE}")" == *"--env-file ${OSTICKET_ENV_FILE}"* ]] || fail 'wrapper selected another env file'
[[ "$(head -n 1 "${MOCK_TRACE}")" == *'-p osticket-test'* ]] || fail 'wrapper lost configured project'
expect_exit 0 "${script_root}/scripts/backup-osticket.sh"
[[ -f "${test_dir}/locks/backup.lock" && ! -e "${test_dir}/state/backup.lock" ]] || fail 'lock path was resolved before loading env'
[[ "$(metric osticket_backup_last_attempt_success)" == 1 ]] || fail 'success metric missing'
[[ "$(metric osticket_backup_repository_free_bytes)" == 104857600 ]] || fail 'NAS space metric missing'
[[ "$(stat -c %a "${test_dir}/stage/osticket-backup.tar")" == 600 ]] || fail 'archive is not private'
[[ "$(stat -c %a "${test_dir}/metrics/backup.prom")" == 644 ]] || fail 'metrics are unreadable by exporter'
[[ "$(stat -c %a "${test_dir}/metrics")" == 755 ]] || fail 'metrics directory mode wrong'
mkdir "${test_dir}/extracted"
tar -xf "${MOCK_REMOTE}/latest.tar" -C "${test_dir}/extracted"
(cd "${test_dir}/extracted" && sha256sum -c SHA256SUMS >/dev/null)
grep -Fq test-salt "${test_dir}/extracted/ost-config.php" || fail 'config salt was lost'
grep -Fq 'image_tag=test-image' "${test_dir}/extracted/metadata.txt" || fail 'image metadata missing'

for revision in {2..9}; do
    expect_exit 0 env MOCK_REVISION="${revision}" "${script_root}/scripts/backup-osticket.sh"
done
[[ "$(find "${test_dir}/stage" -maxdepth 1 -type f | wc -l)" == 1 ]] || fail 'staging accumulated historical files'
[[ "$(tar -tf "${MOCK_REMOTE}/latest.tar" | wc -l)" == 4 ]] || fail 'archive accumulated historical dumps'
tar -xOf "${MOCK_REMOTE}/latest.tar" osticket.sql | grep -Fq 'VALUES (9)' || fail 'latest dump not restored'
grep -Fq 'restic forget --keep-within 7d --prune' "${MOCK_TRACE}" || fail 'retention does not reclaim data'

# Start each regression from success=1: an already-failed metric would conceal
# configuration validation exiting before the metrics handler is installed.
for setting in RESTIC_REPOSITORY RESTIC_PASSWORD_FILE NFS_MOUNT_POINT NFS_EXPECTED_SOURCE NFS_EXPECTED_FSTYPE; do
    assert_configuration_failure "${setting}" ''
done
assert_configuration_failure NFS_EXPECTED_SOURCE __unset__
assert_configuration_failure NFS_EXPECTED_FSTYPE ext4

assert_failure_preserves env MOCK_EMPTY_DUMP=1 "${script_root}/scripts/backup-osticket.sh"
before="$(archive_hash)"
expect_exit 3 env MOCK_FAIL_DUMP=1 "${script_root}/scripts/backup-osticket.sh"
[[ "$(archive_hash)" == "${before}" ]] || fail 'partial dump replaced complete archive'
expect_exit 143 env MOCK_ABORT_DUMP=1 "${script_root}/scripts/backup-osticket.sh"
[[ "$(archive_hash)" == "${before}" ]] || fail 'interrupted dump replaced complete archive'
assert_failure_preserves env MOCK_NONTRANSACTIONAL=1 "${script_root}/scripts/backup-osticket.sh"
assert_failure_preserves env MOCK_MISSING_MOUNT=1 "${script_root}/scripts/backup-osticket.sh"
[[ "$(metric osticket_backup_repository_free_bytes)" == -1 ]] || fail 'unavailable NAS reported local free space'
assert_failure_preserves env MOCK_MOUNT_SOURCE='nas:/exports/baser4wm-other' "${script_root}/scripts/backup-osticket.sh"
assert_failure_preserves env MOCK_MOUNT_FSTYPE=ext4 "${script_root}/scripts/backup-osticket.sh"
assert_failure_preserves env MOCK_NESTED_LOCAL=1 "${script_root}/scripts/backup-osticket.sh"

printf "NFS_EXPECTED_SOURCE=''\n" >> "${OSTICKET_ENV_FILE}"
assert_failure_preserves "${script_root}/scripts/backup-osticket.sh"
cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"
printf "RESTIC_REPOSITORY='%s/local-repo'\n" "${test_dir}" >> "${OSTICKET_ENV_FILE}"
mkdir "${test_dir}/local-repo"
assert_failure_preserves "${script_root}/scripts/backup-osticket.sh"
cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"
ln -s "${test_dir}/local-repo" "${test_dir}/nfs/link"
printf "RESTIC_REPOSITORY='%s/nfs/link'\n" "${test_dir}" >> "${OSTICKET_ENV_FILE}"
assert_failure_preserves "${script_root}/scripts/backup-osticket.sh"
cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"

printf 'NFS_EXPECTED_FSTYPE=nfs4\n' >> "${OSTICKET_ENV_FILE}"
expect_exit 0 "${script_root}/scripts/backup-osticket.sh"
cp "${test_dir}/base.env" "${OSTICKET_ENV_FILE}"

old_success="$(metric osticket_backup_last_success_timestamp_seconds)"
expect_exit 4 env MOCK_FAIL_RESTIC=1 MOCK_REVISION=10 "${script_root}/scripts/backup-osticket.sh"
[[ "$(metric osticket_backup_last_success_timestamp_seconds)" == "${old_success}" ]] || fail 'failed Restic upload advanced success'
tar -xOf "${test_dir}/stage/osticket-backup.tar" osticket.sql | grep -Fq 'VALUES (10)' || fail 'latest local archive not retained on upload failure'
expect_exit 5 env MOCK_FAIL_PRUNE=1 "${script_root}/scripts/backup-osticket.sh"
[[ "$(metric osticket_backup_last_attempt_success)" == 0 ]] || fail 'prune failure was hidden'
[[ "$(metric osticket_backup_maintenance_success)" == 0 ]] || fail 'maintenance failure was hidden'
expect_exit 0 "${script_root}/scripts/backup-osticket.sh"
old_attempt="$(metric osticket_backup_last_attempt_timestamp_seconds)"
expect_exit 6 env MOCK_FAIL_CHECK=1 "${script_root}/scripts/backup-osticket.sh" check
[[ "$(metric osticket_backup_last_attempt_timestamp_seconds)" == "${old_attempt}" ]] || fail 'check was recorded as a backup'
[[ "$(metric osticket_backup_maintenance_success)" == 0 ]] || fail 'check failure metric missing'
expect_exit 0 "${script_root}/scripts/backup-osticket.sh" check
expect_exit 0 "${script_root}/scripts/backup-osticket.sh" retention
grep -Fq 'restic check --read-data' "${MOCK_TRACE}" || fail 'check did not read repository data'

before_metrics="$(sha256sum "${test_dir}/metrics/backup.prom")"
exec 8>"${test_dir}/locks/backup.lock"
flock -n 8
expect_exit 75 "${script_root}/scripts/backup-osticket.sh"
[[ "$(sha256sum "${test_dir}/metrics/backup.prom")" == "${before_metrics}" ]] || fail 'overlap changed active job metrics'
exec 8>&-
expect_exit 0 "${script_root}/scripts/run-cron.sh"
tail -n 1 "${MOCK_TRACE}" | grep -Fq 'exec -T --user www-data web php' || fail 'cron did not use the application account'
old_lines="$(wc -l < "${MOCK_TRACE}")"
exec 8>"${test_dir}/locks/cron.lock"
flock -n 8
expect_exit 0 "${script_root}/scripts/run-cron.sh"
exec 8>&-
[[ "$(wc -l < "${MOCK_TRACE}")" == "${old_lines}" ]] || fail 'overlapping cron executed'
printf "<?php\ndefine('OSTINSTALLED', FALSE);\n" > "${test_dir}/config.php"
expect_exit 0 "${script_root}/scripts/run-cron.sh"
[[ "$(wc -l < "${MOCK_TRACE}")" == "${old_lines}" ]] || fail 'cron ran before installation'
expect_exit 1 "${script_root}/scripts/backup-osticket.sh"
expect_exit 2 "${script_root}/scripts/backup-osticket.sh" unsupported
expect_exit 1 env OSTICKET_ENV_FILE="${test_dir}/missing.env" "${script_root}/scripts/compose-production.sh" ps
! grep -Fq -- "${TEST_EXPECTED_PASSWORD}" "${MOCK_TRACE}" || fail 'secret leaked into command arguments'
[[ -z "$(find "${test_dir}/stage" -maxdepth 1 -name '.*' -type f -o -name '.payload.*')" ]] || fail 'temporary payloads were not cleaned up'
printf 'Production script tests passed (archive/retention, NFS guards, failures, metrics, env, cron, locks).\n'
