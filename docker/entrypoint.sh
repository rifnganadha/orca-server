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

kilo_provider_id="${KILO_PROVIDER_ID:-9router}"
kilo_provider_name="${KILO_PROVIDER_NAME:-9Router}"
kilo_provider_npm="${KILO_PROVIDER_NPM:-@ai-sdk/openai-compatible}"
kilo_base_url="${KILO_BASE_URL:-https://9router.akasia.dev/v1}"
kilo_model_id="${KILO_MODEL_ID:-gpt-5.6-sol}"
kilo_model_name="${KILO_MODEL_NAME:-GPT-5.6 SOL}"
repowise_enabled="${REPOWISE_ENABLED:-true}"

if [[ ! "${kilo_provider_id}" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "KILO_PROVIDER_ID must contain only lowercase letters, digits, periods, underscores, or hyphens." >&2
    exit 2
fi
if [[ "${repowise_enabled}" != "true" && "${repowise_enabled}" != "false" ]]; then
    echo "REPOWISE_ENABLED must be true or false." >&2
    exit 2
fi
if [[ -z "${kilo_provider_name}" || -z "${kilo_provider_npm}" || -z "${kilo_base_url}" || -z "${kilo_model_id}" || -z "${kilo_model_name}" ]]; then
    echo "Kilo provider and model settings must not be empty." >&2
    exit 2
fi

git config --global user.name "${GIT_USER_NAME}"
git config --global user.email "${GIT_USER_EMAIL}"

rm -rf "${XDG_DATA_HOME:-${HOME}/.local/share}/kilo/memory"

for skill_scope in .agents .kilocode; do
    bundled_skills="/usr/local/share/orca-server/skills/${skill_scope}/skills"
    installed_skills="/home/orca/${skill_scope}/skills"
    mkdir -p "${installed_skills}"
    for bundled_skill in "${bundled_skills}"/*; do
        skill_name="$(basename "${bundled_skill}")"
        if [[ ! -e "${installed_skills}/${skill_name}" ]]; then
            cp -R "${bundled_skill}" "${installed_skills}/${skill_name}"
        fi
    done
done

mkdir -p /home/orca/.config/kilo
kilo_config="/home/orca/.config/kilo/kilo.jsonc"
jq \
    --arg provider_id "${kilo_provider_id}" \
    --arg provider_name "${kilo_provider_name}" \
    --arg provider_npm "${kilo_provider_npm}" \
    --arg base_url "${kilo_base_url}" \
    --arg model_id "${kilo_model_id}" \
    --arg model_name "${kilo_model_name}" \
    --argjson repowise_enabled "${repowise_enabled}" \
    '.model = ($provider_id + "/" + $model_id)
    | .small_model = .model
    | .enabled_providers = [$provider_id]
    | .provider = {
        ($provider_id): {
          npm: $provider_npm,
          name: $provider_name,
          options: {
            baseURL: $base_url,
            apiKey: "{env:KILO_API_KEY}"
          },
          models: {
            ($model_id): {name: $model_name}
          }
        }
      }
    | if $repowise_enabled then
        .mcp.repowise = {
          type: "local",
          command: ["/usr/local/bin/repowise", "mcp"],
          enabled: true
        }
      else
        .mcp = ((.mcp // {}) | del(.repowise))
      end' \
    /usr/local/share/orca-server/kilo/kilo.jsonc >"${kilo_config}"
chmod 600 "${kilo_config}"

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
repowise_log="${runtime_dir}/repowise.log"
: >"${mobile_ready_log}"
: >"${web_ready_log}"
: >"${repowise_log}"
nginx_config="${runtime_dir}/nginx.conf"
web_auth_file="${runtime_dir}/htpasswd"
web_session_token="$(openssl rand -hex 32)"
repowise_session_token="$(openssl rand -hex 32)"
repowise_api_key="$(openssl rand -hex 32)"
login_page="${runtime_dir}/login.html"
repowise_login_page="${runtime_dir}/repowise-login.html"
web_landing_page="${runtime_dir}/index.html"
pairing_page="${runtime_dir}/mobile.html"
mobile_pairing_qr="${runtime_dir}/mobile.svg"
desktop_pairing_page="${runtime_dir}/desktop.html"
desktop_pairing_qr="${runtime_dir}/desktop.svg"
orca_pid=""
repowise_pid=""
template_dir="/usr/local/share/orca-server"
nginx_template="${template_dir}/nginx/nginx.conf"
web_template_dir="${template_dir}/web"

cleanup() {
    [[ -z "${orca_pid}" ]] || kill "${orca_pid}" 2>/dev/null || true
    [[ -z "${repowise_pid}" ]] || kill "${repowise_pid}" 2>/dev/null || true
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
render_template "${web_template_dir}/login.html" "${login_page}" PRODUCT Orca
render_template "${web_template_dir}/login.html" "${repowise_login_page}" PRODUCT RepoWise

if [[ "${repowise_enabled}" == "true" ]]; then
    REPOWISE_API_KEY="${repowise_api_key}" repowise-dashboard > >(tee "${repowise_log}") 2>&1 &
    repowise_pid=$!

    for _ in $(seq 1 240); do
        if bash -c 'exec 3<>/dev/tcp/127.0.0.1/7337' 2>/dev/null \
                && bash -c 'exec 3<>/dev/tcp/127.0.0.1/7340' 2>/dev/null; then
            break
        fi
        if ! kill -0 "${repowise_pid}" 2>/dev/null; then
            cat "${repowise_log}" >&2
            echo "RepoWise dashboard exited during startup." >&2
            exit 1
        fi
        sleep 0.5
    done
    if ! bash -c 'exec 3<>/dev/tcp/127.0.0.1/7337' 2>/dev/null \
            || ! bash -c 'exec 3<>/dev/tcp/127.0.0.1/7340' 2>/dev/null; then
        cat "${repowise_log}" >&2
        echo "RepoWise dashboard did not become ready within 120 seconds." >&2
        exit 1
    fi
    echo "RepoWise workspace dashboard ready."
fi

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
    REPOWISE_SESSION_TOKEN "${repowise_session_token}" \
    REPOWISE_API_KEY "${repowise_api_key}" \
    PAIRING_ENDPOINT "${pairing_endpoint}" \
    SERVER_ARCH "${server_arch}" \
    RUNTIME_DIR "${runtime_dir}" \
    LOGIN_PAGE "${login_page}" \
    REPOWISE_LOGIN_PAGE "${repowise_login_page}" \
    AUTH_FILE "${web_auth_file}" \
    MOBILE_PAGE "${pairing_page}" \
    MOBILE_QR "${mobile_pairing_qr}" \
    DESKTOP_PAGE "${desktop_pairing_page}" \
    DESKTOP_QR "${desktop_pairing_qr}"

exec nginx -c "${nginx_config}" -g 'daemon off;'
