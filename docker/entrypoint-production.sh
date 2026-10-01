#!/bin/bash
set -euo pipefail

APP_ROOT="/var/www/html/ticket"
cd "${APP_ROOT}"

if [[ ! -f "${APP_ROOT}/index.php" ]]; then
    echo "FATAL: missing ${APP_ROOT}/index.php (expected production layout under /ticket)." >&2
    exit 1
fi

if [[ -f "${APP_ROOT}/manage.php" && -d "/var/www/html/.git" ]]; then
    echo "WARNING: git metadata under /var/www/html suggests a dev bind mount on a production image." >&2
fi

mkdir -p include/mpdf/tmp include/mpdf/ttfontdata
chown -R www-data:www-data include/mpdf/tmp include/mpdf/ttfontdata 2>/dev/null || true

config_file="${APP_ROOT}/include/ost-config.php"
config_template="${APP_ROOT}/docker/ost-config.php"
installed=false
if [[ -f "${config_file}" ]] && grep -qE "define\('OSTINSTALLED',[\s]*TRUE\)" "${config_file}"; then
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

if [[ ! -f "${config_file}" ]]; then
    if [[ -f "${config_template}" ]]; then
        cp "${config_template}" "${config_file}"
        echo "Created include/ost-config.php from docker/ost-config.php."
    elif [[ -f include/ost-sampleconfig.php ]]; then
        cp include/ost-sampleconfig.php "${config_file}"
        echo "Created include/ost-config.php from ost-sampleconfig.php."
    else
        echo "WARNING: No config template; mount or create include/ost-config.php." >&2
    fi
fi

if [[ -f "${config_file}" ]]; then
    if [[ "${mode}" == "install" ]] || [[ "${installed}" != true ]]; then
        chmod 0666 "${config_file}" 2>/dev/null || true
    fi
fi

if [[ -n "${MYSQL_HOST:-}" ]]; then
    echo "Waiting for MySQL at ${MYSQL_HOST}..."
    until php -r '
        $host = getenv("MYSQL_HOST") ?: "db";
        $user = getenv("MYSQL_USER") ?: "";
        $pass = getenv("MYSQL_PASSWORD") ?: "";
        $db   = getenv("MYSQL_DATABASE") ?: "osticket";
        if ($user === "" || $pass === "") { exit(1); }
        $mysqli = @new mysqli($host, $user, $pass, $db);
        if ($mysqli->connect_errno) { exit(1); }
        exit(0);
    '; do
        sleep 2
    done
    echo "MySQL is ready."
fi

exec "$@"
