# workstation

A containerised [opencode](https://opencode.ai) server on Debian stable, with a full
development toolchain, published to GitHub Container Registry together with a Helm chart.

| Artifact   | Location                                          |
| ---------- | ------------------------------------------------- |
| Image      | `ghcr.io/f-hj/workstation:<tag>`                  |
| Helm chart | `oci://ghcr.io/f-hj/charts/opencode --version <v>` |

## What is inside the image

- Debian `stable-slim`, non-root user `dev` (uid 1000) with passwordless `sudo`
- `build-essential`, cmake, pkg-config, libssl-dev, git, git-lfs, ripgrep, fd, fzf, jq
- GitHub CLI (`gh`) and Drone CI CLI (`drone`)
- Python 3 with `uv` and `uvx`
- Go (latest stable at build time)
- Node.js (latest at build time) with npm, yarn, corepack
- `opencode` (latest release at build time) started as `opencode serve` on port 4096

Every "latest" is resolved when the image is built. The workflow rebuilds weekly and
on every push to `main`; pin versions with build args or by dispatching the workflow:

```sh
docker build --build-arg NODE_VERSION=v24.20.0 --build-arg GO_VERSION=go1.27.1 --build-arg OPENCODE_VERSION=1.18.26 .
```

## Tags

| Event                | Image tags                                  | Chart version              |
| -------------------- | ------------------------------------------- | -------------------------- |
| push to `main`       | `main`, `sha-<short>`, `latest`             | `0.1.0-main.<sha>`         |
| tag `vX.Y.Z`         | `X.Y.Z`, `X.Y`, `X`, `sha-<short>`          | `X.Y.Z`                    |
| weekly schedule      | `weekly-YYYYMMDD`, `main`, `latest`         | `0.1.0-weekly-....<sha>`   |
| pull request         | build only, nothing pushed                  | packaged as artifact only  |

## Configuration (environment variables)

The entrypoint writes `~/.config/opencode/opencode.json` from these variables unless a
config file already exists (for instance one mounted from a ConfigMap).

| Variable                         | Default          | Purpose                                                              |
| -------------------------------- | ---------------- | -------------------------------------------------------------------- |
| `OPENCODE_PROVIDER`              | `openrouter`     | Provider id (`openrouter`, `anthropic`, `openai`, ...)               |
| `OPENROUTER_API_KEY`             |                  | API key. The name is `<PROVIDER>_API_KEY` unless overridden below    |
| `OPENCODE_PROVIDER_API_KEY_ENV`  | `<PROVIDER>_API_KEY` | Name of the variable holding the key                             |
| `OPENCODE_MODEL`                 |                  | Default model, e.g. `openrouter/anthropic/claude-sonnet-4.5`         |
| `OPENCODE_SMALL_MODEL`           |                  | Cheaper model for titles and summaries                               |
| `OPENCODE_PROVIDER_BASE_URL`     |                  | Custom base URL (proxy, self-hosted gateway)                         |
| `OPENCODE_CONFIG_JSON`           |                  | Complete `opencode.json`; written verbatim and wins over the above   |
| `OPENCODE_HOST` / `OPENCODE_PORT`| `0.0.0.0` / `4096` | Listen address                                                     |
| `OPENCODE_CORS`                  |                  | Space separated browser origins                                      |
| `OPENCODE_SERVER_PASSWORD`       |                  | Enables HTTP basic auth (user `OPENCODE_SERVER_USERNAME`, default `opencode`) |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` |                | Commit identity                                                      |
| `GITHUB_TOKEN` (or `GH_TOKEN`)   |                  | GitHub token for HTTPS clone/push and the `gh` CLI                   |
| `GIT_SSH_KEY_FILE`               |                  | Path to a mounted private key for SSH remotes                        |
| `DRONE_SERVER` / `DRONE_TOKEN`   |                  | Drone CI server URL and personal token, read by the `drone` CLI      |
| `SSH_AUTHORIZED_KEYS`            |                  | Public keys (one per line); when set, an sshd starts (see below)     |
| `SSH_AUTHORIZED_KEYS_FILE`       |                  | Same, from a file such as a mounted secret                           |
| `SSH_SERVER_PORT`                | `2222`           | sshd listen port                                                     |

A project-level `opencode.json` inside `/workspace` is merged on top as usual.

## Secrets and environment hygiene

opencode runs the agent's shell commands as the same user and with the same
environment as the server. To keep tokens out of `env`, out of child processes
(build scripts, `npm install` hooks) and out of the model's context, the
entrypoint moves every secret into the tool that needs it and then removes it
from the environment before `opencode serve` starts:

| Secret                       | Where it ends up                                                     | Used by                          |
| ---------------------------- | -------------------------------------------------------------------- | -------------------------------- |
| `OPENROUTER_API_KEY` (or `<PROVIDER>_API_KEY`) | `~/.config/workstation/secrets/<NAME>` (0600), referenced from `opencode.json` as `{file:...}` | opencode |
| `GITHUB_TOKEN` / `GH_TOKEN`  | `~/.config/workstation/secrets/github_token` (0600) and `gh auth login --with-token` | git (credential helper), `gh` |
| `DRONE_SERVER` / `DRONE_TOKEN` | `~/.config/drone/env` (0600), loaded by the `drone` wrapper only for the duration of a drone command | `drone` |
| `OPENCODE_SERVER_PASSWORD`   | stays in the environment: opencode reads it from there               | opencode                         |

After that the entrypoint also unsets:

- `KUBERNETES_*` and Kubernetes service links (`*_SERVICE_HOST`, `*_PORT_*`).
  The chart additionally sets `enableServiceLinks: false` and does not mount
  the service account token.
- Anything named `*_TOKEN`, `*_PASSWORD`, `*_PASSWD`, `*_SECRET`, `*_API_KEY`,
  `*_APIKEY`, `*_ACCESS_KEY`, `*_PRIVATE_KEY`, `*_CREDENTIALS`.

Set `OPENCODE_KEEP_ENV="NPM_TOKEN FOO_SECRET"` (chart: `opencode.keepEnv`) for
variables the agent genuinely needs, or `OPENCODE_SCRUB_ENV=false`
(`opencode.scrubEnv`) to disable scrubbing. The startup log lists what was removed.

Is `gh` logged in? Yes. It normally authenticates from `GH_TOKEN`/`GITHUB_TOKEN`
directly; since those are removed, the entrypoint runs `gh auth login
--with-token` once at startup, which stores the token in `~/.config/gh/hosts.yml`.
`gh auth status` shows the result. This needs network at startup; if it fails the
log says so and git still works through the file-based credential helper.

Limits: the agent runs as the same Unix user as the server, so it can still read
those 0600 files (just as it can read opencode's own `auth.json`). Scrubbing
keeps secrets out of casual `env` dumps and out of inherited environments; it is
not a sandbox. The files live on the home PVC, so they persist across restarts
and are refreshed from the environment on every start.

## SSH access to the workstation

Set `SSH_AUTHORIZED_KEYS` (or the chart's `sshServer.authorizedKeys`) and the
entrypoint starts an OpenSSH server next to opencode:

- Runs **unprivileged as `dev`** on port 2222. The pod drops all capabilities, so
  there is no root sshd and no port 22. Logging in is only possible as `dev`.
- **Key-only**: passwords and root login are disabled. `sudo` still works once
  inside, so treat an authorized key as full access to the container.
- **Stable host key**: generated once into `~/.ssh/host_keys` on the home volume.
  The fingerprint is printed in the log at startup.
- SFTP, agent forwarding and TCP forwarding are enabled, so `scp`, `rsync`,
  VS Code Remote-SSH and `ssh -L 4096:127.0.0.1:4096` all work.
- The container stops if either sshd or opencode exits, so Kubernetes restarts
  a broken pod instead of leaving half of it running.

Chart:

```yaml
sshServer:
  enabled: true
  authorizedKeys:
    - ssh-ed25519 AAAA... you@laptop
  service:
    type: NodePort      # or ClusterIP + kubectl port-forward
    nodePort: 30022     # optional fixed port
```

Then `ssh -p 30022 dev@<node-ip>`. Running `ssh -t -p 30022 dev@<node-ip> opencode`
gives you the full opencode TUI inside the pod, attached to the local server.
`sshServer.existingSecret` takes a Secret with an `authorized_keys` entry instead
of listing keys in values.

Docker: `-e SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" -p 2222:2222`.

## GitHub access: which key?

You have two options. Both are supported by the image; the token is the simpler one.

**Fine-grained personal access token (recommended).** Create it under
GitHub Settings, Developer settings, Personal access tokens, Fine-grained tokens.
Give it access to the repositories you want the agent to touch and these
permissions: `Contents: Read and write`, `Metadata: Read-only`, plus
`Pull requests: Read and write` if you want `gh pr create` to work. Set an
expiration. Pass it as `GITHUB_TOKEN`. At startup it is stored for git (a
credential helper reading a 0600 file) and for `gh` (`gh auth login`), then
removed from the environment. Clone with HTTPS URLs
(`https://github.com/you/repo.git`).

**SSH key (alternative).** Generate a dedicated `ed25519` key
(`ssh-keygen -t ed25519 -C opencode-workstation`) and add the public half to
your GitHub account as an *authentication key* (a deploy key only works for one
repository). Mount the private half as a secret and point `GIT_SSH_KEY_FILE` at
it. The entrypoint copies it with mode 0600 and adds `github.com` to
`known_hosts`. Clone with SSH URLs (`git@github.com:you/repo.git`).

Classic tokens with the `repo` scope also work but grant access to every
repository you own. Prefer the fine-grained token.

## Run with Docker

```sh
docker run -d --name opencode \
  -p 4096:4096 \
  -e OPENROUTER_API_KEY=sk-or-... \
  -e OPENCODE_MODEL=openrouter/anthropic/claude-sonnet-4.5 \
  -e OPENCODE_SERVER_PASSWORD=change-me \
  -e GITHUB_TOKEN=github_pat_... \
  -e GIT_USER_NAME="Your Name" -e GIT_USER_EMAIL=you@example.com \
  -v opencode-workspace:/workspace \
  -v opencode-home:/home/dev \
  ghcr.io/f-hj/workstation:latest

curl -u opencode:change-me http://127.0.0.1:4096/global/health
```

Attach the opencode TUI from your machine:

```sh
opencode attach http://opencode:change-me@127.0.0.1:4096
```

Or get a shell in the workstation:

```sh
docker exec -it opencode bash
```

## Deploy with Helm

Create the secret yourself (recommended) and install the chart:

```sh
kubectl create namespace opencode
kubectl -n opencode create secret generic opencode \
  --from-literal=OPENROUTER_API_KEY=sk-or-... \
  --from-literal=GITHUB_TOKEN=github_pat_... \
  --from-literal=OPENCODE_SERVER_PASSWORD=change-me \
  --from-literal=DRONE_TOKEN=...

helm upgrade --install opencode oci://ghcr.io/f-hj/charts/opencode \
  --namespace opencode \
  --set secrets.existingSecret=opencode \
  --set opencode.model=openrouter/anthropic/claude-sonnet-4.5 \
  --set git.userName="Your Name" \
  --set git.userEmail=you@example.com \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set 'ingress.hosts[0].host=opencode.example.com' \
  --set 'ingress.hosts[0].paths[0].path=/' \
  --set 'ingress.hosts[0].paths[0].pathType=Prefix'
```

Or a `values.yaml`:

```yaml
opencode:
  model: openrouter/anthropic/claude-sonnet-4.5
  cors: https://app.example.com
git:
  userName: Your Name
  userEmail: you@example.com
drone:
  server: https://drone.example.com
secrets:
  existingSecret: opencode        # keys: OPENROUTER_API_KEY, GITHUB_TOKEN, OPENCODE_SERVER_PASSWORD, DRONE_TOKEN
ssh:
  existingSecret: opencode-ssh    # optional, key id_ed25519
persistence:
  workspace:
    size: 50Gi
    storageClass: fast
  home:
    size: 20Gi
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: opencode.example.com
  tls:
    clusterIssuer: letsencrypt   # cert-manager requests the certificate
resources:
  requests: { cpu: 500m, memory: 1Gi }
  limits: { cpu: "4", memory: 8Gi }
```

Chart notes:

- Two `ReadWriteOnce` PVCs are created: `/workspace` (repositories) and
  `/home/dev` (the whole home: opencode sessions and auth, Go module cache,
  npm/yarn/uv caches, `gh` and `drone` config, shell history). The Deployment
  uses the `Recreate` strategy for that reason. When the home volume starts
  empty the entrypoint seeds dotfiles from `/etc/skel`.
- `config.enabled=true` mounts `config.content` as `opencode.json` and disables
  the env-based generation.
- Private registry: point at an existing pull secret with
  `image.pullSecret: my-registry` (or `--set image.pullSecret=my-registry`),
  list several with `imagePullSecrets: [{ name: other }]`, or let the chart
  create one:

  ```yaml
  imageCredentials:
    create: true
    registry: ghcr.io
    username: f-hj
    password: ghp_...   # token with read:packages
  ```

  The generated `kubernetes.io/dockerconfigjson` Secret is attached to the pod
  automatically.
- Probes are TCP so they keep working when basic auth is enabled.
- An `ingress.hosts` entry without `paths` gets `/` with `pathType: Prefix`, so
  a values file only needs `- host: opencode.example.com`.
- HTTPS is on by default when the Ingress is enabled: one TLS block covers all
  hosts with the secret `<release>-opencode-tls` (override with
  `ingress.tls.secretName`). Set `ingress.tls.clusterIssuer` or
  `ingress.tls.issuer` and cert-manager issues the certificate; without one, the
  secret must already exist. `ingress.forceHttps` (default `true`) adds the
  HTTP-to-HTTPS redirect annotations for ingress-nginx and Traefik. Set
  `ingress.tls.enabled: false` for plain HTTP.
- The pod runs as uid/gid 1000 with `fsGroup: 1000`.

## Repository layout

```
Dockerfile                          image definition
scripts/docker-entrypoint.sh        secrets to files, config generation, git/GitHub setup, env scrub, opencode serve
scripts/git-credential-github-file  git credential helper reading the stored GitHub token
scripts/drone-wrapper               drone CLI wrapper loading DRONE_SERVER/DRONE_TOKEN from a file
charts/opencode/                    Helm chart
.github/workflows/release.yml       build, push image (amd64+arm64) and chart to GHCR
```

## Releasing

```sh
git tag v0.1.0
git push origin v0.1.0
```

The workflow publishes `ghcr.io/f-hj/workstation:0.1.0` and chart version `0.1.0`
with `appVersion: 0.1.0`.
