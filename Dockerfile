# syntax=docker/dockerfile:1

ARG DOCKER_CLI_VERSION=29.1.3
ARG NODE_VERSION=22.20.0
ARG SKILLS_CLI_VERSION=1.5.23
ARG KILO_CLI_VERSION=7.5.6
ARG REPOWISE_VERSION=0.46.0

FROM docker:${DOCKER_CLI_VERSION}-cli AS docker-cli

FROM node:${NODE_VERSION}-bookworm-slim AS node-runtime

FROM debian:bookworm-slim AS extractor

ARG ORCA_VERSION=v1.4.188
ARG TARGETARCH

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl file grep squashfs-tools zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/orca

RUN case "${TARGETARCH}" in \
        amd64) asset="orca-linux.AppImage"; machine="x86-64" ;; \
        arm64) asset="orca-linux-arm64.AppImage"; machine="ARM aarch64" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fL --retry 3 \
        "https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/${asset}" \
        -o orca-linux.AppImage \
    && chmod 755 orca-linux.AppImage \
    && file_info="$(LC_ALL=C file orca-linux.AppImage)" \
    && echo "${file_info}" | grep -q 'ELF .* executable' \
    && echo "${file_info}" | grep -Fq "${machine}" \
    && grep -abo 'hsqs' orca-linux.AppImage | cut -d: -f1 > squashfs-offsets \
    && rm -rf squashfs-root \
    && found_squashfs=false \
    && while read -r squashfs_offset; do \
        rm -rf squashfs-root; \
        if unsquashfs -no-progress -offset "${squashfs_offset}" -d squashfs-root orca-linux.AppImage >/dev/null 2>&1; then \
            found_squashfs=true; \
            break; \
        fi; \
    done < squashfs-offsets \
    && test "${found_squashfs}" = true \
    && rm squashfs-offsets \
    && rm orca-linux.AppImage \
    && chmod -R a+rX squashfs-root

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LIBGL_ALWAYS_SOFTWARE=1 \
    ORCA_PORT=6770

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        apache2-utils \
        bash \
        ca-certificates \
        curl \
        gh \
        git \
        jq \
        libasound2 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libcairo2 \
        libcups2 \
        libdbus-1-3 \
        libgbm1 \
        libglib2.0-0 \
        libgtk-3-0 \
        libnspr4 \
        libnss3 \
        libpango-1.0-0 \
        libxcomposite1 \
        libxdamage1 \
        libxkbcommon0 \
        nginx-light \
        openssh-client \
        openssl \
        python3 \
        python3-venv \
        qrencode \
        ripgrep \
        xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash orca

ARG KILO_CLI_VERSION
RUN curl -fsSL https://kilo.ai/cli/install | bash -s -- --version "${KILO_CLI_VERSION}" --no-modify-path \
    && mv /root/.kilo/bin/kilo /usr/local/bin/kilo \
    && mv /root/.kilo/bin/tree-sitter /usr/local/bin/tree-sitter \
    && rm -rf /root/.kilo \
    && test -f /usr/local/bin/tree-sitter/tree-sitter.wasm \
    && test "$(kilo --version)" = "${KILO_CLI_VERSION}"

ARG REPOWISE_VERSION
RUN python3 -m venv /opt/repowise \
    && /opt/repowise/bin/pip install --no-cache-dir "repowise==${REPOWISE_VERSION}" \
    && ln -s /opt/repowise/bin/repowise /usr/local/bin/repowise \
    && repowise --version | grep -F "${REPOWISE_VERSION}"

COPY --from=extractor /opt/orca/squashfs-root /opt/orca/squashfs-root
COPY --from=docker-cli /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-cli /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
COPY --from=node-runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node-runtime /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
COPY docker/nginx /usr/local/share/orca-server/nginx
COPY docker/web /usr/local/share/orca-server/web
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=755 docker/repowise-dashboard.py /usr/local/bin/repowise-dashboard
COPY docker/kilo/kilo.jsonc /usr/local/share/orca-server/kilo/kilo.jsonc
RUN sed -i 's/\r$//' /usr/local/bin/docker-entrypoint.sh \
    && sed -i 's/\r$//' /usr/local/bin/repowise-dashboard \
    && chmod 755 /usr/local/bin/docker /usr/local/libexec/docker/cli-plugins/* \
    && chmod 644 /usr/local/share/orca-server/kilo/kilo.jsonc \
    && docker --version \
    && docker compose version \
    && node --version \
    && npm --version \
    && npx --version

USER orca
WORKDIR /home/orca

ARG SKILLS_CLI_VERSION
RUN --mount=type=cache,target=/home/orca/.npm,uid=1000,gid=1000 \
    npx --yes "skills@${SKILLS_CLI_VERSION}" add https://github.com/stablyai/orca \
        --skill orca-cli \
        --skill computer-use \
        --skill orchestration \
        --global \
        --agent universal \
        --yes \
    && npx --yes "skills@${SKILLS_CLI_VERSION}" add https://github.com/stablyai/orca \
        --skill orca-cli \
        --skill computer-use \
        --skill orchestration \
        --global \
        --agent kilo \
        --yes \
    && test -f /home/orca/.agents/skills/orca-cli/SKILL.md \
    && test -f /home/orca/.agents/skills/computer-use/SKILL.md \
    && test -f /home/orca/.agents/skills/orchestration/SKILL.md \
    && test -f /home/orca/.kilocode/skills/orca-cli/SKILL.md \
    && test -f /home/orca/.kilocode/skills/computer-use/SKILL.md \
    && test -f /home/orca/.kilocode/skills/orchestration/SKILL.md

USER root
RUN mkdir -p /usr/local/share/orca-server/skills/.agents /usr/local/share/orca-server/skills/.kilocode \
    && cp -R /home/orca/.agents/skills /usr/local/share/orca-server/skills/.agents/skills \
    && cp -R /home/orca/.kilocode/skills /usr/local/share/orca-server/skills/.kilocode/skills \
    && chmod -R a+rX /usr/local/share/orca-server/skills

USER orca

EXPOSE 6768

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
