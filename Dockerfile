# syntax=docker/dockerfile:1.7
#
# OpenCode server workstation
#   - Debian stable (slim)
#   - build-essential, git, gh, ripgrep and friends
#   - Go (latest stable), Node.js (latest) + yarn
#   - opencode v2 (https://opencode.ai/v2) running as an HTTP server
#
# Every "latest" is resolved at build time so a rebuild refreshes the toolchain.
# Pin with --build-arg NODE_VERSION=v24.20.0 GO_VERSION=go1.27.1 OPENCODE_VERSION=2.0.12

FROM debian:stable-slim

ARG TARGETARCH
ARG NODE_VERSION=latest
ARG GO_VERSION=latest
ARG OPENCODE_VERSION=latest
# OpenClient iOS app plugin (@openclient-ios/opencode-plugin): version written
# into opencode.json by the entrypoint when OPENCLIENT_ENABLED=true.
ARG OPENCLIENT_PLUGIN_VERSION=latest

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# Base system + build tooling
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        cmake \
        make \
        autoconf \
        automake \
        libtool \
        libssl-dev \
        zlib1g-dev \
        python3 \
        python3-pip \
        python3-venv \
        git \
        git-lfs \
        openssh-client \
        openssh-server \
        ca-certificates \
        curl \
        wget \
        gnupg \
        jq \
        xz-utils \
        unzip \
        zip \
        tar \
        gzip \
        ripgrep \
        fd-find \
        fzf \
        less \
        vim-tiny \
        nano \
        procps \
        htop \
        tini \
        # OC Notify: forwards a pod port to the plugin's loopback-only web app
        socat \
        # OpenClient image/video tools (ffprobe + ffmpeg previews and HLS)
        ffmpeg \
        sudo \
        locales \
        tzdata \
        bash-completion; \
    # GitHub CLI (official apt repository)
    mkdir -p -m 755 /etc/apt/keyrings; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    # Docker CLI, buildx and compose (daemon provided by a sidecar or DOCKER_HOST)
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc; \
    chmod go+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh docker-ce-cli docker-buildx-plugin docker-compose-plugin; \
    git lfs install --system; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    # sshd runs unprivileged as the dev user with its own host keys (see entrypoint);
    # drop the package-generated system host keys.
    rm -f /etc/ssh/ssh_host_*; \
    mkdir -p /run/sshd; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Node.js (latest by default) + yarn
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) NODE_ARCH=x64 ;; \
        arm64) NODE_ARCH=arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${NODE_VERSION}" = "latest" ]; then \
        NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '.[0].version')"; \
    fi; \
    echo "Installing Node.js ${NODE_VERSION} (${NODE_ARCH})"; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" -o /tmp/node.tar.xz; \
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" -o /tmp/SHASUMS256.txt; \
    grep " node-${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz\$" /tmp/SHASUMS256.txt | sed 's# .*# /tmp/node.tar.xz#' | sha256sum -c -; \
    tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner; \
    rm -f /tmp/node.tar.xz /tmp/SHASUMS256.txt /usr/local/CHANGELOG.md /usr/local/LICENSE /usr/local/README.md; \
    npm install -g --no-fund --no-audit yarn corepack; \
    npm cache clean --force; \
    node --version; npm --version; yarn --version

# ---------------------------------------------------------------------------
# Go (latest stable by default)
# ---------------------------------------------------------------------------
ENV GOROOT=/usr/local/go \
    GOPATH=/home/${USERNAME}/go \
    GOTOOLCHAIN=auto
ENV PATH=${GOPATH}/bin:${GOROOT}/bin:${PATH}

RUN set -eux; \
    if [ "${GO_VERSION}" = "latest" ]; then \
        GO_VERSION="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1)"; \
    fi; \
    echo "Installing ${GO_VERSION} (${TARGETARCH})"; \
    curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${TARGETARCH}.tar.gz" -o /tmp/go.tar.gz; \
    EXPECTED="$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' \
        | jq -r --arg v "${GO_VERSION}" --arg a "${TARGETARCH}" \
          '.[] | select(.version==$v) | .files[] | select(.os=="linux" and .arch==$a and .kind=="archive") | .sha256')"; \
    echo "${EXPECTED}  /tmp/go.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/go.tar.gz -C /usr/local --no-same-owner; \
    rm -f /tmp/go.tar.gz; \
    go version; \
    # Login shells (ssh) do not inherit the image ENV; provide it via profile.d too.
    printf '%s\n' \
        'export GOROOT=/usr/local/go' \
        'export GOPATH="${GOPATH:-$HOME/go}"' \
        'export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"' \
        'case ":$PATH:" in *":/usr/local/go/bin:"*) ;; *) export PATH="$GOPATH/bin:/usr/local/go/bin:$HOME/.local/bin:$PATH" ;; esac' \
        '# docker:dind sidecar socket (see charts/opencode values: docker.enabled)' \
        'if [ -z "${DOCKER_HOST:-}" ] && [ -S /run/docker/docker.sock ]; then export DOCKER_HOST=unix:///run/docker/docker.sock; fi' \
        > /etc/profile.d/workstation.sh; \
    chmod 0644 /etc/profile.d/workstation.sh

# ---------------------------------------------------------------------------
# opencode v2 (latest release by default, checksum-verified)
#
# v2 is distributed as npm platform packages (@opencode/cli-linux-<arch>), the
# same source https://opencode.ai/v2/install uses; GitHub "latest" releases
# still point at the 1.x line. The version is resolved from the @opencode/cli
# dist-tag and the tarball is checked against the registry's sha512 integrity.
# The x64 build requires AVX2 (@opencode/cli-linux-x64-baseline otherwise).
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) OC_ARCH=x64 ;; \
        arm64) OC_ARCH=arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    OPENCODE_VERSION="${OPENCODE_VERSION#v}"; \
    if [ "${OPENCODE_VERSION}" = "latest" ]; then \
        OPENCODE_VERSION="$(curl -fsSL 'https://registry.npmjs.org/@opencode%2Fcli/latest' | jq -r .version)"; \
    fi; \
    case "${OPENCODE_VERSION}" in \
        2.*) ;; \
        *) echo "OPENCODE_VERSION=${OPENCODE_VERSION}: only opencode 2.x is supported" >&2; exit 1 ;; \
    esac; \
    META="$(curl -fsSL "https://registry.npmjs.org/@opencode%2Fcli-linux-${OC_ARCH}/${OPENCODE_VERSION}")"; \
    URL="$(printf '%s' "${META}" | jq -er .dist.tarball)"; \
    INTEGRITY="$(printf '%s' "${META}" | jq -er .dist.integrity)"; \
    echo "Installing opencode ${OPENCODE_VERSION} (${OC_ARCH}) from ${URL}"; \
    curl -fsSL "${URL}" -o /tmp/opencode.tgz; \
    EXPECTED="$(printf '%s' "${INTEGRITY#sha512-}" | base64 -d | od -An -tx1 | tr -d ' \n')"; \
    echo "${EXPECTED}  /tmp/opencode.tgz" | sha512sum -c -; \
    mkdir -p /tmp/opencode; \
    tar -xzf /tmp/opencode.tgz -C /tmp/opencode --strip-components=1 package/bin/opencode; \
    install -m 0755 /tmp/opencode/bin/opencode /usr/local/bin/opencode; \
    rm -rf /tmp/opencode /tmp/opencode.tgz; \
    opencode --version

# ---------------------------------------------------------------------------
# OpenClient plugin version (https://github.com/ntoporcov/openclient)
#
# opencode v2 installs package plugins itself (into ~/.cache/opencode/npm, on
# the home volume) the first time a project is opened, so the package is not
# baked into the image. Only the version is resolved here; the entrypoint
# writes "@openclient-ios/opencode-plugin@<version>" into opencode.json when
# OPENCLIENT_ENABLED=true (override at runtime with OPENCLIENT_PLUGIN_VERSION).
# ---------------------------------------------------------------------------
RUN set -eux; \
    OPENCLIENT_PLUGIN_VERSION="${OPENCLIENT_PLUGIN_VERSION#v}"; \
    if [ "${OPENCLIENT_PLUGIN_VERSION}" = "latest" ]; then \
        OPENCLIENT_PLUGIN_VERSION="$(curl -fsSL 'https://registry.npmjs.org/@openclient-ios%2Fopencode-plugin/latest' | jq -er .version)"; \
    else \
        curl -fsSL "https://registry.npmjs.org/@openclient-ios%2Fopencode-plugin/${OPENCLIENT_PLUGIN_VERSION}" | jq -er .version >/dev/null; \
    fi; \
    echo "OpenClient plugin version: ${OPENCLIENT_PLUGIN_VERSION}"; \
    install -d -m 0755 /usr/local/share/workstation; \
    printf '%s\n' "${OPENCLIENT_PLUGIN_VERSION}" > /usr/local/share/workstation/openclient-plugin.version; \
    chmod 0644 /usr/local/share/workstation/openclient-plugin.version

# ---------------------------------------------------------------------------
# uv (Python package manager) and the Drone CI CLI, latest releases
# ---------------------------------------------------------------------------
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) UV_TRIPLE=x86_64-unknown-linux-gnu ;; \
        arm64) UV_TRIPLE=aarch64-unknown-linux-gnu ;; \
    esac; \
    UV_BASE="https://github.com/astral-sh/uv/releases/latest/download"; \
    curl -fsSL "${UV_BASE}/uv-${UV_TRIPLE}.tar.gz" -o /tmp/uv.tar.gz; \
    curl -fsSL "${UV_BASE}/uv-${UV_TRIPLE}.tar.gz.sha256" | sed 's# .*# /tmp/uv.tar.gz#' | sha256sum -c -; \
    tar -xzf /tmp/uv.tar.gz -C /tmp; \
    install -m 0755 "/tmp/uv-${UV_TRIPLE}/uv" "/tmp/uv-${UV_TRIPLE}/uvx" /usr/local/bin/; \
    rm -rf /tmp/uv.tar.gz "/tmp/uv-${UV_TRIPLE}"; \
    uv --version; \
    # drone CLI (https://github.com/harness/drone-cli); /usr/local/bin/drone is a
    # wrapper (scripts/drone-wrapper) that loads DRONE_SERVER/DRONE_TOKEN from a file.
    curl -fsSL "https://github.com/harness/drone-cli/releases/latest/download/drone_linux_${TARGETARCH}.tar.gz" \
        | tar -xz -C /tmp drone; \
    install -D -m 0755 /tmp/drone /usr/local/libexec/drone; \
    rm -f /tmp/drone; \
    /usr/local/libexec/drone --version

# ---------------------------------------------------------------------------
# Helm, Argo CD CLI, Scaleway CLI (latest releases, checksum-verified)
# ---------------------------------------------------------------------------
RUN set -eux; \
    # helm
    HELM_VERSION="$(curl -fsSL https://get.helm.sh/helm-latest-version)"; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" -o /tmp/helm.tar.gz; \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum" | sed 's# .*# /tmp/helm.tar.gz#' | sha256sum -c -; \
    tar -xzf /tmp/helm.tar.gz -C /tmp; \
    install -m 0755 "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    rm -rf /tmp/helm.tar.gz "/tmp/linux-${TARGETARCH}"; \
    helm version; \
    # argocd
    ARGOCD_BASE="https://github.com/argoproj/argo-cd/releases/latest/download"; \
    curl -fsSL "${ARGOCD_BASE}/argocd-linux-${TARGETARCH}" -o /tmp/argocd; \
    curl -fsSL "${ARGOCD_BASE}/cli_checksums.txt" | grep " argocd-linux-${TARGETARCH}\$" | sed 's# .*# /tmp/argocd#' | sha256sum -c -; \
    install -m 0755 /tmp/argocd /usr/local/bin/argocd; \
    rm -f /tmp/argocd; \
    argocd version --client; \
    # scaleway cli (asset names embed the version; read it from SHA256SUMS)
    SCW_BASE="https://github.com/scaleway/scaleway-cli/releases/latest/download"; \
    curl -fsSL "${SCW_BASE}/SHA256SUMS" -o /tmp/scw-sums.txt; \
    SCW_VERSION="$(grep -oE 'scaleway-cli_[0-9]+\.[0-9]+\.[0-9]+_linux_amd64' /tmp/scw-sums.txt | head -n1 | sed -E 's/scaleway-cli_([^_]+)_.*/\1/')"; \
    curl -fsSL "${SCW_BASE}/scaleway-cli_${SCW_VERSION}_linux_${TARGETARCH}" -o /tmp/scw; \
    grep " scaleway-cli_${SCW_VERSION}_linux_${TARGETARCH}\$" /tmp/scw-sums.txt | sed 's# .*# /tmp/scw#' | sha256sum -c -; \
    install -m 0755 /tmp/scw /usr/local/bin/scw; \
    rm -f /tmp/scw /tmp/scw-sums.txt; \
    scw version

# ---------------------------------------------------------------------------
# Non-root user, directories, entrypoint
# ---------------------------------------------------------------------------
RUN set -eux; \
    groupadd --gid "${USER_GID}" "${USERNAME}"; \
    useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}"; \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}"; \
    chmod 0440 "/etc/sudoers.d/${USERNAME}"; \
    mkdir -p /workspace \
        "/home/${USERNAME}/.config/opencode" \
        "/home/${USERNAME}/.local/share/opencode" \
        "/home/${USERNAME}/.ssh" \
        "${GOPATH}"; \
    chmod 700 "/home/${USERNAME}/.ssh"; \
    chown -R "${USER_UID}:${USER_GID}" /workspace "/home/${USERNAME}"

COPY --chmod=0755 scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chmod=0755 scripts/git-credential-github-file /usr/local/bin/git-credential-github-file
COPY --chmod=0755 scripts/drone-wrapper /usr/local/bin/drone
COPY --chmod=0755 scripts/openclient-notify /usr/local/bin/openclient-notify

USER ${USERNAME}
WORKDIR /workspace

ENV HOME=/home/${USERNAME} \
    # opencode server
    OPENCODE_HOST=0.0.0.0 \
    OPENCODE_PORT=4096 \
    # provider / model (see scripts/docker-entrypoint.sh)
    OPENCODE_PROVIDER=openrouter \
    OPENCODE_MODEL="" \
    BUN_RUNTIME_TRANSPILER_CACHE_PATH=0

# 4096: opencode server. 2222: optional sshd (only when SSH_AUTHORIZED_KEYS is set).
# 4070: OpenClient plugin bridge (first free port in 4070-4090, unauthenticated;
#       only with OPENCLIENT_ENABLED=true, keep it on a trusted network).
# 4321: OC Notify web app, forwarded from loopback (only with OPENCLIENT_NOTIFY_ENABLED=true).
EXPOSE 4096 2222 4070 4321

# Persist these two paths:
#   /workspace     your repositories
#   /home/dev      opencode sessions/auth, Go module cache, npm/yarn/uv caches,
#                  gh and drone config, shell history. The entrypoint seeds
#                  dotfiles from /etc/skel when the home volume starts empty.
#
# Secrets passed as env vars (provider API key, GITHUB_TOKEN, DRONE_TOKEN, ...)
# are moved by the entrypoint into 0600 files under ~/.config and removed from
# the environment before opencode starts. See scripts/docker-entrypoint.sh.

# /api/info (v2 server info) is behind basic auth when OPENCODE_SERVER_PASSWORD is set.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS ${OPENCODE_SERVER_PASSWORD:+-u "${OPENCODE_SERVER_USERNAME:-opencode}:${OPENCODE_SERVER_PASSWORD}"} \
        "http://127.0.0.1:${OPENCODE_PORT}/api/info" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["serve"]
