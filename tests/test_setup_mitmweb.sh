#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${SCRIPT_DIR}/setup_mitmweb.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0

cleanup() {
    rm -rf -- "${TEST_ROOT}"
}
trap cleanup EXIT

export XDG_CONFIG_HOME="${TEST_ROOT}/config"
export XDG_DATA_HOME="${TEST_ROOT}/data"
export XDG_RUNTIME_DIR="${TEST_ROOT}/runtime"
mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_RUNTIME_DIR}"

# shellcheck disable=SC1090
source "${SCRIPT}"

fail() {
    printf 'not ok %d - %s\n' "${TESTS_RUN}" "$1" >&2
    return 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    [[ "${actual}" == "${expected}" ]] ||
        fail "${message}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
    local file="$1"
    local expected="$2"
    local message="$3"

    grep -Fq -- "${expected}" "${file}" || fail "${message}: ${expected}"
}

run_test() {
    local name="$1"
    local status
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    set +e
    (set -Eeuo pipefail; "$@")
    status="$?"
    set -e
    if [[ "${status}" == "0" ]]; then
        printf 'ok %d - %s\n' "${TESTS_RUN}" "${name}"
    else
        fail "${name}"
    fi
}

reset_configuration() {
    # Values are consumed by functions loaded dynamically from the main script.
    # shellcheck disable=SC2034
    ENV_OVERRIDES=()
    set_defaults
    # shellcheck disable=SC2034
    NO_BROWSER="1"
    # shellcheck disable=SC2034
    NO_CERT_INSTALL="1"
}

test_safe_defaults() {
    reset_configuration
    assert_equal "127.0.0.1" "${PROXY_HOST}" "proxy must be loopback by default"
    assert_equal "mitmweb-shellcrash.service" "${SERVICE_NAME}" "service name must be unique"
    assert_equal "${APP_CONFIG_DIR}/mitmproxy" "${MITM_CONF_DIR}" "mitmproxy config must be private"
    assert_equal "${BROWSER_HOME}/.pki/nssdb" "${NSS_DB}" "NSS database must follow browser HOME"
    [[ "${CONFIG_FILE}" != "${HOME}/.mitmproxy/config.yaml" ]] ||
        fail "global mitmproxy config must not be used"
}

test_quoting_helpers() {
    local yaml_value
    local unit_value

    yaml_value="$(yaml_quote "a'b")"
    unit_value="$(systemd_quote "a%b\$c\"d\\e")"
    assert_equal "'a''b'" "${yaml_value}" "YAML single-quote escaping"
    assert_equal "\"a%%b\$\$c\\\"d\\\\e\"" "${unit_value}" "systemd escaping"
}

test_proxy_credentials_are_redacted() {
    local redacted

    redacted="$(redact_url_credentials 'http://user:secret@127.0.0.1:7890/path?q=1')"
    assert_equal 'http://***@127.0.0.1:7890/path?q=1' "${redacted}" \
        "proxy credentials must not be printed"
}

test_interactive_prompt_validation() {
    local answer=""
    local port=""

    prompt_yes_no answer "Continue" 0 <<< $'maybe\nyes' 2>/dev/null
    assert_equal "1" "${answer}" "yes/no prompt must retry invalid input"
    prompt_yes_no answer "Continue" 1 <<< '' 2>/dev/null
    assert_equal "1" "${answer}" "yes/no prompt must accept the default"
    prompt_port port "Port" 8080 <<< $'0\n70000\n08081' 2>/dev/null
    assert_equal "8081" "${port}" "port prompt must validate and normalize input"
}

test_configuration_summary_redacts_credentials() {
    local output

    reset_configuration
    UPSTREAM_PROXY='http://user:secret@127.0.0.1:7890/path'
    output="$(show_configuration_summary 1 1 0)"
    [[ "${output}" != *'secret'* ]] || fail "configuration summary leaked a proxy password"
    [[ "${output}" == *'http://***@127.0.0.1:7890/path'* ]] ||
        fail "configuration summary did not show a redacted proxy"
}

test_configure_cancel_has_no_writes() {
    local mock_dir="${TEST_ROOT}/configure-cancel"

    export XDG_CONFIG_HOME="${mock_dir}/config"
    export XDG_DATA_HOME="${mock_dir}/data"
    export XDG_RUNTIME_DIR="${mock_dir}/runtime"
    reset_configuration

    configure_interactive <<< $'\n\n\n\n\n\n\n\n\n' >/dev/null 2>&1
    [[ ! -e "${STATE_FILE}" ]] || fail "cancelled configure created a state file"
    [[ ! -e "${UNIT_FILE}" ]] || fail "cancelled configure created a unit"
    [[ ! -e "${CONFIG_FILE}" ]] || fail "cancelled configure created a config"
}

test_configure_command_requires_tty() {
    local mock_dir="${TEST_ROOT}/configure-no-tty"

    export XDG_CONFIG_HOME="${mock_dir}/config"
    export XDG_DATA_HOME="${mock_dir}/data"
    export XDG_RUNTIME_DIR="${mock_dir}/runtime"
    reset_configuration
    if (configure_command </dev/null) >/dev/null 2>&1; then
        fail "configure command must reject non-interactive input"
    fi
}

test_configure_applies_autostart_after_post_failure() {
    local mock_dir="${TEST_ROOT}/configure-post-failure"
    local status

    export XDG_CONFIG_HOME="${mock_dir}/config"
    export XDG_DATA_HOME="${mock_dir}/data"
    export XDG_RUNTIME_DIR="${mock_dir}/runtime"
    reset_configuration
    # Values are read dynamically by configure_interactive from the sourced script.
    # shellcheck disable=SC2034
    NO_BROWSER="0"
    NO_CERT_INSTALL="0"

    # shellcheck disable=SC2329
    setup() {
        mkdir -p "${APP_CONFIG_DIR}" "${UNIT_DIR}"
        : >"${STATE_FILE}"
        : >"${UNIT_FILE}"
        return 1
    }
    # shellcheck disable=SC2329
    enable_service() {
        : >"${mock_dir}/autostart-enabled"
    }

    set +e
    configure_interactive <<< $'\n\n\n\n\n\n\n\ny\ny' >/dev/null 2>&1
    status="$?"
    set -e
    [[ "${status}" == "1" ]] || fail "configure must retain the setup failure status"
    [[ -f "${mock_dir}/autostart-enabled" ]] ||
        fail "configure did not apply autostart after a post-install failure"
}

test_render_and_validate() {
    local render_root="${TEST_ROOT}/render-default"

    reset_configuration
    resolve_executable MITMWEB_EXECUTABLE mitmweb
    validate_configuration
    mkdir -p "${render_root}"
    render_configuration "${render_root}"
    # shellcheck disable=SC2329
    systemd-analyze() {
        return 0
    }
    validate_rendered_configuration
    unset -f systemd-analyze

    assert_file_contains "${RENDERED_CONFIG_FILE}" "'upstream:http://127.0.0.1:7890'" \
        "upstream must be YAML quoted"
    assert_file_contains "${RENDERED_UNIT_FILE}" "--set \"confdir=${MITM_CONF_DIR}\"" \
        "unit must pass the final confdir"
}

test_special_systemd_path() {
    local render_root="${TEST_ROOT}/render-special"

    reset_configuration
    resolve_executable MITMWEB_EXECUTABLE mitmweb
    MITM_CONF_DIR="${TEST_ROOT}/conf dir-%-\$literal"
    derive_paths
    validate_configuration
    mkdir -p "${render_root}"
    render_configuration "${render_root}"
    # shellcheck disable=SC2329
    systemd-analyze() {
        return 0
    }
    validate_rendered_configuration
    unset -f systemd-analyze
    assert_file_contains "${RENDERED_UNIT_FILE}" 'confdir=' "custom confdir must be rendered"
    assert_file_contains "${RENDERED_UNIT_FILE}" '%%' "systemd percent must be escaped"
    assert_file_contains "${RENDERED_UNIT_FILE}" "\$\$literal" "systemd dollar must be escaped"
}

test_state_round_trip() {
    local render_root="${TEST_ROOT}/render-state"
    local expected_proxy="http://user:pass@127.0.0.1:7890/?a=b=c"

    reset_configuration
    resolve_executable MITMWEB_EXECUTABLE mitmweb
    UPSTREAM_PROXY="${expected_proxy}"
    mkdir -p "${render_root}" "${APP_CONFIG_DIR}"
    render_configuration "${render_root}"
    install -m 600 "${RENDERED_STATE_FILE}" "${STATE_FILE}"

    UPSTREAM_PROXY="invalid"
    load_state
    assert_equal "${expected_proxy}" "${UPSTREAM_PROXY}" "state values containing equals signs"
}

test_invalid_profile_is_rejected() {
    reset_configuration
    # shellcheck disable=SC2034
    CHROMIUM_PROFILE="${TEST_ROOT}/outside-profile"
    if (validate_configuration) >/dev/null 2>&1; then
        fail "profile outside browser HOME should fail validation"
    fi
}

test_parent_path_is_rejected() {
    reset_configuration
    MITM_CONF_DIR="${TEST_ROOT}/managed/../escape"
    derive_paths
    if (validate_configuration) >/dev/null 2>&1; then
        fail "paths containing '..' should fail validation"
    fi
}

test_invalid_mitmproxy_yaml_is_rejected() {
    local render_root="${TEST_ROOT}/render-invalid"

    reset_configuration
    resolve_executable MITMWEB_EXECUTABLE mitmweb
    mkdir -p "${render_root}"
    render_configuration "${render_root}"
    printf 'invalid_yaml: [unterminated\n' >>"${RENDERED_CONFIG_FILE}"
    # shellcheck disable=SC2329
    systemd-analyze() {
        return 0
    }
    if (validate_rendered_configuration) >/dev/null 2>&1; then
        unset -f systemd-analyze
        fail "invalid mitmproxy YAML should fail rendered validation"
    fi
    unset -f systemd-analyze
}

test_verify_failure_is_nonzero() {
    reset_configuration
    mkdir -p "${MITM_CONF_DIR}"
    : >"${MITM_CONF_DIR}/mitmproxy-ca-cert.pem"
    # shellcheck disable=SC2329
    curl() {
        return 22
    }
    if verify_proxy >/dev/null 2>&1; then
        unset -f curl
        fail "verify_proxy must fail when curl fails"
    fi
    unset -f curl
}

test_installation_consistency_state() {
    local mock_dir="${TEST_ROOT}/consistency"
    local output
    local status

    export XDG_CONFIG_HOME="${mock_dir}/config"
    export XDG_DATA_HOME="${mock_dir}/data"
    export XDG_RUNTIME_DIR="${mock_dir}/runtime"
    reset_configuration

    assert_equal "absent" "$(installation_state)" "empty installation state"
    mkdir -p "${APP_CONFIG_DIR}"
    : >"${STATE_FILE}"
    assert_equal "incomplete" "$(installation_state)" "partial installation state"
    set +e
    output="$(require_installed 2>&1)"
    status="$?"
    set -e
    [[ "${status}" != "0" ]] || fail "incomplete installation must fail management commands"
    [[ "${output}" == *"setup"* && "${output}" == *"uninstall"* ]] ||
        fail "incomplete installation did not provide repair instructions"
    mkdir -p "${MITM_CONF_DIR}" "${UNIT_DIR}"
    : >"${CONFIG_FILE}"
    : >"${UNIT_FILE}"
    assert_equal "installed" "$(installation_state)" "complete installation state"
}

test_setup_transaction_rolls_back() {
    local failed_status
    local mock_dir="${TEST_ROOT}/transaction"

    export XDG_CONFIG_HOME="${mock_dir}/config"
    export XDG_DATA_HOME="${mock_dir}/data"
    export XDG_RUNTIME_DIR="${mock_dir}/runtime"
    mkdir -p "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_RUNTIME_DIR}" "${mock_dir}/service-state"

    # shellcheck disable=SC2329
    systemctl() {
        local action
        local service=""

        [[ "${1:-}" == "--user" ]] && shift
        action="${1:-}"
        shift || true
        case "${action}" in
            show-environment | daemon-reload | reset-failed) return 0 ;;
            is-active)
                [[ "${1:-}" == "--quiet" ]] && shift
                service="${1:-}"
                [[ -f "${mock_dir}/service-state/active-${service}" ]]
                ;;
            is-enabled)
                [[ "${1:-}" == "--quiet" ]] && shift
                service="${1:-}"
                [[ -f "${mock_dir}/service-state/enabled-${service}" ]]
                ;;
            is-failed) return 1 ;;
            start)
                service="${1:-}"
                if [[ "${service}" == "${SERVICE_NAME}" && -f "${mock_dir}/fail-next-start" ]]; then
                    rm -f "${mock_dir}/fail-next-start"
                    return 1
                fi
                : >"${mock_dir}/service-state/active-${service}"
                if [[ "${service}" == "${SERVICE_NAME}" ]]; then
                    mkdir -p "${MITM_CONF_DIR}"
                    : >"${MITM_CONF_DIR}/mitmproxy-ca-cert.pem"
                fi
                ;;
            stop)
                service="${1:-}"
                rm -f "${mock_dir}/service-state/active-${service}"
                ;;
            enable)
                service="${1:-}"
                : >"${mock_dir}/service-state/enabled-${service}"
                ;;
            disable)
                service="${1:-}"
                rm -f "${mock_dir}/service-state/enabled-${service}"
                ;;
            status) return 0 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2329
    systemd-analyze() {
        return 0
    }
    # shellcheck disable=SC2329
    journalctl() {
        return 0
    }
    # shellcheck disable=SC2329
    ss() {
        return 0
    }
    # shellcheck disable=SC2329
    flock() {
        return 0
    }
    # shellcheck disable=SC2329
    curl() {
        printf '200'
    }

    reset_configuration
    resolve_executable MITMWEB_EXECUTABLE mitmweb
    setup >/dev/null 2>&1
    [[ ! -f "${mock_dir}/service-state/enabled-${SERVICE_NAME}" ]] ||
        fail "fresh setup must not enable autostart"
    cp -a "${CONFIG_FILE}" "${mock_dir}/original-config"
    cp -a "${STATE_FILE}" "${mock_dir}/original-state"
    cp -a "${UNIT_FILE}" "${mock_dir}/original-unit"

    : >"${mock_dir}/service-state/enabled-${SERVICE_NAME}"
    setup >/dev/null 2>&1
    cmp -s "${CONFIG_FILE}" "${mock_dir}/original-config" ||
        fail "repeated setup changed the rendered config"
    cmp -s "${STATE_FILE}" "${mock_dir}/original-state" ||
        fail "repeated setup changed the rendered state"
    cmp -s "${UNIT_FILE}" "${mock_dir}/original-unit" ||
        fail "repeated setup changed the rendered unit"
    [[ -f "${mock_dir}/service-state/active-${SERVICE_NAME}" ]] ||
        fail "repeated setup did not leave the service active"
    [[ -f "${mock_dir}/service-state/enabled-${SERVICE_NAME}" ]] ||
        fail "repeated setup did not preserve autostart"

    UPSTREAM_PROXY="http://127.0.0.1:9999"
    : >"${mock_dir}/fail-next-start"
    set +e
    (set -Eeuo pipefail; setup) >/dev/null 2>&1
    failed_status="$?"
    set -e

    [[ "${failed_status}" != "0" ]] || fail "a failed service start must fail setup"
    cmp -s "${CONFIG_FILE}" "${mock_dir}/original-config" || fail "config was not rolled back"
    cmp -s "${STATE_FILE}" "${mock_dir}/original-state" || fail "state was not rolled back"
    cmp -s "${UNIT_FILE}" "${mock_dir}/original-unit" || fail "unit was not rolled back"
    [[ -f "${mock_dir}/service-state/active-${SERVICE_NAME}" ]] ||
        fail "previously active service was not restarted"
    [[ -f "${mock_dir}/service-state/enabled-${SERVICE_NAME}" ]] ||
        fail "previous autostart state was not restored"
}

test_ready_accepts_authenticated_web_ui() {
    local response_code

    reset_configuration
    READY_TIMEOUT="1"
    # shellcheck disable=SC2329
    systemctl() {
        case "${2:-}" in
            is-failed) return 1 ;;
            is-active) return 0 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2329
    curl() {
        printf '%s' "${response_code}"
    }

    for response_code in 200 403; do
        wait_until_ready >/dev/null
    done
}

test_ready_stops_on_failed_service() {
    local curl_marker="${TEST_ROOT}/failed-service-curl"

    reset_configuration
    READY_TIMEOUT="300"
    # shellcheck disable=SC2329
    systemctl() {
        case "${2:-}" in
            is-failed) return 0 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2329
    curl() {
        : >"${curl_marker}"
        printf '200'
    }
    # shellcheck disable=SC2329
    journalctl() {
        return 0
    }

    if (wait_until_ready) >/dev/null 2>&1; then
        fail "a failed service must not become ready"
    fi
    [[ ! -e "${curl_marker}" ]] || fail "readiness probe ran after the service failed"
}

test_ready_timeout_uses_wall_clock() {
    local elapsed
    local started

    reset_configuration
    # shellcheck disable=SC2034
    READY_TIMEOUT="1"
    # shellcheck disable=SC2329
    systemctl() {
        case "${2:-}" in
            is-failed) return 1 ;;
            *) return 0 ;;
        esac
    }
    # shellcheck disable=SC2329
    curl() {
        return 7
    }
    # shellcheck disable=SC2329
    journalctl() {
        return 0
    }

    started="${SECONDS}"
    if (wait_until_ready) >/dev/null 2>&1; then
        fail "an unreachable Web UI must not become ready"
    fi
    elapsed=$((SECONDS - started))
    ((elapsed >= 1 && elapsed <= 3)) ||
        fail "one-second readiness timeout took ${elapsed}s"
}

test_ca_uses_private_nss_database() {
    local key_file="${TEST_ROOT}/test-ca-key.pem"

    reset_configuration
    # shellcheck disable=SC2034
    NO_CERT_INSTALL="0"
    mkdir -p "${MITM_CONF_DIR}"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
        -subj '/CN=mitmweb-shellcrash-test' \
        -keyout "${key_file}" \
        -out "${MITM_CONF_DIR}/mitmproxy-ca-cert.pem" >/dev/null 2>&1
    install_chromium_ca >/dev/null
    certutil -L -d "sql:${NSS_DB}" -n "${CA_NICKNAME}" >/dev/null
    [[ "${NSS_DB}" == "${BROWSER_HOME}/.pki/nssdb" ]] ||
        fail "CA was not installed below the private browser HOME"
}

test_uninstall_removes_only_managed_legacy_unit() {
    local mock_dir="${TEST_ROOT}/legacy-uninstall"

    export XDG_CONFIG_HOME="${mock_dir}/config"
    export XDG_DATA_HOME="${mock_dir}/data"
    export XDG_RUNTIME_DIR="${mock_dir}/runtime"
    reset_configuration
    mkdir -p "${UNIT_DIR}" "${MITM_CONF_DIR}" "${BROWSER_HOME}"
    : >"${STATE_FILE}"
    : >"${CONFIG_FILE}"
    : >"${UNIT_FILE}"
    : >"${BROWSER_HOME}/managed-data"
    cat >"${LEGACY_UNIT_FILE}" <<'EOF'
[Unit]
Description=mitmweb via ShellCrash upstream proxy
[Service]
ExecStart=/usr/bin/mitmweb --no-web-open-browser
EOF

    # shellcheck disable=SC2329
    systemctl() {
        return 0
    }
    # shellcheck disable=SC2329
    flock() {
        return 0
    }

    uninstall_service >/dev/null 2>&1
    uninstall_service >/dev/null 2>&1
    [[ ! -e "${LEGACY_UNIT_FILE}" ]] || fail "managed legacy unit was not removed"
    [[ ! -e "${UNIT_FILE}" ]] || fail "managed unit was not removed"
    [[ ! -e "${APP_CONFIG_DIR}" ]] || fail "managed config directory was not removed"
    [[ ! -e "${DATA_HOME}/${APP_ID}" ]] || fail "managed browser data was not removed"
}

run_test "safe defaults" test_safe_defaults
run_test "quoting helpers" test_quoting_helpers
run_test "redact proxy credentials" test_proxy_credentials_are_redacted
run_test "interactive prompt validation" test_interactive_prompt_validation
run_test "configuration summary redaction" test_configuration_summary_redacts_credentials
run_test "configure cancellation has no writes" test_configure_cancel_has_no_writes
run_test "configure command requires a TTY" test_configure_command_requires_tty
run_test "configure applies autostart after post failure" test_configure_applies_autostart_after_post_failure
run_test "render and validate" test_render_and_validate
run_test "special systemd path" test_special_systemd_path
run_test "state round trip" test_state_round_trip
run_test "reject profile outside private HOME" test_invalid_profile_is_rejected
run_test "reject parent path components" test_parent_path_is_rejected
run_test "reject invalid mitmproxy YAML" test_invalid_mitmproxy_yaml_is_rejected
run_test "strict proxy verification" test_verify_failure_is_nonzero
run_test "installation consistency state" test_installation_consistency_state
run_test "repeatable setup and transaction rollback" test_setup_transaction_rolls_back
run_test "authenticated Web UI readiness" test_ready_accepts_authenticated_web_ui
run_test "failed service readiness" test_ready_stops_on_failed_service
run_test "wall-clock readiness timeout" test_ready_timeout_uses_wall_clock
run_test "private Chromium NSS database" test_ca_uses_private_nss_database
run_test "repeatable managed uninstall" test_uninstall_removes_only_managed_legacy_unit

printf '1..%d\n' "${TESTS_RUN}"
