#!/usr/bin/env bash
# Entrypoint for the opencode workstation image.
#
# Responsibilities:
#   1. Generate ~/.config/opencode/opencode.json from environment variables
#      (unless a config file is already present, e.g. mounted from a ConfigMap).
#   2. Configure git identity and GitHub credentials (token over HTTPS and/or
#      SSH key).
#   3. Start `opencode serve` bound to all interfaces, or run whatever command
#      was passed instead.
#
# Environment variables (all optional):
#
#   OPENCODE_PROVIDER              provider id, default "openrouter"
#   OPENCODE_MODEL                 default model, e.g. "openrouter/anthropic/claude-sonnet-4.5"
#   OPENCODE_SMALL_MODEL           model used for lightweight tasks (titles, summaries)
#   OPENCODE_PROVIDER_API_KEY_ENV  name of the env var holding the provider API key;
#                                  defaults to "<PROVIDER>_API_KEY", e.g. OPENROUTER_API_KEY
#   OPENCODE_PROVIDER_BASE_URL     override the provider base URL (self-hosted / proxies)
#   OPENCODE_CONFIG_JSON           full opencode.json content; written verbatim, wins over the above
#   OPENCODE_CONFIG_FORCE          "true" to overwrite an existing config file
#
#   OPENCODE_HOST / OPENCODE_PORT  bind address for `opencode serve` (0.0.0.0 / 4096)
#   OPENCODE_CORS                  space separated list of allowed browser origins
#   OPENCODE_SERVER_PASSWORD       enable HTTP basic auth (read by opencode itself)
#   OPENCODE_SERVER_USERNAME       basic auth user, default "opencode" (read by opencode itself)
#
#   GIT_USER_NAME / GIT_USER_EMAIL git identity for commits
#   GITHUB_TOKEN (or GH_TOKEN)     GitHub token used for HTTPS clone/push and the gh CLI
#   GIT_SSH_KEY_FILE               path to a private key (mounted secret) to use for SSH remotes
#   GIT_SSH_KNOWN_HOSTS_SCAN       "false" to skip ssh-keyscan of github.com
#
#   DRONE_SERVER / DRONE_TOKEN     read directly by the drone CLI; nothing to do here
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
mkdir -p "${CONFIG_DIR}" "${HOME}/.local/share/opencode"

# ---------------------------------------------------------------------------
# 0. home directory (may be a freshly provisioned, empty volume)
# ---------------------------------------------------------------------------
if [[ ! -e "${HOME}/.bashrc" && -d /etc/skel ]]; then
  log "seeding dotfiles into ${HOME} from /etc/skel"
  cp -rn /etc/skel/. "${HOME}/" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 1. opencode configuration
# ---------------------------------------------------------------------------
write_config() {
  if [[ -n "${OPENCODE_CONFIG_JSON:-}" ]]; then
    log "writing opencode.json from OPENCODE_CONFIG_JSON"
    printf '%s\n' "${OPENCODE_CONFIG_JSON}" | jq . > "${CONFIG_FILE}"
    return
  fi

  local provider="${OPENCODE_PROVIDER:-openrouter}"
  local key_env="${OPENCODE_PROVIDER_API_KEY_ENV:-}"
  if [[ -z "${key_env}" ]]; then
    key_env="$(printf '%s' "${provider}" | tr '[:lower:]-' '[:upper:]_')_API_KEY"
  fi

  if [[ -z "${!key_env:-}" ]]; then
    log "WARNING: ${key_env} is not set; opencode will have no credentials for provider '${provider}'"
  fi

  log "generating opencode.json for provider '${provider}' (api key from \$${key_env})"

  # The API key is referenced with {env:...} so the secret itself never lands on disk.
  jq -n \
    --arg provider "${provider}" \
    --arg keyref "{env:${key_env}}" \
    --arg model "${OPENCODE_MODEL:-}" \
    --arg small_model "${OPENCODE_SMALL_MODEL:-}" \
    --arg base_url "${OPENCODE_PROVIDER_BASE_URL:-}" \
    '
    {
      "$schema": "https://opencode.ai/config.json",
      autoupdate: false,
      provider: {
        ($provider): {
          options: (
            { apiKey: $keyref }
            + (if $base_url != "" then { baseURL: $base_url } else {} end)
          )
        }
      }
    }
    + (if $model != "" then { model: $model } else {} end)
    + (if $small_model != "" then { small_model: $small_model } else {} end)
    ' > "${CONFIG_FILE}"
}

if [[ -s "${CONFIG_FILE}" && "${OPENCODE_CONFIG_FORCE:-false}" != "true" ]]; then
  log "using existing ${CONFIG_FILE}"
else
  write_config
fi

# ---------------------------------------------------------------------------
# 2. git / GitHub
# ---------------------------------------------------------------------------
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name "${GIT_USER_NAME}"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "${GIT_USER_EMAIL}"
fi
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global --add safe.directory '*'

# Token over HTTPS: a credential helper that reads GITHUB_TOKEN / GH_TOKEN at
# call time, so the token is never written to disk.
if [[ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ]]; then
  log "GitHub token detected; enabling HTTPS credential helper for github.com"
  git config --global credential.https://github.com.helper /usr/local/bin/git-credential-github-env
  git config --global credential.https://gist.github.com.helper /usr/local/bin/git-credential-github-env
  # gh reads GH_TOKEN / GITHUB_TOKEN directly; nothing else to do.
fi

# SSH key from a mounted secret. Copy so we can enforce 0600 (secret mounts are
# read-only and may have permissive modes).
if [[ -n "${GIT_SSH_KEY_FILE:-}" ]]; then
  if [[ -r "${GIT_SSH_KEY_FILE}" ]]; then
    log "installing SSH key from ${GIT_SSH_KEY_FILE}"
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    install -m 0600 "${GIT_SSH_KEY_FILE}" "${HOME}/.ssh/id_git"
    cat > "${HOME}/.ssh/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${HOME}/.ssh/id_git
  IdentitiesOnly yes
EOF
    chmod 600 "${HOME}/.ssh/config"
    if [[ "${GIT_SSH_KNOWN_HOSTS_SCAN:-true}" == "true" ]]; then
      ssh-keyscan -t ed25519,ecdsa,rsa github.com >> "${HOME}/.ssh/known_hosts" 2>/dev/null || \
        log "WARNING: ssh-keyscan github.com failed (no network yet?)"
    fi
  else
    log "WARNING: GIT_SSH_KEY_FILE=${GIT_SSH_KEY_FILE} is not readable"
  fi
fi

# ---------------------------------------------------------------------------
# 3. run
# ---------------------------------------------------------------------------
if [[ "${1:-serve}" == "serve" ]]; then
  shift || true
  args=(serve --hostname "${OPENCODE_HOST:-0.0.0.0}" --port "${OPENCODE_PORT:-4096}")
  if [[ -n "${OPENCODE_CORS:-}" ]]; then
    # shellcheck disable=SC2206
    for origin in ${OPENCODE_CORS}; do
      args+=(--cors "${origin}")
    done
  fi
  log "starting: opencode ${args[*]} $*"
  exec opencode "${args[@]}" "$@"
fi

exec "$@"
