# workstation

A containerised [opencode](https://opencode.ai) server on Debian stable, with a full
development toolchain, published to GitHub Container Registry together with a Helm chart.

| Artifact   | Location                                          |
| ---------- | ------------------------------------------------- |
| Image      | `ghcr.io/f-hj/workstation:<tag>`                  |
| Helm chart | `oci://ghcr.io/f-hj/charts/opencode --version <v>` |

## What is inside the image

- Debian `stable-slim`, non-root user `dev` (uid 1000) with passwordless `sudo`
- `build-essential`, cmake, pkg-config, libssl-dev, python3, git, git-lfs, `gh`, ripgrep, fd, fzf, jq
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

The API key is referenced from the config as `{env:OPENROUTER_API_KEY}`, so the secret
itself is never written to disk. A project-level `opencode.json` inside `/workspace`
is merged on top as usual.

## GitHub access: which key?

You have two options. Both are supported by the image; the token is the simpler one.

**Fine-grained personal access token (recommended).** Create it under
GitHub Settings, Developer settings, Personal access tokens, Fine-grained tokens.
Give it access to the repositories you want the agent to touch and these
permissions: `Contents: Read and write`, `Metadata: Read-only`, plus
`Pull requests: Read and write` if you want `gh pr create` to work. Set an
expiration. Pass it as `GITHUB_TOKEN`. Git uses it through a credential helper
that reads the environment on each call, and `gh` picks it up automatically.
Clone with HTTPS URLs (`https://github.com/you/repo.git`).

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
  -v opencode-data:/home/dev/.local/share/opencode \
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
  --from-literal=OPENCODE_SERVER_PASSWORD=change-me

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
secrets:
  existingSecret: opencode        # keys: OPENROUTER_API_KEY, GITHUB_TOKEN, OPENCODE_SERVER_PASSWORD
ssh:
  existingSecret: opencode-ssh    # optional, key id_ed25519
persistence:
  workspace:
    size: 50Gi
    storageClass: fast
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  hosts:
    - host: opencode.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - secretName: opencode-tls
      hosts: [opencode.example.com]
resources:
  requests: { cpu: 500m, memory: 1Gi }
  limits: { cpu: "4", memory: 8Gi }
```

Chart notes:

- Two `ReadWriteOnce` PVCs are created: `/workspace` (repositories) and
  `/home/dev/.local/share/opencode` (sessions, storage). The Deployment uses the
  `Recreate` strategy for that reason.
- `config.enabled=true` mounts `config.content` as `opencode.json` and disables
  the env-based generation.
- Probes are TCP so they keep working when basic auth is enabled.
- The pod runs as uid/gid 1000 with `fsGroup: 1000`.

## Repository layout

```
Dockerfile                          image definition
scripts/docker-entrypoint.sh        config generation, git/GitHub setup, opencode serve
scripts/git-credential-github-env   git credential helper reading GITHUB_TOKEN
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
