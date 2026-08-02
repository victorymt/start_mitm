#!/usr/bin/env bash
set -Eeuo pipefail

APP_ID="mitmweb-shellcrash"
SERVICE_NAME="mitmweb-shellcrash.service"
BROWSER_SERVICE_NAME="chromium-mitmweb-shellcrash.service"
LEGACY_SERVICE_NAME="mitmweb.service"
LEGACY_BROWSER_SERVICE_NAME="chromium-mitmweb.service"
STATE_VERSION="1"
CA_NICKNAME="mitmweb-shellcrash-ca"

declare -A ENV_OVERRIDES=()
declare -A SNAPSHOT_PATHS=()
declare -A SNAPSHOT_PRESENT=()

log() {
    printf '[mitmweb-setup] %s\n' "$*"
}

warn() {
    printf '[mitmweb-setup] WARNING: %s\n' "$*" >&2
}

die() {
    printf '[mitmweb-setup] ERROR: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

capture_environment() {
    local name
    local names=(
        MITMWEB_BIN
        SHELLCRASH_PROXY
        MITMWEB_LISTEN_HOST
        MITMWEB_PROXY_PORT
        MITMWEB_WEB_HOST
        MITMWEB_WEB_PORT
        MITMWEB_CONFDIR
        MITMWEB_ALLOW_LAN
        MITMWEB_ALLOW_REMOTE_WEB
        CHROMIUM_MITM_BIN
        CHROMIUM_MITM_HOME
        CHROMIUM_MITM_PROFILE
        CHROMIUM_MITM_URL
        CHROMIUM_NSS_DB
    )

    ENV_OVERRIDES=()
    for name in "${names[@]}"; do
        if [[ -v "${name}" ]]; then
            ENV_OVERRIDES["${name}"]="${!name}"
        fi
    done
}

set_defaults() {
    CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
    DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
        RUNTIME_HOME="${XDG_RUNTIME_DIR}/${APP_ID}"
    else
        RUNTIME_HOME="${TMPDIR:-/tmp}/${APP_ID}-${UID}"
    fi

    APP_CONFIG_DIR="${CONFIG_HOME}/${APP_ID}"
    STATE_FILE="${APP_CONFIG_DIR}/state"
    UNIT_DIR="${CONFIG_HOME}/systemd/user"
    UNIT_FILE="${UNIT_DIR}/${SERVICE_NAME}"
    LEGACY_UNIT_FILE="${UNIT_DIR}/${LEGACY_SERVICE_NAME}"
    LEGACY_UNIT_BACKUP="${LEGACY_UNIT_FILE}.migrated.bak"
    LOCK_FILE="${RUNTIME_HOME}/operation.lock"

    MITMWEB_EXECUTABLE="$(command -v mitmweb 2>/dev/null || true)"
    UPSTREAM_PROXY="http://127.0.0.1:7890"
    PROXY_HOST="127.0.0.1"
    PROXY_PORT="8080"
    WEB_HOST="127.0.0.1"
    WEB_PORT="8082"
    MITM_CONF_DIR="${APP_CONFIG_DIR}/mitmproxy"
    LAN_ENABLED="0"
    REMOTE_WEB_ENABLED="0"

    BROWSER_HOME="${DATA_HOME}/${APP_ID}/browser-home"
    CHROMIUM_PROFILE="${BROWSER_HOME}/profile"
    CHROMIUM_START_URL="http://mitm.it"
    CHROMIUM_EXECUTABLE=""

    READY_TIMEOUT="${MITMWEB_READY_TIMEOUT:-30}"
    VERIFY_URL="${MITMWEB_VERIFY_URL:-https://example.com}"
    NO_BROWSER="${MITMWEB_NO_BROWSER:-0}"
    NO_CERT_INSTALL="${MITMWEB_NO_CERT_INSTALL:-0}"

    derive_paths
    INSTALLED_CONFIG_FILE="${CONFIG_FILE}"
}

derive_paths() {
    CONFIG_FILE="${MITM_CONF_DIR}/config.yaml"
    NSS_DB="${BROWSER_HOME}/.pki/nssdb"
}

load_state() {
    local line
    local key
    local value
    local loaded_version=""

    [[ -f "${STATE_FILE}" ]] || return 0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        [[ "${line}" == *=* ]] || die "Malformed state line in ${STATE_FILE}: ${line}"
        key="${line%%=*}"
        value="${line#*=}"
        case "${key}" in
            STATE_VERSION) loaded_version="${value}" ;;
            MITMWEB_EXECUTABLE) MITMWEB_EXECUTABLE="${value}" ;;
            UPSTREAM_PROXY) UPSTREAM_PROXY="${value}" ;;
            PROXY_HOST) PROXY_HOST="${value}" ;;
            PROXY_PORT) PROXY_PORT="${value}" ;;
            WEB_HOST) WEB_HOST="${value}" ;;
            WEB_PORT) WEB_PORT="${value}" ;;
            MITM_CONF_DIR) MITM_CONF_DIR="${value}" ;;
            LAN_ENABLED) LAN_ENABLED="${value}" ;;
            REMOTE_WEB_ENABLED) REMOTE_WEB_ENABLED="${value}" ;;
            BROWSER_HOME) BROWSER_HOME="${value}" ;;
            CHROMIUM_PROFILE) CHROMIUM_PROFILE="${value}" ;;
            CHROMIUM_START_URL) CHROMIUM_START_URL="${value}" ;;
            CHROMIUM_EXECUTABLE) CHROMIUM_EXECUTABLE="${value}" ;;
            *) die "Unknown state key in ${STATE_FILE}: ${key}" ;;
        esac
    done <"${STATE_FILE}"

    [[ "${loaded_version}" == "${STATE_VERSION}" ]] ||
        die "Unsupported state version in ${STATE_FILE}: ${loaded_version:-missing}"
    derive_paths
}

has_override() {
    [[ -n "${ENV_OVERRIDES[$1]+present}" ]]
}

apply_setup_overrides() {
    if has_override MITMWEB_BIN; then
        MITMWEB_EXECUTABLE="${ENV_OVERRIDES[MITMWEB_BIN]}"
    fi
    if has_override SHELLCRASH_PROXY; then
        UPSTREAM_PROXY="${ENV_OVERRIDES[SHELLCRASH_PROXY]}"
    fi
    if has_override MITMWEB_PROXY_PORT; then
        PROXY_PORT="${ENV_OVERRIDES[MITMWEB_PROXY_PORT]}"
    fi
    if has_override MITMWEB_WEB_HOST; then
        WEB_HOST="${ENV_OVERRIDES[MITMWEB_WEB_HOST]}"
    fi
    if has_override MITMWEB_WEB_PORT; then
        WEB_PORT="${ENV_OVERRIDES[MITMWEB_WEB_PORT]}"
    fi
    if has_override MITMWEB_CONFDIR; then
        MITM_CONF_DIR="${ENV_OVERRIDES[MITMWEB_CONFDIR]}"
    fi
    if has_override CHROMIUM_MITM_BIN; then
        CHROMIUM_EXECUTABLE="${ENV_OVERRIDES[CHROMIUM_MITM_BIN]}"
    fi
    if has_override CHROMIUM_MITM_HOME; then
        BROWSER_HOME="${ENV_OVERRIDES[CHROMIUM_MITM_HOME]}"
    fi
    if has_override CHROMIUM_MITM_PROFILE; then
        CHROMIUM_PROFILE="${ENV_OVERRIDES[CHROMIUM_MITM_PROFILE]}"
    elif has_override CHROMIUM_MITM_HOME; then
        CHROMIUM_PROFILE="${BROWSER_HOME}/profile"
    fi
    if has_override CHROMIUM_MITM_URL; then
        CHROMIUM_START_URL="${ENV_OVERRIDES[CHROMIUM_MITM_URL]}"
    fi

    LAN_ENABLED="${ENV_OVERRIDES[MITMWEB_ALLOW_LAN]:-0}"
    REMOTE_WEB_ENABLED="${ENV_OVERRIDES[MITMWEB_ALLOW_REMOTE_WEB]:-0}"
    if has_override MITMWEB_LISTEN_HOST; then
        PROXY_HOST="${ENV_OVERRIDES[MITMWEB_LISTEN_HOST]}"
    elif [[ "${LAN_ENABLED}" == "1" ]]; then
        PROXY_HOST="0.0.0.0"
    else
        PROXY_HOST="127.0.0.1"
    fi

    derive_paths
    if has_override CHROMIUM_NSS_DB &&
        [[ "${ENV_OVERRIDES[CHROMIUM_NSS_DB]}" != "${NSS_DB}" ]]; then
        die "CHROMIUM_NSS_DB is no longer independent. Set CHROMIUM_MITM_HOME so Chromium uses the matching private NSS database."
    fi
}

initialize_configuration() {
    local apply_overrides="${1}"

    set_defaults
    load_state
    INSTALLED_CONFIG_FILE="${CONFIG_FILE}"
    if [[ "${apply_overrides}" == "1" ]]; then
        apply_setup_overrides
    fi
    derive_paths
}

validate_boolean() {
    [[ "$2" == "0" || "$2" == "1" ]] || die "$1 must be 0 or 1: $2"
}

validate_port() {
    [[ "$2" =~ ^[0-9]+$ ]] || die "$1 must be an integer: $2"
    ((1 <= 10#$2 && 10#$2 <= 65535)) || die "$1 is outside 1-65535: $2"
}

validate_single_line() {
    [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || die "$1 must not contain newlines."
}

validate_path() {
    local normalized

    validate_single_line "$1" "$2"
    [[ "$2" == /* ]] || die "$1 must be an absolute path: $2"
    [[ "$2" != "/" ]] || die "$1 must not be the filesystem root."
    normalized="/${2#/}/"
    [[ "${normalized}" != */../* && "${normalized}" != */./* ]] ||
        die "$1 must not contain '.' or '..' path components: $2"
}

validate_host() {
    validate_single_line "$1" "$2"
    [[ -n "$2" && ! "$2" =~ [[:space:]] ]] || die "$1 is invalid: $2"
    [[ "$2" != -* ]] || die "$1 must not start with '-': $2"
}

is_loopback_host() {
    case "$1" in
        127.0.0.1 | localhost | ::1 | \[::1\]) return 0 ;;
        *) return 1 ;;
    esac
}

validate_http_url() {
    validate_single_line "$1" "$2"
    [[ "$2" =~ ^https?://[^[:space:]]+$ ]] || die "$1 must be an http(s) URL: $2"
}

validate_configuration() {
    validate_boolean MITMWEB_ALLOW_LAN "${LAN_ENABLED}"
    validate_boolean MITMWEB_ALLOW_REMOTE_WEB "${REMOTE_WEB_ENABLED}"
    validate_boolean MITMWEB_NO_BROWSER "${NO_BROWSER}"
    validate_boolean MITMWEB_NO_CERT_INSTALL "${NO_CERT_INSTALL}"
    validate_port MITMWEB_PROXY_PORT "${PROXY_PORT}"
    validate_port MITMWEB_WEB_PORT "${WEB_PORT}"
    [[ "${PROXY_PORT}" != "${WEB_PORT}" ]] || die "Proxy and Web UI ports must differ."

    validate_host MITMWEB_LISTEN_HOST "${PROXY_HOST}"
    validate_host MITMWEB_WEB_HOST "${WEB_HOST}"
    if ! is_loopback_host "${PROXY_HOST}" && [[ "${LAN_ENABLED}" != "1" ]]; then
        die "A non-loopback proxy bind requires MITMWEB_ALLOW_LAN=1."
    fi
    if ! is_loopback_host "${WEB_HOST}" && [[ "${REMOTE_WEB_ENABLED}" != "1" ]]; then
        die "A non-loopback Web UI bind requires MITMWEB_ALLOW_REMOTE_WEB=1."
    fi

    validate_http_url SHELLCRASH_PROXY "${UPSTREAM_PROXY}"
    validate_http_url CHROMIUM_MITM_URL "${CHROMIUM_START_URL}"
    validate_http_url MITMWEB_VERIFY_URL "${VERIFY_URL}"
    validate_path XDG_CONFIG_HOME "${CONFIG_HOME}"
    validate_path XDG_DATA_HOME "${DATA_HOME}"
    validate_path runtime-directory "${RUNTIME_HOME}"
    validate_path MITMWEB_CONFDIR "${MITM_CONF_DIR}"
    validate_path CHROMIUM_MITM_HOME "${BROWSER_HOME}"
    validate_path CHROMIUM_MITM_PROFILE "${CHROMIUM_PROFILE}"
    [[ "${CHROMIUM_PROFILE}" == "${BROWSER_HOME}/"* ]] ||
        die "CHROMIUM_MITM_PROFILE must be inside CHROMIUM_MITM_HOME."

    [[ "${READY_TIMEOUT}" =~ ^[0-9]+$ ]] || die "MITMWEB_READY_TIMEOUT must be an integer."
    ((1 <= 10#${READY_TIMEOUT} && 10#${READY_TIMEOUT} <= 300)) ||
        die "MITMWEB_READY_TIMEOUT is outside 1-300: ${READY_TIMEOUT}"
}

resolve_executable() {
    local variable_name="$1"
    local display_name="$2"
    local value="${!variable_name}"
    local resolved=""

    [[ -n "${value}" ]] || die "${display_name} is not installed."
    validate_single_line "${display_name}" "${value}"
    if [[ "${value}" == */* ]]; then
        [[ "${value}" == /* && -x "${value}" ]] || die "${display_name} is not executable: ${value}"
        resolved="${value}"
    else
        resolved="$(command -v "${value}" 2>/dev/null || true)"
        [[ -n "${resolved}" ]] || die "${display_name} was not found: ${value}"
    fi
    printf -v "${variable_name}" '%s' "${resolved}"
}

find_chromium() {
    local candidate

    for candidate in chromium chromium-browser google-chrome-stable google-chrome; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            command -v "${candidate}"
            return 0
        fi
    done
    return 1
}

resolve_chromium() {
    if [[ -n "${CHROMIUM_EXECUTABLE}" ]]; then
        resolve_executable CHROMIUM_EXECUTABLE "Chromium/Chrome"
        return
    fi
    CHROMIUM_EXECUTABLE="$(find_chromium)" || die "Chromium/Chrome was not found."
}

preflight_common() {
    local command

    for command in curl install journalctl systemctl; do
        need_cmd "${command}"
    done
    systemctl --user show-environment >/dev/null || die "The systemd user manager is unavailable."
}

preflight_setup() {
    local command

    for command in cmp cp date flock grep mktemp mv sed ss systemd-analyze tail; do
        need_cmd "${command}"
    done
    preflight_common
    resolve_executable MITMWEB_EXECUTABLE mitmweb

    if [[ "${NO_BROWSER}" != "1" ]]; then
        need_cmd systemd-run
        resolve_chromium
        if [[ "${NO_CERT_INSTALL}" != "1" ]]; then
            need_cmd certutil
            need_cmd openssl
        fi
    fi
}

acquire_lock() {
    need_cmd flock
    install -d -m 700 "${RUNTIME_HOME}"
    [[ -O "${RUNTIME_HOME}" ]] || die "Runtime directory is not owned by the current user: ${RUNTIME_HOME}"
    exec {LOCK_FD}>>"${LOCK_FILE}"
    chmod 600 "${LOCK_FILE}"
    flock -n "${LOCK_FD}" || die "Another ${APP_ID} operation is already running."
}

yaml_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "${value}"
}

systemd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\$\$}"
    value="${value//%/%%}"
    printf '"%s"' "${value}"
}

render_configuration() {
    local temp_dir="$1"
    local upstream_value
    local proxy_host_value
    local web_host_value
    local executable_value
    local confdir_value

    RENDERED_CONF_DIR="${temp_dir}/mitmproxy"
    RENDERED_CONFIG_FILE="${RENDERED_CONF_DIR}/config.yaml"
    RENDERED_UNIT_FILE="${temp_dir}/${SERVICE_NAME}"
    RENDERED_STATE_FILE="${temp_dir}/state"
    mkdir -p "${RENDERED_CONF_DIR}"

    upstream_value="$(yaml_quote "upstream:${UPSTREAM_PROXY}")"
    proxy_host_value="$(yaml_quote "${PROXY_HOST}")"
    web_host_value="$(yaml_quote "${WEB_HOST}")"
    executable_value="$(systemd_quote "${MITMWEB_EXECUTABLE}")"
    confdir_value="$(systemd_quote "confdir=${MITM_CONF_DIR}")"

    cat >"${RENDERED_CONFIG_FILE}" <<EOF
# Managed by ${APP_ID}.
mode:
  - ${upstream_value}
listen_host: ${proxy_host_value}
listen_port: ${PROXY_PORT}

web_host: ${web_host_value}
web_port: ${WEB_PORT}
web_open_browser: false

block_private: false
block_global: true
showhost: true
EOF

    cat >"${RENDERED_UNIT_FILE}" <<EOF
[Unit]
Description=mitmweb via ShellCrash upstream proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PYTHONUNBUFFERED=1
UMask=0077
ExecStart=${executable_value} --set ${confdir_value} --no-web-open-browser
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF

    cat >"${RENDERED_STATE_FILE}" <<EOF
STATE_VERSION=${STATE_VERSION}
MITMWEB_EXECUTABLE=${MITMWEB_EXECUTABLE}
UPSTREAM_PROXY=${UPSTREAM_PROXY}
PROXY_HOST=${PROXY_HOST}
PROXY_PORT=${PROXY_PORT}
WEB_HOST=${WEB_HOST}
WEB_PORT=${WEB_PORT}
MITM_CONF_DIR=${MITM_CONF_DIR}
LAN_ENABLED=${LAN_ENABLED}
REMOTE_WEB_ENABLED=${REMOTE_WEB_ENABLED}
BROWSER_HOME=${BROWSER_HOME}
CHROMIUM_PROFILE=${CHROMIUM_PROFILE}
CHROMIUM_START_URL=${CHROMIUM_START_URL}
CHROMIUM_EXECUTABLE=${CHROMIUM_EXECUTABLE}
EOF
}

validate_rendered_configuration() {
    "${MITMWEB_EXECUTABLE}" --set "confdir=${RENDERED_CONF_DIR}" --options >/dev/null ||
        die "Generated mitmweb configuration is invalid."
    systemd-analyze --user verify "${RENDERED_UNIT_FILE}" >/dev/null ||
        die "Generated systemd unit is invalid."
}

install_atomic() {
    local source="$1"
    local destination="$2"
    local mode="$3"
    local temporary

    temporary="$(mktemp "${destination}.tmp.XXXXXX")"
    install -m "${mode}" "${source}" "${temporary}"
    mv -f "${temporary}" "${destination}"
    log "Installed: ${destination}"
}

snapshot_file() {
    local key="$1"
    local path="$2"
    local snapshot="${SETUP_TEMP_DIR}/snapshots/${key}"

    SNAPSHOT_PATHS["${key}"]="${path}"
    if [[ -e "${path}" || -L "${path}" ]]; then
        [[ ! -d "${path}" ]] || die "Expected a file but found a directory: ${path}"
        cp -a -- "${path}" "${snapshot}"
        SNAPSHOT_PRESENT["${key}"]="1"
    else
        SNAPSHOT_PRESENT["${key}"]="0"
    fi
}

restore_snapshot() {
    local key="$1"
    local path="${SNAPSHOT_PATHS[${key}]}"
    local snapshot="${SETUP_TEMP_DIR}/snapshots/${key}"

    mkdir -p "$(dirname "${path}")"
    if [[ "${SNAPSHOT_PRESENT[${key}]}" == "1" ]]; then
        rm -f -- "${path}"
        cp -a -- "${snapshot}" "${path}"
    else
        rm -f -- "${path}"
    fi
}

is_service_active() {
    systemctl --user is-active --quiet "$1"
}

is_service_enabled() {
    systemctl --user is-enabled --quiet "$1"
}

is_managed_legacy_unit() {
    [[ -f "${LEGACY_UNIT_FILE}" ]] || return 1
    grep -Fq 'Description=mitmweb via ShellCrash upstream proxy' "${LEGACY_UNIT_FILE}" &&
        grep -Fq -- '--no-web-open-browser' "${LEGACY_UNIT_FILE}"
}

begin_transaction() {
    mkdir -p "${SETUP_TEMP_DIR}/snapshots"
    PREVIOUS_NEW_ACTIVE="0"
    PREVIOUS_NEW_ENABLED="0"
    PREVIOUS_LEGACY_ACTIVE="0"
    PREVIOUS_LEGACY_ENABLED="0"
    LEGACY_MANAGED="0"

    is_service_active "${SERVICE_NAME}" && PREVIOUS_NEW_ACTIVE="1"
    is_service_enabled "${SERVICE_NAME}" && PREVIOUS_NEW_ENABLED="1"
    if is_managed_legacy_unit; then
        LEGACY_MANAGED="1"
        is_service_active "${LEGACY_SERVICE_NAME}" && PREVIOUS_LEGACY_ACTIVE="1"
        is_service_enabled "${LEGACY_SERVICE_NAME}" && PREVIOUS_LEGACY_ENABLED="1"
    fi

    snapshot_file config "${CONFIG_FILE}"
    snapshot_file unit "${UNIT_FILE}"
    snapshot_file state "${STATE_FILE}"
    snapshot_file legacy_unit "${LEGACY_UNIT_FILE}"
    TRANSACTION_ACTIVE="1"
}

restore_enabled_state() {
    local service="$1"
    local enabled="$2"

    if [[ "${enabled}" == "1" ]]; then
        systemctl --user enable "${service}" >/dev/null 2>&1 || true
    else
        systemctl --user disable "${service}" >/dev/null 2>&1 || true
    fi
}

rollback_setup() {
    warn "Setup failed; restoring the previous configuration and service state."
    systemctl --user stop "${SERVICE_NAME}" >/dev/null 2>&1 || true

    restore_snapshot config
    restore_snapshot unit
    restore_snapshot state
    restore_snapshot legacy_unit
    systemctl --user daemon-reload >/dev/null 2>&1 || true

    restore_enabled_state "${SERVICE_NAME}" "${PREVIOUS_NEW_ENABLED}"
    if [[ "${LEGACY_MANAGED}" == "1" ]]; then
        restore_enabled_state "${LEGACY_SERVICE_NAME}" "${PREVIOUS_LEGACY_ENABLED}"
    fi
    if [[ "${PREVIOUS_NEW_ACTIVE}" == "1" ]]; then
        systemctl --user start "${SERVICE_NAME}" >/dev/null 2>&1 ||
            warn "Could not restart the previous ${SERVICE_NAME}."
    fi
    if [[ "${PREVIOUS_LEGACY_ACTIVE}" == "1" ]]; then
        systemctl --user start "${LEGACY_SERVICE_NAME}" >/dev/null 2>&1 ||
            warn "Could not restart the previous ${LEGACY_SERVICE_NAME}."
    fi
}

setup_exit_handler() {
    local status="$1"
    trap - EXIT
    set +e
    if [[ "${TRANSACTION_ACTIVE:-0}" == "1" ]]; then
        rollback_setup
    fi
    if [[ -n "${SETUP_TEMP_DIR:-}" && -d "${SETUP_TEMP_DIR}" ]]; then
        rm -rf -- "${SETUP_TEMP_DIR}"
    fi
    exit "${status}"
}

port_in_use() {
    local port="$1"
    local listeners

    if ! listeners="$(ss -H -ltn "sport = :${port}" 2>&1)"; then
        die "Could not inspect TCP port ${port}: ${listeners}"
    fi
    [[ -n "${listeners}" ]]
}

wait_for_ports_free() {
    local attempt

    for ((attempt = 0; attempt < 30; attempt++)); do
        if ! port_in_use "${PROXY_PORT}" && ! port_in_use "${WEB_PORT}"; then
            return 0
        fi
        sleep 0.1
    done
    port_in_use "${PROXY_PORT}" && die "Port ${PROXY_PORT} is already in use."
    port_in_use "${WEB_PORT}" && die "Port ${WEB_PORT} is already in use."
    die "Configured ports did not become available."
}

url_host() {
    local host="$1"

    case "${host}" in
        0.0.0.0) host="127.0.0.1" ;;
        :: | \[::\]) host="::1" ;;
    esac
    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
        printf '[%s]' "${host}"
    else
        printf '%s' "${host}"
    fi
}

web_url() {
    printf 'http://%s:%s/' "$(url_host "${WEB_HOST}")" "${WEB_PORT}"
}

proxy_url() {
    printf 'http://%s:%s' "$(url_host "${PROXY_HOST}")" "${PROXY_PORT}"
}

redact_url_credentials() {
    local url="$1"
    local scheme
    local remainder
    local authority
    local suffix=""

    scheme="${url%%://*}://"
    remainder="${url#*://}"
    if [[ "${remainder}" == */* ]]; then
        authority="${remainder%%/*}"
        suffix="/${remainder#*/}"
    else
        authority="${remainder}"
    fi
    if [[ "${authority}" == *@* ]]; then
        authority="***@${authority##*@}"
    fi
    printf '%s%s%s' "${scheme}" "${authority}" "${suffix}"
}

prompt_value() {
    local result_name="$1"
    local label="$2"
    local current_value="$3"
    local entered_value

    printf '%s [%s]: ' "${label}" "${current_value}" >&2
    if ! IFS= read -r entered_value; then
        warn "Input ended; configuration was not applied."
        return 1
    fi
    printf -v "${result_name}" '%s' "${entered_value:-${current_value}}"
}

prompt_secret_value() {
    local result_name="$1"
    local label="$2"
    local current_value="$3"
    local entered_value

    printf '%s [current: %s; Enter keeps it]: ' \
        "${label}" "$(redact_url_credentials "${current_value}")" >&2
    if ! IFS= read -r -s entered_value; then
        printf '\n' >&2
        warn "Input ended; configuration was not applied."
        return 1
    fi
    printf '\n' >&2
    printf -v "${result_name}" '%s' "${entered_value:-${current_value}}"
}

prompt_yes_no() {
    local result_name="$1"
    local label="$2"
    local default_value="$3"
    local choice
    local hint

    validate_boolean prompt-default "${default_value}"
    if [[ "${default_value}" == "1" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    while true; do
        printf '%s [%s]: ' "${label}" "${hint}" >&2
        if ! IFS= read -r choice; then
            warn "Input ended; configuration was not applied."
            return 1
        fi
        case "${choice,,}" in
            '') printf -v "${result_name}" '%s' "${default_value}"; return 0 ;;
            y | yes) printf -v "${result_name}" '%s' 1; return 0 ;;
            n | no) printf -v "${result_name}" '%s' 0; return 0 ;;
            *) warn "Please answer yes or no." ;;
        esac
    done
}

prompt_port() {
    local result_name="$1"
    local label="$2"
    local current_value="$3"
    local candidate

    while true; do
        prompt_value candidate "${label}" "${current_value}" || return 1
        if [[ "${candidate}" =~ ^[0-9]+$ ]] &&
            ((1 <= 10#${candidate} && 10#${candidate} <= 65535)); then
            printf -v "${result_name}" '%d' "$((10#${candidate}))"
            return 0
        fi
        warn "Port must be an integer from 1 to 65535."
    done
}

prompt_http_url() {
    local result_name="$1"
    local label="$2"
    local current_value="$3"
    local secret="${4:-0}"
    local candidate

    while true; do
        if [[ "${secret}" == "1" ]]; then
            prompt_secret_value candidate "${label}" "${current_value}" || return 1
        else
            prompt_value candidate "${label}" "${current_value}" || return 1
        fi
        if [[ "${candidate}" =~ ^https?://[^[:space:]]+$ ]]; then
            printf -v "${result_name}" '%s' "${candidate}"
            return 0
        fi
        warn "Value must be an http(s) URL."
    done
}

current_autostart_state() {
    local result_name="$1"
    local enabled="0"

    if [[ -f "${STATE_FILE}" && -f "${UNIT_FILE}" ]] &&
        command -v systemctl >/dev/null 2>&1 &&
        systemctl --user is-enabled --quiet "${SERVICE_NAME}" >/dev/null 2>&1; then
        enabled="1"
    fi
    printf -v "${result_name}" '%s' "${enabled}"
}

show_configuration_summary() {
    local start_browser="$1"
    local install_ca="$2"
    local autostart="$3"
    local lan_text="disabled"
    local remote_web_text="disabled"
    local browser_text="no"
    local ca_text="no"
    local autostart_text="no"

    [[ "${LAN_ENABLED}" == "1" ]] && lan_text="enabled"
    [[ "${REMOTE_WEB_ENABLED}" == "1" ]] && remote_web_text="enabled"
    [[ "${start_browser}" == "1" ]] && browser_text="yes"
    [[ "${install_ca}" == "1" ]] && ca_text="yes"
    [[ "${autostart}" == "1" ]] && autostart_text="yes"

    printf '\nConfiguration summary:\n'
    printf '  Upstream proxy:    %s\n' "$(redact_url_credentials "${UPSTREAM_PROXY}")"
    printf '  Capture proxy:     %s:%s (LAN access %s)\n' \
        "${PROXY_HOST}" "${PROXY_PORT}" "${lan_text}"
    printf '  Web UI:            %s:%s (remote access %s)\n' \
        "${WEB_HOST}" "${WEB_PORT}" "${remote_web_text}"
    printf '  Start Chromium:    %s\n' "${browser_text}"
    printf '  Install browser CA:%s\n' " ${ca_text}"
    printf '  Chromium URL:      %s\n' "${CHROMIUM_START_URL}"
    printf '  Enable autostart:  %s\n\n' "${autostart_text}"
}

wait_until_ready() {
    local attempt
    local attempts=$((10#${READY_TIMEOUT} * 10))
    local target

    target="$(web_url)"
    for ((attempt = 0; attempt < attempts; attempt++)); do
        if systemctl --user is-failed --quiet "${SERVICE_NAME}"; then
            break
        fi
        if curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
            -o /dev/null "${target}" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done

    systemctl --user status "${SERVICE_NAME}" --no-pager || true
    journalctl --user -u "${SERVICE_NAME}" -n 30 --no-pager || true
    die "mitmweb did not become ready at ${target} within ${READY_TIMEOUT}s."
}

complete_legacy_migration() {
    [[ "${LEGACY_MANAGED}" == "1" ]] || return 0

    systemctl --user disable "${LEGACY_SERVICE_NAME}" >/dev/null 2>&1 || true
    cp -a -- "${LEGACY_UNIT_FILE}" "${LEGACY_UNIT_BACKUP}"
    rm -f -- "${LEGACY_UNIT_FILE}"
    systemctl --user daemon-reload
    warn "Migrated ${LEGACY_SERVICE_NAME}; legacy ~/.mitmproxy data and global NSS certificates were left untouched."
}

commit_setup() {
    install -d -m 700 "${APP_CONFIG_DIR}" "${MITM_CONF_DIR}"
    install -d -m 755 "${UNIT_DIR}"
    install_atomic "${RENDERED_CONFIG_FILE}" "${CONFIG_FILE}" 600
    install_atomic "${RENDERED_STATE_FILE}" "${STATE_FILE}" 600
    install_atomic "${RENDERED_UNIT_FILE}" "${UNIT_FILE}" 644

    systemctl --user daemon-reload
    systemctl --user start "${SERVICE_NAME}"
    wait_until_ready

    if [[ "${PREVIOUS_NEW_ENABLED}" == "1" ||
        ("${PREVIOUS_NEW_ENABLED}" == "0" && "${PREVIOUS_LEGACY_ENABLED}" == "1") ]]; then
        systemctl --user enable "${SERVICE_NAME}" >/dev/null
    fi
    complete_legacy_migration
    TRANSACTION_ACTIVE="0"
}

latest_web_url() {
    local url

    url="$({
        journalctl --user -u "${SERVICE_NAME}" --grep 'Web server listening at' \
            -n 1 --no-pager -o cat 2>/dev/null || true
    } | sed -n 's/.*Web server listening at \(http[^ ]*\).*/\1/p' | tail -n 1)"

    if [[ -n "${url}" ]]; then
        printf '%s\n' "${url}"
    else
        web_url
        printf '\n'
    fi
}

show_info() {
    local enabled_state

    enabled_state="$(systemctl --user is-enabled "${SERVICE_NAME}" 2>/dev/null || true)"
    printf '\n'
    printf 'Service:     %s\n' "${SERVICE_NAME}"
    printf 'Proxy:       %s\n' "$(proxy_url)"
    printf 'Upstream:    %s\n' "$(redact_url_credentials "${UPSTREAM_PROXY}")"
    printf 'Web UI:      %s\n' "$(latest_web_url)"
    printf 'Config:      %s\n' "${CONFIG_FILE}"
    printf 'CA cert:     %s/mitmproxy-ca-cert.pem\n' "${MITM_CONF_DIR}"
    printf 'Browser:     %s\n' "${CHROMIUM_PROFILE}"
    printf 'Autostart:   %s\n' "${enabled_state:-disabled}"
    printf '\n'
}

verify_proxy() {
    local ca_file="${MITM_CONF_DIR}/mitmproxy-ca-cert.pem"

    if [[ ! -f "${ca_file}" ]]; then
        warn "CA certificate has not been generated yet: ${ca_file}"
        return 1
    fi

    if curl -fsS --connect-timeout 5 --max-time 15 \
        --proxy "$(proxy_url)" \
        --cacert "${ca_file}" \
        -o /dev/null "${VERIFY_URL}"; then
        log "HTTPS proxy test passed (mitmweb -> ShellCrash -> Internet)."
        return 0
    fi

    warn "HTTPS proxy test failed for ${VERIFY_URL}. Check ShellCrash at $(redact_url_credentials "${UPSTREAM_PROXY}")."
    return 1
}

prepare_browser_directories() {
    install -d -m 700 "${BROWSER_HOME}"
    install -d -m 700 "${CHROMIUM_PROFILE}"
    install -d -m 700 "${BROWSER_HOME}/.pki" "${NSS_DB}"
}

install_chromium_ca() {
    local ca_file="${MITM_CONF_DIR}/mitmproxy-ca-cert.pem"
    local desired_fingerprint
    local installed_fingerprint=""
    local trust_attributes=""

    [[ "${NO_CERT_INSTALL}" == "1" ]] && return 0
    need_cmd certutil
    need_cmd openssl
    [[ -f "${ca_file}" ]] || die "CA certificate not found: ${ca_file}"

    prepare_browser_directories
    if [[ ! -f "${NSS_DB}/cert9.db" ]]; then
        certutil -N -d "sql:${NSS_DB}" --empty-password
    fi

    desired_fingerprint="$(openssl x509 -in "${ca_file}" -noout -fingerprint -sha256)"
    if certutil -L -d "sql:${NSS_DB}" -n "${CA_NICKNAME}" -a >/dev/null 2>&1; then
        installed_fingerprint="$(
            certutil -L -d "sql:${NSS_DB}" -n "${CA_NICKNAME}" -a 2>/dev/null |
                openssl x509 -noout -fingerprint -sha256 2>/dev/null || true
        )"
        trust_attributes="$(
            certutil -L -d "sql:${NSS_DB}" 2>/dev/null |
                awk -v name="${CA_NICKNAME}" '$1 == name {print $2}'
        )"
    fi

    if [[ "${installed_fingerprint}" == "${desired_fingerprint}" &&
        "${trust_attributes}" == "C,," ]]; then
        log "Private Chromium NSS database already trusts the current CA."
        return 0
    fi

    certutil -D -d "sql:${NSS_DB}" -n "${CA_NICKNAME}" >/dev/null 2>&1 || true
    certutil -A -d "sql:${NSS_DB}" -n "${CA_NICKNAME}" -t "C,," -i "${ca_file}"
    log "Imported the mitmproxy CA into the private Chromium NSS database: ${NSS_DB}"
}

remove_chromium_ca() {
    if command -v certutil >/dev/null 2>&1 && [[ -f "${NSS_DB}/cert9.db" ]]; then
        certutil -D -d "sql:${NSS_DB}" -n "${CA_NICKNAME}" >/dev/null 2>&1 || true
    fi
}

cleanup_stale_chromium_lock() {
    local lock="${CHROMIUM_PROFILE}/SingletonLock"
    local lock_target
    local lock_pid
    local socket=""

    [[ -L "${lock}" ]] || return 0
    lock_target="$(readlink "${lock}")"
    lock_pid="${lock_target##*-}"
    [[ "${lock_pid}" =~ ^[0-9]+$ ]] || return 0
    kill -0 "${lock_pid}" >/dev/null 2>&1 && return 0

    [[ "$(readlink "${lock}" 2>/dev/null || true)" == "${lock_target}" ]] || return 0
    socket="$(readlink "${CHROMIUM_PROFILE}/SingletonSocket" 2>/dev/null || true)"
    rm -f "${CHROMIUM_PROFILE}/SingletonLock" \
        "${CHROMIUM_PROFILE}/SingletonCookie" \
        "${CHROMIUM_PROFILE}/SingletonSocket"
    if [[ "${socket}" == /tmp/.org.chromium.Chromium.*/SingletonSocket ||
        "${socket}" == /tmp/org.chromium.Chromium.*/SingletonSocket ]]; then
        rm -f "${socket}"
        rmdir "${socket%/SingletonSocket}" 2>/dev/null || true
    fi
    log "Removed stale Chromium profile lock for PID ${lock_pid}."
}

append_desktop_environment() {
    local -n arguments_ref="$1"
    local env_name

    for env_name in DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS \
        XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XAUTHORITY \
        HYPRLAND_INSTANCE_SIGNATURE; do
        if [[ -n "${!env_name:-}" ]]; then
            arguments_ref+=(--setenv="${env_name}=${!env_name}")
        fi
    done
}

start_chromium() {
    local browser_args=()
    local run_args=()

    need_cmd systemd-run
    resolve_chromium
    prepare_browser_directories || return 1
    cleanup_stale_chromium_lock || return 1

    browser_args=(
        --user-data-dir="${CHROMIUM_PROFILE}"
        --proxy-server="$(proxy_url)"
        --proxy-bypass-list="<-loopback>"
        --disable-quic
        --no-first-run
    )
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        browser_args+=(--ozone-platform=wayland)
    fi

    if systemctl --user is-active --quiet "${BROWSER_SERVICE_NAME}"; then
        run_args=(
            systemd-run --user --wait --collect --quiet
            --property=Type=exec
            --setenv="HOME=${BROWSER_HOME}"
        )
        append_desktop_environment run_args
        if ! "${run_args[@]}" "${CHROMIUM_EXECUTABLE}" \
            --user-data-dir="${CHROMIUM_PROFILE}" "${CHROMIUM_START_URL}"; then
            warn "Could not send the URL to the running Chromium instance."
            return 1
        fi
        log "Reused the running proxied Chromium instance."
        return 0
    fi

    systemctl --user reset-failed "${BROWSER_SERVICE_NAME}" >/dev/null 2>&1 || true
    run_args=(
        systemd-run --user
        --unit="${BROWSER_SERVICE_NAME%.service}"
        --collect --quiet
        --property=Type=exec
        --setenv="HOME=${BROWSER_HOME}"
    )
    append_desktop_environment run_args
    if ! "${run_args[@]}" "${CHROMIUM_EXECUTABLE}" \
        "${browser_args[@]}" "${CHROMIUM_START_URL}"; then
        warn "Could not start the isolated Chromium service."
        return 1
    fi

    sleep 0.5
    if ! systemctl --user is-active --quiet "${BROWSER_SERVICE_NAME}"; then
        journalctl --user -u "${BROWSER_SERVICE_NAME}" -n 30 --no-pager || true
        die "Chromium did not remain active."
    fi
    log "Started an isolated Chromium profile: ${CHROMIUM_PROFILE}"
    log "Chromium start URL: ${CHROMIUM_START_URL}"
    log "Chromium CA trust store: ${NSS_DB}"
}

stop_browser_services() {
    systemctl --user stop "${BROWSER_SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl --user stop "${LEGACY_BROWSER_SERVICE_NAME}" >/dev/null 2>&1 || true
}

setup() (
    local post_status="0"

    set -Eeuo pipefail

    validate_configuration
    preflight_setup
    acquire_lock

    SETUP_TEMP_DIR="$(mktemp -d)"
    TRANSACTION_ACTIVE="0"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'setup_exit_handler $?' EXIT

    render_configuration "${SETUP_TEMP_DIR}"
    validate_rendered_configuration
    begin_transaction

    systemctl --user stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
    if [[ "${LEGACY_MANAGED}" == "1" ]]; then
        systemctl --user stop "${LEGACY_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    wait_for_ports_free
    commit_setup

    stop_browser_services
    log "Service configuration committed successfully."

    if ! verify_proxy; then
        post_status="1"
    fi
    if [[ "${NO_BROWSER}" != "1" ]]; then
        if [[ "${NO_CERT_INSTALL}" != "1" ]]; then
            install_chromium_ca
        fi
        if ! start_chromium; then
            post_status="1"
        fi
    fi

    show_info
    if [[ "${post_status}" != "0" ]]; then
        warn "Setup completed, but one or more post-install checks failed."
        return "${post_status}"
    fi
    log "Setup complete."
)

installation_state() {
    local present="0"
    local path
    local paths=("${STATE_FILE}" "${INSTALLED_CONFIG_FILE}" "${UNIT_FILE}")

    for path in "${paths[@]}"; do
        [[ -f "${path}" ]] && present="$((present + 1))"
    done
    case "${present}" in
        0) printf 'absent\n' ;;
        3) printf 'installed\n' ;;
        *) printf 'incomplete\n' ;;
    esac
}

require_installed() {
    case "$(installation_state)" in
        installed) return 0 ;;
        incomplete)
            die "${APP_ID} installation is incomplete. Run '$0 setup' to repair it or '$0 uninstall' to remove it."
            ;;
        *) die "${APP_ID} is not installed. Run '$0 setup' first." ;;
    esac
}

start_service() {
    require_installed
    preflight_common
    acquire_lock
    systemctl --user start "${SERVICE_NAME}"
    wait_until_ready
    show_info
}

restart_service() {
    require_installed
    preflight_common
    acquire_lock
    systemctl --user restart "${SERVICE_NAME}"
    wait_until_ready
    verify_proxy
    show_info
}

stop_service() {
    require_installed
    need_cmd systemctl
    acquire_lock
    stop_browser_services
    systemctl --user stop "${SERVICE_NAME}"
    log "mitmweb and its isolated Chromium instance stopped."
}

status_service() {
    local status="0"

    require_installed
    need_cmd systemctl
    if systemctl --user status "${SERVICE_NAME}" --no-pager; then
        status="0"
    else
        status="$?"
    fi
    systemctl --user status "${BROWSER_SERVICE_NAME}" --no-pager || true
    show_info
    return "${status}"
}

show_logs() {
    require_installed
    need_cmd journalctl
    journalctl --user -u "${SERVICE_NAME}" -n 50 --no-pager
    journalctl --user -u "${BROWSER_SERVICE_NAME}" -n 30 --no-pager || true
}

launch_browser() {
    require_installed
    validate_http_url CHROMIUM_MITM_URL "${CHROMIUM_START_URL}"
    preflight_common
    acquire_lock
    if ! systemctl --user is-active --quiet "${SERVICE_NAME}"; then
        systemctl --user start "${SERVICE_NAME}"
        wait_until_ready
    fi
    if [[ "${NO_CERT_INSTALL}" != "1" ]]; then
        install_chromium_ca
    fi
    start_chromium
    show_info
}

enable_service() {
    require_installed
    need_cmd systemctl
    acquire_lock
    systemctl --user enable "${SERVICE_NAME}"
    log "Autostart enabled for ${SERVICE_NAME}."
}

disable_service() {
    require_installed
    need_cmd systemctl
    acquire_lock
    systemctl --user disable "${SERVICE_NAME}"
    log "Autostart disabled for ${SERVICE_NAME}."
}

configure_interactive() {
    local previous_lan="${LAN_ENABLED}"
    local previous_remote_web="${REMOTE_WEB_ENABLED}"
    local start_browser="1"
    local install_ca="1"
    local autostart="0"
    local confirmed="0"
    local setup_status="0"
    local autostart_status="0"

    [[ "${NO_BROWSER}" == "1" ]] && start_browser="0"
    [[ "${NO_CERT_INSTALL}" == "1" ]] && install_ca="0"
    current_autostart_state autostart

    printf 'Interactive mitmweb configuration\n'
    printf 'Press Enter to keep the value shown in brackets.\n\n'
    prompt_http_url UPSTREAM_PROXY "Upstream HTTP(S) proxy" "${UPSTREAM_PROXY}" 1
    prompt_port PROXY_PORT "Capture proxy port" "${PROXY_PORT}"
    prompt_port WEB_PORT "Web UI port" "${WEB_PORT}"
    while [[ "${WEB_PORT}" == "${PROXY_PORT}" ]]; do
        warn "The Web UI port must differ from the capture proxy port."
        prompt_port WEB_PORT "Web UI port" "${WEB_PORT}"
    done

    prompt_yes_no LAN_ENABLED "Allow capture proxy access from the LAN" "${LAN_ENABLED}"
    if [[ "${LAN_ENABLED}" == "0" ]]; then
        PROXY_HOST="127.0.0.1"
    elif [[ "${previous_lan}" == "0" ]] || is_loopback_host "${PROXY_HOST}"; then
        PROXY_HOST="0.0.0.0"
    fi

    prompt_yes_no REMOTE_WEB_ENABLED "Allow remote access to the Web UI" "${REMOTE_WEB_ENABLED}"
    if [[ "${REMOTE_WEB_ENABLED}" == "0" ]]; then
        WEB_HOST="127.0.0.1"
    elif [[ "${previous_remote_web}" == "0" ]] || is_loopback_host "${WEB_HOST}"; then
        WEB_HOST="0.0.0.0"
    fi

    prompt_yes_no start_browser "Start an isolated Chromium after setup" "${start_browser}"
    if [[ "${start_browser}" == "1" ]]; then
        prompt_yes_no install_ca "Trust the mitmproxy CA in that Chromium profile" "${install_ca}"
        prompt_http_url CHROMIUM_START_URL "Chromium start URL" "${CHROMIUM_START_URL}"
    else
        install_ca="0"
    fi
    prompt_yes_no autostart "Enable mitmweb autostart for this user" "${autostart}"

    NO_BROWSER="$((1 - start_browser))"
    NO_CERT_INSTALL="$((1 - install_ca))"
    validate_configuration
    show_configuration_summary "${start_browser}" "${install_ca}" "${autostart}"
    prompt_yes_no confirmed "Apply this configuration" 0
    if [[ "${confirmed}" != "1" ]]; then
        log "Configuration cancelled; no changes were made."
        return 0
    fi

    if setup; then
        setup_status="0"
    else
        setup_status="$?"
    fi

    if [[ -f "${STATE_FILE}" && -f "${UNIT_FILE}" ]]; then
        if [[ "${autostart}" == "1" ]]; then
            if ! (enable_service); then
                autostart_status="1"
            fi
        elif ! (disable_service); then
            autostart_status="1"
        fi
    fi

    if [[ "${setup_status}" != "0" ]]; then
        return "${setup_status}"
    fi
    return "${autostart_status}"
}

configure_command() {
    [[ -t 0 && -t 1 ]] ||
        die "'configure' requires an interactive terminal. Use 'setup' for non-interactive installation."
    configure_interactive
}

doctor() {
    local status="0"
    local command
    local commands=(curl install journalctl systemctl ss systemd-analyze flock)

    validate_configuration
    for command in "${commands[@]}"; do
        if command -v "${command}" >/dev/null 2>&1; then
            log "Found: ${command}"
        else
            warn "Missing: ${command}"
            status="1"
        fi
    done
    if [[ -n "${MITMWEB_EXECUTABLE}" && -x "${MITMWEB_EXECUTABLE}" ]]; then
        log "Found mitmweb: ${MITMWEB_EXECUTABLE}"
    else
        warn "mitmweb is unavailable: ${MITMWEB_EXECUTABLE:-not found}"
        status="1"
    fi
    if [[ "${NO_BROWSER}" != "1" ]]; then
        if CHROMIUM_EXECUTABLE="$(find_chromium)"; then
            log "Found Chromium: ${CHROMIUM_EXECUTABLE}"
        else
            warn "Chromium/Chrome was not found."
            status="1"
        fi
    fi
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        warn "The systemd user manager is unavailable."
        status="1"
    fi
    case "$(installation_state)" in
        installed) log "Installed state: ${STATE_FILE}" ;;
        incomplete)
            warn "Installation files are incomplete. Run '$0 setup' to repair them or '$0 uninstall' to remove them."
            status="1"
            ;;
        absent) log "No installed state found; doctor checked setup defaults." ;;
    esac
    return "${status}"
}

path_is_within() {
    [[ "$1" == "$2" || "$1" == "$2/"* ]]
}

uninstall_service() {
    local default_browser_root="${DATA_HOME}/${APP_ID}"

    need_cmd systemctl
    acquire_lock
    stop_browser_services
    systemctl --user disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    if is_managed_legacy_unit; then
        systemctl --user disable --now "${LEGACY_SERVICE_NAME}" >/dev/null 2>&1 || true
        rm -f -- "${LEGACY_UNIT_FILE}"
        warn "Removed the legacy managed ${LEGACY_SERVICE_NAME}; its global mitmproxy and NSS data were retained."
    fi
    remove_chromium_ca

    rm -f -- "${UNIT_FILE}"
    rm -f -- "${LEGACY_UNIT_BACKUP}"
    if path_is_within "${MITM_CONF_DIR}" "${APP_CONFIG_DIR}"; then
        [[ "${APP_CONFIG_DIR}" == "${CONFIG_HOME}/${APP_ID}" ]] || die "Refusing to remove an unexpected config directory."
        rm -rf -- "${APP_CONFIG_DIR}"
    else
        rm -f -- "${CONFIG_FILE}"
        rm -f -- "${STATE_FILE}"
        warn "Custom mitmproxy directory retained: ${MITM_CONF_DIR}"
        rmdir "${APP_CONFIG_DIR}" 2>/dev/null || true
    fi
    if path_is_within "${BROWSER_HOME}" "${default_browser_root}"; then
        [[ "${default_browser_root}" == "${DATA_HOME}/${APP_ID}" ]] || die "Refusing to remove an unexpected browser directory."
        rm -rf -- "${default_browser_root}"
    else
        warn "Custom Chromium home retained: ${BROWSER_HOME}"
    fi
    systemctl --user daemon-reload
    systemctl --user reset-failed "${SERVICE_NAME}" "${BROWSER_SERVICE_NAME}" >/dev/null 2>&1 || true
    log "Uninstalled ${APP_ID}. Legacy global mitmproxy and NSS data were not modified."
}

usage() {
    cat <<'EOF'
Usage: ./setup_mitmweb.sh [command]

Commands:
  setup      Non-interactively install/reconfigure using environment values
  configure  Interactively configure, review, and install mitmweb
  start      Start mitmweb without changing its autostart state
  stop       Stop mitmweb and its isolated Chromium instance
  restart    Restart mitmweb and strictly verify the proxy chain
  status     Show service status and installed settings
  logs       Show recent mitmweb and Chromium service logs
  browser [URL]
             Start or reuse isolated Chromium through mitmweb
  verify     Verify HTTPS through mitmweb and ShellCrash
  enable     Enable user-session autostart
  disable    Disable user-session autostart
  doctor     Validate dependencies and configuration without changing state
  uninstall  Remove files and services managed by this script
  help       Show this help

Setup environment overrides:
  MITMWEB_BIN              mitmweb executable
  SHELLCRASH_PROXY         Upstream HTTP(S) proxy
  MITMWEB_PROXY_PORT       Capture proxy port (default: 8080)
  MITMWEB_WEB_PORT         Web UI port (default: 8082)
  MITMWEB_LISTEN_HOST      Capture bind address (default: 127.0.0.1)
  MITMWEB_WEB_HOST         Web UI bind address (default: 127.0.0.1)
  MITMWEB_CONFDIR          Dedicated mitmproxy config and CA directory
  MITMWEB_ALLOW_LAN        Set to 1 before using a non-loopback proxy bind
  MITMWEB_ALLOW_REMOTE_WEB Set to 1 before using a non-loopback Web UI bind
  CHROMIUM_MITM_BIN        Chromium/Chrome executable
  CHROMIUM_MITM_HOME       Private browser HOME and NSS root
  CHROMIUM_MITM_PROFILE    Profile path inside CHROMIUM_MITM_HOME
  CHROMIUM_MITM_URL        Browser start URL (default: http://mitm.it)

Runtime overrides:
  MITMWEB_READY_TIMEOUT    Service readiness timeout in seconds (default: 30)
  MITMWEB_VERIFY_URL       HTTPS URL used by verify
  MITMWEB_NO_BROWSER       Set to 1 to skip Chromium during setup
  MITMWEB_NO_CERT_INSTALL  Set to 1 to skip Chromium CA installation

Notes:
  configure requires a terminal and uses installed settings as defaults.
  setup never prompts, so it is suitable for scripts and automation.
  After a power loss or SIGKILL during installation, run setup again to repair.
EOF
}

require_argument_count() {
    local expected="$1"
    local command="$2"
    local actual="$3"
    [[ "${actual}" == "${expected}" ]] || die "Invalid arguments for '${command}'. See '$0 help'."
}

main() {
    local command="${1:-setup}"
    local argument_count="$#"
    local current_installation_state

    case "${command}" in
        help | -h | --help)
            usage
            return 0
            ;;
        setup | configure | start | stop | restart | status | logs | browser | verify | enable | disable | doctor | uninstall) ;;
        *) usage >&2; die "Unknown command: ${command}" ;;
    esac

    capture_environment
    case "${command}" in
        setup | doctor) initialize_configuration 1 ;;
        *) initialize_configuration 0 ;;
    esac
    validate_configuration

    current_installation_state="$(installation_state)"
    if [[ "${current_installation_state}" == "incomplete" ]]; then
        case "${command}" in
            setup | configure)
                warn "Incomplete installation detected; ${command} will repair it."
                ;;
            doctor) ;;
            uninstall)
                warn "Incomplete installation detected; uninstall will remove the remaining managed files."
                ;;
            *)
                die "${APP_ID} installation is incomplete. Run '$0 setup' to repair it or '$0 uninstall' to remove it."
                ;;
        esac
    fi

    case "${command}" in
        setup)
            ((argument_count <= 1)) || die "Invalid arguments for 'setup'. See '$0 help'."
            setup
            ;;
        configure)
            require_argument_count 1 configure "${argument_count}"
            configure_command
            ;;
        start)
            require_argument_count 1 start "${argument_count}"
            start_service
            ;;
        stop)
            require_argument_count 1 stop "${argument_count}"
            stop_service
            ;;
        restart)
            require_argument_count 1 restart "${argument_count}"
            restart_service
            ;;
        status)
            require_argument_count 1 status "${argument_count}"
            status_service
            ;;
        logs)
            require_argument_count 1 logs "${argument_count}"
            show_logs
            ;;
        browser)
            ((argument_count <= 2)) || die "browser accepts at most one URL."
            if [[ -n "${2:-}" ]]; then
                CHROMIUM_START_URL="$2"
            fi
            launch_browser
            ;;
        verify)
            require_argument_count 1 verify "${argument_count}"
            require_installed
            verify_proxy
            ;;
        enable)
            require_argument_count 1 enable "${argument_count}"
            enable_service
            ;;
        disable)
            require_argument_count 1 disable "${argument_count}"
            disable_service
            ;;
        doctor)
            require_argument_count 1 doctor "${argument_count}"
            doctor
            ;;
        uninstall)
            require_argument_count 1 uninstall "${argument_count}"
            uninstall_service
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
