FROM debian:bookworm-slim AS extractor

ARG ORCA_VERSION=v1.4.188
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl file \
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
    && ./orca-linux.AppImage --appimage-extract \
    && rm orca-linux.AppImage \
    && chmod -R a+rX squashfs-root

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LIBGL_ALWAYS_SOFTWARE=1 \
    ORCA_PORT=6770

RUN apt-get update \
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
        qrencode \
        ripgrep \
        xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash orca

COPY --from=extractor /opt/orca/squashfs-root /opt/orca/squashfs-root
COPY docker/nginx /usr/local/share/orca-server/nginx
COPY docker/web /usr/local/share/orca-server/web
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh

USER orca
WORKDIR /home/orca

EXPOSE 6768

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
