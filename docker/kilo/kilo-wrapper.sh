#!/usr/bin/env bash
set -euo pipefail

# Kilo stores project memory outside the checkout. Initialize it on first use so every
# Git project opened in the container starts with memory enabled by default.
if [[ -d .git || -f .git ]]; then
    memory_data_root="${XDG_DATA_HOME:-${HOME}/.local/share}/kilo/memory"
    project_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"

    if [[ -n "${project_root}" ]]; then
        project_name="$(basename "${project_root}")"
        project_hash="$(printf '%s' "${project_root}" | sha1sum | cut -c1-12)"
        memory_root="${memory_data_root}/${project_name}-${project_hash}"

        if [[ ! -f "${memory_root}/state.json" ]]; then
            mkdir -p "${memory_root}/sessions"
            printf '%s\n' '*' '!.gitignore' >"${memory_root}/.gitignore"
            printf '%s\n' '# Project Memory' '' '## Facts' '' '## Decisions' '' '## Constraints' '' '## Open Questions' >"${memory_root}/project.md"
            printf '%s\n' '# Environment Memory' '' '## Commands' '' '## Paths' '' '## Tooling' >"${memory_root}/environment.md"
            printf '%s\n' '# Corrective Memory' '' '## Corrections' >"${memory_root}/corrections.md"
            printf '%s\n' '{"kind":"kilo-memory","version":1}' >"${memory_root}/manifest.json"
            printf '%s\n' '{"version":1,"enabled":true,"scope":"project","autoInject":true,"autoConsolidate":true,"verbose":false,"capture":{"mode":"selective","turnClose":true,"explicit":true,"maxOpsPerRun":16,"minIntervalMs":300000,"timeoutMs":30000},"stats":{"lastInjectedAt":null,"lastInjectedBytes":0,"lastInjectedTokens":0,"lastInjectedSessionID":null,"lastTypedConsolidationAt":null,"lastSessionSavedAt":null,"lastConsolidatedMessageID":null,"lastConsolidationCost":0,"lastConsolidationTokens":0,"lastOperationCount":0,"lastRecallAt":null,"lastRecallCount":0,"lastRecallSessionID":null}}' >"${memory_root}/state.json"
            chmod 700 "${memory_root}" "${memory_root}/sessions"
            find "${memory_root}" -maxdepth 1 -type f -exec chmod 600 {} +
        fi
    fi
fi

exec /usr/local/bin/kilo-real "$@"
