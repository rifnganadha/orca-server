#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ORCA_PAIRING_ADDRESS:-}" ]]; then
    echo "ORCA_PAIRING_ADDRESS is required (use a reachable Tailscale IP, hostname, or proxy URL)." >&2
    exit 2
fi

if [[ -z "${ORCA_WEB_USER:-}" || -z "${ORCA_WEB_PASSWORD:-}" ]]; then
    echo "ORCA_WEB_USER and ORCA_WEB_PASSWORD are required." >&2
    exit 2
fi

if [[ -z "${GIT_USER_NAME:-}" || -z "${GIT_USER_EMAIL:-}" ]]; then
    echo "GIT_USER_NAME and GIT_USER_EMAIL are required." >&2
    exit 2
fi

git config --global user.name "${GIT_USER_NAME}"
git config --global user.email "${GIT_USER_EMAIL}"

if [[ -n "${GH_TOKEN:-}" ]]; then
    gh config set git_protocol https --host github.com
    gh auth setup-git --hostname github.com
    echo "Configured GitHub CLI and Git HTTPS authentication from GH_TOKEN."
fi

public_port="${ORCA_PORT:-6770}"
pairing_address="${ORCA_PAIRING_ADDRESS}"
if [[ "${pairing_address}" != *://* && "${pairing_address}" != *:* ]]; then
    pairing_address="${pairing_address}:${public_port}"
fi

case "$(uname -m)" in
    x86_64 | amd64) server_arch="x86_64" ;;
    aarch64 | arm64) server_arch="aarch64" ;;
    *) server_arch="$(uname -m)" ;;
esac

runtime_dir="$(mktemp -d)"
mobile_ready_log="${runtime_dir}/mobile.log"
web_ready_log="${runtime_dir}/web.log"
: >"${mobile_ready_log}"
: >"${web_ready_log}"
nginx_config="${runtime_dir}/nginx.conf"
web_auth_file="${runtime_dir}/htpasswd"
web_session_token="$(openssl rand -hex 32)"
login_page="${runtime_dir}/login.html"
web_landing_page="${runtime_dir}/index.html"
pairing_page="${runtime_dir}/mobile.html"
mobile_pairing_qr="${runtime_dir}/mobile.svg"
desktop_pairing_page="${runtime_dir}/desktop.html"
desktop_pairing_qr="${runtime_dir}/desktop.svg"
orca_pid=""
template_dir="/usr/local/share/orca-server"
nginx_template="${template_dir}/nginx/nginx.conf"
web_template_dir="${template_dir}/web"

cleanup() {
    [[ -z "${orca_pid}" ]] || kill "${orca_pid}" 2>/dev/null || true
    rm -rf "${runtime_dir}"
}
trap cleanup EXIT INT TERM

wait_for_pairing() {
    local scope="$1"
    local log="$2"
    local label="$3"
    local line parsed result
    local fragment=""
    local log_fd

    exec {log_fd}<"${log}"

    for _ in $(seq 1 120); do
        while true; do
            line=""
            if IFS= read -r line <&"${log_fd}"; then
                line="${fragment}${line}"
                fragment=""
                parsed="$(jq -Rr --arg scope "${scope}" 'fromjson? | select(.type == "orca_server_ready" and .pairing.available == true and .pairing.scope == $scope) | [.pairing.url, .pairing.endpoint] | @tsv' <<<"${line}")"
                [[ -z "${parsed}" ]] || result="${parsed}"
            else
                fragment+="${line}"
                break
            fi
        done
        if [[ -n "${result:-}" ]]; then
            IFS=$'\t' read -r pairing_url pairing_endpoint <<<"${result}"
            exec {log_fd}<&-
            return
        fi
        kill -0 "${orca_pid}" 2>/dev/null || wait "${orca_pid}"
        sleep 0.5
    done
    exec {log_fd}<&-
    cat "${log}" >&2
    echo "Orca did not provide a ${label} pairing URL within 60 seconds." >&2
    return 1
}

render_template() {
    local input="$1"
    local output="$2"
    local key value escaped
    local sed_args=()

    shift 2
    while (( $# )); do
        key="$1"
        value="$2"
        shift 2
        escaped="${value//\\/\\\\}"
        escaped="${escaped//&/\\&}"
        escaped="${escaped//|/\\|}"
        sed_args+=(-e "s|@@${key}@@|${escaped}|g")
    done
    sed "${sed_args[@]}" "${input}" >"${output}"
}

printf '%s\n' "${ORCA_WEB_PASSWORD}" | htpasswd -n -i -m "${ORCA_WEB_USER}" >"${web_auth_file}"
cp "${web_template_dir}/login.html" "${login_page}"

/opt/orca/squashfs-root/AppRun serve \
    --port 6769 \
    --pairing-address "${pairing_address}" \
    --mobile-pairing \
    --json >"${mobile_ready_log}" 2>&1 &
orca_pid=$!
wait_for_pairing mobile "${mobile_ready_log}" Mobile
mobile_pairing_url="${pairing_url}"
mobile_pairing_endpoint="${pairing_endpoint}"

kill "${orca_pid}" 2>/dev/null || true
wait "${orca_pid}" 2>/dev/null || true
orca_pid=""

/opt/orca/squashfs-root/AppRun serve \
    --port 6769 \
    --pairing-address "${pairing_address}" \
    --json > >(tee "${web_ready_log}") 2>&1 &
orca_pid=$!
wait_for_pairing runtime "${web_ready_log}" Web

render_template "${web_template_dir}/landing.html" "${web_landing_page}" PAIRING_URL "${pairing_url}"

printf '%s' "${mobile_pairing_url}" | qrencode -t SVG -o "${mobile_pairing_qr}"
render_template "${web_template_dir}/pairing.html" "${pairing_page}" \
    TITLE Mobile \
    INSTRUCTIONS 'In Orca Mobile, choose <strong>Pair Desktop</strong> and scan this code.' \
    QR_PATH mobile-pairing.svg \
    PAIRING_URL "${mobile_pairing_url}" \
    PAIRING_ENDPOINT "${mobile_pairing_endpoint}"

printf '%s' "${pairing_url}" | qrencode -t SVG -o "${desktop_pairing_qr}"
render_template "${web_template_dir}/pairing.html" "${desktop_pairing_page}" \
    TITLE Desktop \
    INSTRUCTIONS 'Scan this code or enter the full pairing URI in the Orca desktop client.' \
    QR_PATH desktop-pairing.svg \
    PAIRING_URL "${pairing_url}" \
    PAIRING_ENDPOINT "${pairing_endpoint}"

render_template "${nginx_template}" "${nginx_config}" \
    SESSION_TOKEN "${web_session_token}" \
    PAIRING_ENDPOINT "${pairing_endpoint}" \
    SERVER_ARCH "${server_arch}" \
    RUNTIME_DIR "${runtime_dir}" \
    LOGIN_PAGE "${login_page}" \
    AUTH_FILE "${web_auth_file}" \
    MOBILE_PAGE "${pairing_page}" \
    MOBILE_QR "${mobile_pairing_qr}" \
    DESKTOP_PAGE "${desktop_pairing_page}" \
    DESKTOP_QR "${desktop_pairing_qr}"

exec nginx -c "${nginx_config}" -g 'daemon off;'
