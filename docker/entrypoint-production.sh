#!/bin/bash
set -euo pipefail

APP_ROOT="/var/www/html/ticket"

if [[ ! -f "${APP_ROOT}/index.php" ]]; then
    echo "FATAL: missing ${APP_ROOT}/index.php (expected production layout under /ticket)." >&2
    exit 1
fi

if [[ -e "/var/www/html/.git" || -e "${APP_ROOT}/.git" ]]; then
    echo "FATAL: git metadata suggests a dev bind mount on a production image." >&2
    exit 1
fi
cd "${APP_ROOT}"

config_file="${APP_ROOT}/include/ost-config.php"
if [[ ! -f "${config_file}" || ! -s "${config_file}" || ! -r "${config_file}" ]]; then
    echo "FATAL: mount a readable, pre-seeded ost-config.php host file (not a directory)." >&2
    exit 1
fi
if ! php -l "${config_file}" >/dev/null 2>&1; then
    echo "FATAL: ost-config.php has invalid PHP syntax." >&2
    exit 1
fi
installed=false
if grep -qiE "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]OSTINSTALLED['\"][[:space:]]*,[[:space:]]*TRUE[[:space:]]*\)[[:space:]]*;" "${config_file}"; then
    installed=true
fi

mode="${OSTICKET_MODE:-production}"
if [[ "${mode}" == "auto" ]]; then
    if [[ "${installed}" == true ]]; then
        mode=production
    else
        mode=install
    fi
fi

case "${mode}" in
    install)
        if [[ "${installed}" == true ]]; then
            echo "FATAL: installed config requires production mode and a read-only bind." >&2
            exit 1
        fi
        if ! grep -qiE "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]OSTINSTALLED['\"][[:space:]]*,[[:space:]]*FALSE[[:space:]]*\)[[:space:]]*;" "${config_file}"; then
            echo "FATAL: install config must define OSTINSTALLED as FALSE." >&2
            exit 1
        fi
        chmod 0666 "${config_file}"
        ;;
    production)
        if [[ "${installed}" != true ]]; then
            echo "FATAL: production config must define OSTINSTALLED as TRUE." >&2
            exit 1
        fi
        if [[ "$(stat -c %u "${config_file}")" != 0 ]]; then
            echo "FATAL: production config must be owned by root on the host." >&2
            exit 1
        fi
        if ! awk -v path="${config_file}" '$5 == path && $6 ~ /(^|,)ro(,|$)/ { found=1 } END { exit !found }' /proc/self/mountinfo; then
            echo "FATAL: production config requires a read-only file bind; recreate the web container after hardening." >&2
            exit 1
        fi
        if ! su -s /bin/sh www-data -c 'test -r /var/www/html/ticket/include/ost-config.php'; then
            echo "FATAL: production config must be readable by www-data." >&2
            exit 1
        fi
        ;;
    *)
        echo "FATAL: OSTICKET_MODE must be install, production, or auto." >&2
        exit 1
        ;;
esac

mkdir -p include/mpdf/tmp include/mpdf/ttfontdata
chown -R www-data:www-data include/mpdf/tmp include/mpdf/ttfontdata

if [[ -n "${MYSQL_HOST:-}" ]]; then
    if [[ -z "${MYSQL_USER:-}" || -z "${MYSQL_PASSWORD:-}" ]]; then
        echo "FATAL: MYSQL_USER and MYSQL_PASSWORD are required." >&2
        exit 1
    fi
    echo "Waiting for MySQL at ${MYSQL_HOST}..."
    deadline=$((SECONDS + 60))
    until php -r '
        $host = getenv("MYSQL_HOST") ?: "db";
        $user = getenv("MYSQL_USER") ?: "";
        $pass = getenv("MYSQL_PASSWORD") ?: "";
        $db   = getenv("MYSQL_DATABASE") ?: "osticket";
        if ($user === "" || $pass === "") { exit(1); }
        mysqli_report(MYSQLI_REPORT_OFF);
        $mysqli = mysqli_init();
        $mysqli->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
        if (!@$mysqli->real_connect($host, $user, $pass, $db)) { exit(1); }
        if ($mysqli->connect_errno) { exit(1); }
        exit(0);
    '; do
        if (( SECONDS >= deadline )); then
            echo "FATAL: MySQL did not become ready within 60 seconds." >&2
            exit 1
        fi
        sleep 2
    done
    echo "MySQL is ready."
fi

exec "$@"
