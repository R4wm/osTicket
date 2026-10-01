#!/bin/bash
set -euo pipefail

mkdir -p include/mpdf/tmp include/mpdf/ttfontdata
chown -R www-data:www-data include/mpdf/tmp include/mpdf/ttfontdata 2>/dev/null || true

config_template="docker/ost-config.php"
config_file="include/ost-config.php"
if [[ ! -f "${config_file}" ]]; then
    if [[ -f "${config_template}" ]]; then
        cp "${config_template}" "${config_file}"
        echo "Created ${config_file} from ${config_template}."
    elif [[ -f include/ost-sampleconfig.php ]]; then
        cp include/ost-sampleconfig.php "${config_file}"
        echo "Created ${config_file} from include/ost-sampleconfig.php."
    else
        echo "WARNING: No osTicket config template found; installer will fail." >&2
    fi
fi
if [[ -f "${config_file}" ]]; then
    chmod 0666 "${config_file}"
    chown www-data:www-data "${config_file}" 2>/dev/null || true
fi

if [[ -n "${MYSQL_HOST:-}" ]]; then
    echo "Waiting for MySQL at ${MYSQL_HOST}..."
    until php -r '
        $host = getenv("MYSQL_HOST") ?: "db";
        $user = getenv("MYSQL_USER") ?: "osticket";
        $pass = getenv("MYSQL_PASSWORD") ?: "osticket";
        $db   = getenv("MYSQL_DATABASE") ?: "osticket";
        $mysqli = @new mysqli($host, $user, $pass, $db);
        if ($mysqli->connect_errno) {
            exit(1);
        }
        exit(0);
    '; do
        sleep 2
    done
    echo "MySQL is ready."
fi

exec "$@"
