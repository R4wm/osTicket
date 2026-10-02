#!/usr/bin/env bash
# Deployment .env files are trusted shell assignments and Compose env files.

OSTICKET_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

osticket_load_env() {
    local deployment_env
    if [[ -n "${OSTICKET_ENV_FILE:-}" ]]; then
        deployment_env="${OSTICKET_ENV_FILE}"
    elif [[ -f "${HOME}/osticket/.env" ]]; then
        deployment_env="${HOME}/osticket/.env"
    else
        deployment_env="/var/lib/osticket/.env"
    fi
    if [[ ! -f "${deployment_env}" ]]; then
        echo "Missing deployment env file. Copy .env.example and set OSTICKET_ENV_FILE." >&2
        return 1
    fi
    deployment_env="$(realpath "${deployment_env}")"
    set -a
    # shellcheck disable=SC1090
    source "${deployment_env}"
    set +a
    export OSTICKET_ENV_FILE="${deployment_env}"
    OSTICKET_STATE_DIR="${OSTICKET_STATE_DIR:-$(dirname "${deployment_env}")}"
    export OSTICKET_STATE_DIR
}

osticket_compose_file() {
    case "${OSTICKET_COMPOSE_FILE:-docker-compose.production.yml}" in
        /*) printf '%s\n' "${OSTICKET_COMPOSE_FILE}" ;;
        *) printf '%s/%s\n' "${OSTICKET_SCRIPT_ROOT}" "${OSTICKET_COMPOSE_FILE:-docker-compose.production.yml}" ;;
    esac
}

osticket_is_installed() {
    [[ -f "${OSTICKET_CONFIG_PATH:?Set OSTICKET_CONFIG_PATH}" ]] &&
        grep -Eq "^[[:space:]]*define[[:space:]]*\([[:space:]]*['\"]OSTINSTALLED['\"][[:space:]]*,[[:space:]]*[Tt][Rr][Uu][Ee][[:space:]]*\)" "${OSTICKET_CONFIG_PATH}"
}
