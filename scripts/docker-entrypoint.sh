#!/usr/bin/env bash
# Entrypoint for the opencode workstation image.
#
# Responsibilities:
#   0. Seed dotfiles when the home directory is a fresh, empty volume.
#   1. Move secrets out of the environment into each tool's own store
#      (0600 files under $HOME) so the agent's shell does not inherit them.
#   2. Generate ~/.config/opencode/opencode.json from environment variables
#      (unless a config file is already present, e.g. mounted from a ConfigMap).
#   3. Configure git identity and GitHub credentials (token and/or SSH key).
#   4. Scrub the environment (consumed secrets, *_TOKEN/*_PASSWORD/..., KUBERNETES_*).
#   5. Start `opencode serve` bound to all interfaces, or run the given command.
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
#   OPENCODE_SERVER_PASSWORD       enable HTTP basic auth (read by opencode itself, stays in env)
#   OPENCODE_SERVER_USERNAME       basic auth user, default "opencode" (read by opencode itself)
#
#   GIT_USER_NAME / GIT_USER_EMAIL git identity for commits
#   GITHUB_TOKEN (or GH_TOKEN)     GitHub token; stored for git (credential helper) and gh, then unset
#   GIT_SSH_KEY_FILE               path to a private key (mounted secret) to use for SSH remotes
#   GIT_SSH_KNOWN_HOSTS_SCAN       "false" to skip ssh-keyscan of github.com
#
#   DRONE_SERVER / DRONE_TOKEN     Drone CI; stored for the drone wrapper, then unset
#
#   SSH_AUTHORIZED_KEYS            public keys (one per line) allowed to ssh in as the
#                                  container user; starts an unprivileged sshd when set
#   SSH_AUTHORIZED_KEYS_FILE       same, read from a file (e.g. a mounted secret)
#   SSH_SERVER_PORT                sshd port, default 2222
#
#   OPENCODE_SCRUB_ENV             "false" to disable environment scrubbing
#   OPENCODE_KEEP_ENV              space/comma separated variable names exempt from scrubbing
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
CONFIG_DIR="${XDG_CONFIG_HOME}/opencode"
CONFIG_FILE="${CONFIG_DIR}/opencode.json"
SECRETS_DIR="${XDG_CONFIG_HOME}/workstation/secrets"

# Variables consumed here and removed from opencode's environment.
CONSUMED_VARS=()

# Write a secret to a 0600 file (no trailing newline).
write_secret() { # name value
  install -d -m 0700 "${SECRETS_DIR}"
  (umask 077; printf '%s' "$2" > "${SECRETS_DIR}/$1")
}

# ---------------------------------------------------------------------------
# 0. home directory (may be a freshly provisioned, empty volume)
# ---------------------------------------------------------------------------
if [[ ! -e "${HOME}/.bashrc" && -d /etc/skel ]]; then
  log "seeding dotfiles into ${HOME} from /etc/skel"
  cp -rn /etc/skel/. "${HOME}/" 2>/dev/null || true
fi
mkdir -p "${CONFIG_DIR}" "${HOME}/.local/share/opencode"

# ---------------------------------------------------------------------------
# 1. provider API key -> file
# ---------------------------------------------------------------------------
PROVIDER="${OPENCODE_PROVIDER:-openrouter}"
KEY_ENV="${OPENCODE_PROVIDER_API_KEY_ENV:-}"
if [[ -z "${KEY_ENV}" ]]; then
  KEY_ENV="$(printf '%s' "${PROVIDER}" | tr '[:lower:]-' '[:upper:]_')_API_KEY"
fi
KEY_FILE="${SECRETS_DIR}/${KEY_ENV}"

if [[ -n "${!KEY_ENV:-}" ]]; then
  log "storing \$${KEY_ENV} in ${KEY_FILE}"
  write_secret "${KEY_ENV}" "${!KEY_ENV}"
  CONSUMED_VARS+=("${KEY_ENV}")
elif [[ -s "${KEY_FILE}" ]]; then
  log "reusing ${KEY_FILE} from a previous start"
else
  log "WARNING: ${KEY_ENV} is not set; opencode will have no credentials for provider '${PROVIDER}'"
fi

# ---------------------------------------------------------------------------
# 2. opencode configuration
# ---------------------------------------------------------------------------
write_config() {
  if [[ -n "${OPENCODE_CONFIG_JSON:-}" ]]; then
    log "writing opencode.json from OPENCODE_CONFIG_JSON"
    (umask 077; printf '%s\n' "${OPENCODE_CONFIG_JSON}" | jq . > "${CONFIG_FILE}")
    return
  fi

  log "generating opencode.json for provider '${PROVIDER}' (api key from ${KEY_FILE})"

  # The key is referenced with {file:...}; the secret is not in the config nor in the env.
  jq -n \
    --arg provider "${PROVIDER}" \
    --arg keyref "{file:${KEY_FILE}}" \
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
CONSUMED_VARS+=(OPENCODE_CONFIG_JSON OPENCODE_CONFIG_FORCE OPENCODE_PROVIDER_API_KEY_ENV OPENCODE_PROVIDER_BASE_URL)

# ---------------------------------------------------------------------------
# 3. git / GitHub / Drone
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
CONSUMED_VARS+=(GIT_USER_NAME GIT_USER_EMAIL)

# GitHub token: stored once, then removed from the environment.
#   - git: credential helper that reads the token file on each call
#   - gh:  `gh auth login --with-token` stores it in ~/.config/gh/hosts.yml
GH_TOKEN_VALUE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -n "${GH_TOKEN_VALUE}" ]]; then
  log "storing GitHub token for git and gh"
  write_secret github_token "${GH_TOKEN_VALUE}"
  git config --global credential.https://github.com.helper /usr/local/bin/git-credential-github-file
  git config --global credential.https://gist.github.com.helper /usr/local/bin/git-credential-github-file
  if command -v gh >/dev/null 2>&1; then
    # gh ignores hosts.yml while GH_TOKEN/GITHUB_TOKEN are set, so log in without them.
    if env -u GH_TOKEN -u GITHUB_TOKEN gh auth login --hostname github.com --git-protocol https --with-token \
        < "${SECRETS_DIR}/github_token" >/dev/null 2>&1; then
      log "gh: logged in (credentials in ${XDG_CONFIG_HOME}/gh/hosts.yml)"
    else
      log "WARNING: gh auth login failed (no network yet? invalid token?); run 'gh auth login' manually"
    fi
  fi
  CONSUMED_VARS+=(GITHUB_TOKEN GH_TOKEN)
fi
unset GH_TOKEN_VALUE

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
  CONSUMED_VARS+=(GIT_SSH_KEY_FILE GIT_SSH_KNOWN_HOSTS_SCAN)
fi

# Drone CLI: /usr/local/bin/drone is a wrapper that sources this file.
if [[ -n "${DRONE_TOKEN:-}${DRONE_SERVER:-}" ]]; then
  log "storing Drone settings for the drone wrapper"
  install -d -m 0700 "${XDG_CONFIG_HOME}/drone"
  (umask 077; {
    [[ -n "${DRONE_SERVER:-}" ]] && printf 'export DRONE_SERVER=%q\n' "${DRONE_SERVER}"
    [[ -n "${DRONE_TOKEN:-}"  ]] && printf 'export DRONE_TOKEN=%q\n'  "${DRONE_TOKEN}"
    true
  } > "${XDG_CONFIG_HOME}/drone/env")
  CONSUMED_VARS+=(DRONE_SERVER DRONE_TOKEN)
fi

# ---------------------------------------------------------------------------
# 3b. SSH server (unprivileged sshd, key-only, logs in as the container user)
# ---------------------------------------------------------------------------
SSHD_CONFIG=""
if [[ -n "${SSH_AUTHORIZED_KEYS:-}" || -n "${SSH_AUTHORIZED_KEYS_FILE:-}" ]]; then
  SSH_PORT="${SSH_SERVER_PORT:-2222}"
  ME="$(id -un)"
  mkdir -p "${HOME}/.ssh/host_keys"
  chmod 700 "${HOME}/.ssh"
  # Best effort: fsGroup leaves the home volume group writable; fails silently
  # when the mount point is owned by root.
  chmod g-w,o-w "${HOME}" 2>/dev/null || true

  # authorized_keys from env and/or file
  {
    [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]] && printf '%s\n' "${SSH_AUTHORIZED_KEYS}"
    [[ -n "${SSH_AUTHORIZED_KEYS_FILE:-}" && -r "${SSH_AUTHORIZED_KEYS_FILE}" ]] && cat "${SSH_AUTHORIZED_KEYS_FILE}"
    true
  } | grep -v '^[[:space:]]*$' > "${HOME}/.ssh/authorized_keys" || true
  chmod 600 "${HOME}/.ssh/authorized_keys"
  KEY_COUNT="$(wc -l < "${HOME}/.ssh/authorized_keys")"

  # host keys persist in the home volume so the fingerprint is stable
  [[ -f "${HOME}/.ssh/host_keys/ssh_host_ed25519_key" ]] || \
    ssh-keygen -q -N '' -t ed25519 -f "${HOME}/.ssh/host_keys/ssh_host_ed25519_key"
  [[ -f "${HOME}/.ssh/host_keys/ssh_host_rsa_key" ]] || \
    ssh-keygen -q -N '' -t rsa -b 4096 -f "${HOME}/.ssh/host_keys/ssh_host_rsa_key"

  SSHD_CONFIG="${XDG_CONFIG_HOME}/workstation/sshd_config"
  install -d -m 0700 "${XDG_CONFIG_HOME}/workstation"
  cat > "${SSHD_CONFIG}" <<EOF
Port ${SSH_PORT}
ListenAddress 0.0.0.0
HostKey ${HOME}/.ssh/host_keys/ssh_host_ed25519_key
HostKey ${HOME}/.ssh/host_keys/ssh_host_rsa_key
PidFile none
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile ${HOME}/.ssh/authorized_keys
PermitRootLogin no
AllowUsers ${ME}
# The home directory is a Kubernetes volume with fsGroup applied (group
# writable, often root owned), which StrictModes rejects. authorized_keys is
# written by the entrypoint in this single-user container, so the check
# adds nothing here.
StrictModes no
X11Forwarding no
AllowTcpForwarding yes
AllowAgentForwarding yes
ClientAliveInterval 60
ClientAliveCountMax 3
LogLevel INFO
Subsystem sftp /usr/lib/openssh/sftp-server
EOF
  if (( KEY_COUNT == 0 )); then
    log "WARNING: SSH server requested but no authorized keys found; not starting sshd"
    SSHD_CONFIG=""
  else
    log "SSH server: ${KEY_COUNT} authorized key(s), port ${SSH_PORT}, user ${ME}, key-only"
    log "SSH host key: $(ssh-keygen -lf "${HOME}/.ssh/host_keys/ssh_host_ed25519_key.pub")"
  fi
  CONSUMED_VARS+=(SSH_AUTHORIZED_KEYS SSH_AUTHORIZED_KEYS_FILE SSH_SERVER_PORT)
fi

# ---------------------------------------------------------------------------
# 4. scrub the environment
# ---------------------------------------------------------------------------
if [[ "${OPENCODE_SCRUB_ENV:-true}" == "true" ]]; then
  keep=" OPENCODE_SERVER_PASSWORD OPENCODE_SERVER_USERNAME "
  keep+=" $(printf '%s' "${OPENCODE_KEEP_ENV:-}" | tr ',' ' ') "
  consumed=" ${CONSUMED_VARS[*]} "

  scrubbed=()
  for var in $(compgen -e); do
    [[ "${keep}" == *" ${var} "* ]] && continue
    if [[ "${consumed}" != *" ${var} "* ]]; then
      case "${var}" in
        # kubernetes downward env and service links
        KUBERNETES_*|*_SERVICE_HOST|*_SERVICE_PORT|*_SERVICE_PORT_*|*_PORT_*_TCP*|*_PORT_*_UDP*) ;;
        # secret-looking names
        *_TOKEN|*_PASSWORD|*_PASSWD|*_SECRET|*_SECRET_*|*_API_KEY|*_APIKEY|*_ACCESS_KEY|*_PRIVATE_KEY|*_CREDENTIALS) ;;
        *) continue ;;
      esac
    fi
    unset "${var}"
    scrubbed+=("${var}")
  done
  # *_PORT for kubernetes service links (e.g. FOO_PORT=tcp://10.0.0.1:80), keep PORT itself
  for var in $(compgen -e); do
    [[ "${var}" == *_PORT && "${!var}" == tcp://* ]] || continue
    [[ "${keep}" == *" ${var} "* ]] && continue
    unset "${var}"
    scrubbed+=("${var}")
  done
  if ((${#scrubbed[@]})); then
    log "removed from environment: ${scrubbed[*]}"
  fi
  unset OPENCODE_KEEP_ENV OPENCODE_SCRUB_ENV keep consumed scrubbed var
fi

# ---------------------------------------------------------------------------
# 5. run
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
  if [[ -z "${SSHD_CONFIG}" ]]; then
    log "starting: opencode ${args[*]} $*"
    exec opencode "${args[@]}" "$@"
  fi

  # Run sshd and opencode side by side; if either exits, stop the other so the
  # container restarts cleanly.
  log "starting: sshd -f ${SSHD_CONFIG}"
  /usr/sbin/sshd -D -e -f "${SSHD_CONFIG}" &
  sshd_pid=$!
  log "starting: opencode ${args[*]} $*"
  opencode "${args[@]}" "$@" &
  oc_pid=$!

  forward() { kill -TERM "${sshd_pid}" "${oc_pid}" 2>/dev/null || true; }
  trap forward TERM INT

  wait -n "${sshd_pid}" "${oc_pid}"
  code=$?
  if kill -0 "${oc_pid}" 2>/dev/null; then
    log "sshd exited (${code}); stopping opencode"
  else
    log "opencode exited (${code}); stopping sshd"
  fi
  forward
  wait "${sshd_pid}" "${oc_pid}" 2>/dev/null || true
  exit "${code}"
fi

exec "$@"
