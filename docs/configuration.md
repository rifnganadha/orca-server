# Configuration

All operator settings live in `.env`. Docker Compose rejects missing required values. Copy
`.env.example` to `.env`, keep that file out of source control, and recreate or rebuild the
service according to the tables below.

[Back to README](../README.md) · [Operations](operations.md) · [Security](security.md)

## Orca

| Variable | Default | Description |
| --- | --- | --- |
| `ORCA_VERSION` | `v1.4.197` | Orca release downloaded during image build |
| `ORCA_PAIRING_ADDRESS` | required | Address advertised to Desktop and Mobile clients |
| `ORCA_PORT` | `6770` | Host port for Orca Web and pairing traffic |
| `ORCA_HOSTNAME` | `orca-server` | Hostname shown in terminals and tabs |
| `ORCA_WEB_USER` | required | Browser username |
| `ORCA_WEB_PASSWORD` | required | Browser password |
| `GIT_USER_NAME` | required | Global Git commit author name |
| `GIT_USER_EMAIL` | required | Global Git commit author email |
| `GH_TOKEN` | empty | Optional fine-grained GitHub token |
| `TZ` | `Asia/Jakarta` | IANA timezone used inside the container |

Pairing address examples:

```dotenv
# Private LAN
ORCA_PAIRING_ADDRESS=192.168.1.4

# Tailscale
ORCA_PAIRING_ADDRESS=100.64.0.10

# TLS reverse proxy
ORCA_PAIRING_ADDRESS=https://orca.example.com
```

A bare address receives `ORCA_PORT` automatically. Include an explicit port when external
routing uses a different one.

Apply runtime-only changes without rebuilding:

```bash
docker compose up -d --force-recreate orca
docker compose exec orca date
```

## Kilo Provider

The entrypoint renders Kilo configuration from `.env` at every startup. Provider changes
require recreation, not an image rebuild.

| Variable | Default | Description |
| --- | --- | --- |
| `KILO_PROVIDER_ID` | `9router` | Lowercase key used in `provider/model` |
| `KILO_PROVIDER_NAME` | `9Router` | Provider display name |
| `KILO_PROVIDER_NPM` | `@ai-sdk/openai-compatible` | AI SDK provider package |
| `KILO_BASE_URL` | `https://9router.example.com/v1` | OpenAI-compatible API base URL |
| `KILO_MODEL_ID` | `gpt-5.6-sol` | Model identifier sent to the provider |
| `KILO_MODEL_NAME` | `GPT-5.6 SOL` | Model display name |
| `KILO_API_KEY` | empty | Provider API key |

```dotenv
KILO_PROVIDER_ID=9router
KILO_PROVIDER_NAME=9Router
KILO_PROVIDER_NPM=@ai-sdk/openai-compatible
KILO_BASE_URL=https://9router.example.com/v1
KILO_MODEL_ID=gpt-5.6-sol
KILO_MODEL_NAME=GPT-5.6 SOL
KILO_API_KEY=replace-with-provider-api-key
```

`KILO_PROVIDER_ID` accepts lowercase letters, digits, periods, underscores, and hyphens.
The rendered config references `{env:KILO_API_KEY}` instead of writing the secret into it.

```bash
docker compose up -d --force-recreate orca
docker compose exec orca kilo debug config
```

## RepoWise

RepoWise runs in an isolated Python environment. It is exposed to Kilo as a local stdio MCP
server and serves a workspace dashboard on host port `7339`.

| Variable | Default | Description |
| --- | --- | --- |
| `REPOWISE_ENABLED` | `true` | Enables MCP tools and the dashboard |
| `REPOWISE_VERSION` | `0.48.0` | Version installed during image build |

Repositories below `/home/orca/orca/projects` are discovered automatically. Missing indexes
are initialized in deterministic no-prose mode. To initialize one manually:

```bash
cd /home/orca/orca/projects/example
repowise init --yes --no-prose --no-editor-setup
repowise status
```

`--no-prose` avoids model calls. `--no-editor-setup` prevents RepoWise from replacing the
global Kilo MCP integration. The generated `.repowise/` directory persists with the project.

The API and UI listen only on container loopback. At startup, the entrypoint creates an
ephemeral RepoWise API key and Nginx injects it into authenticated `/api/` proxy requests.
No static `REPOWISE_API_KEY` configuration is required.

## Build And Tool Versions

| Variable | Default | Description |
| --- | --- | --- |
| `NODE_VERSION` | `24.20.0` | Node.js LTS runtime used by npm-based installers |
| `SKILLS_CLI_VERSION` | `1.5.23` | CLI used to preinstall Orca agent skills |
| `KILO_CLI_VERSION` | `7.5.14` | Kilo CLI and Tree-sitter runtime assets |
| `REPOWISE_VERSION` | `0.48.0` | RepoWise CLI version |
| `DOCKER_CLI_VERSION` | `29.8.0` | Docker CLI image used during build |
| `DOCKER_GID` | `0` | Group allowed to access `docker.sock` |
| `DOCKER_PLATFORM` | `linux/amd64` | Build and runtime architecture |

Changing `NODE_VERSION`, `SKILLS_CLI_VERSION`, `KILO_CLI_VERSION`, `REPOWISE_VERSION`,
`DOCKER_CLI_VERSION`, or `ORCA_VERSION` requires an image rebuild.

## GitHub Authentication

For non-interactive startup, use a fine-grained token:

```dotenv
GH_TOKEN=github_pat_your_token
```

```bash
docker compose up -d --force-recreate orca
docker compose exec orca gh auth status
```

Alternatively, authenticate once with the device flow:

```bash
docker compose exec orca gh auth login --web --git-protocol https
docker compose exec orca gh auth status
```

GitHub CLI stores credentials under `/home/orca/.config/gh` in the persistent home volume.

## Managed Agents

Register supported accounts from a container shell:

```bash
docker compose exec orca bash
orca account add --agent claude
orca account add --agent codex
orca account list
```

In Orca, configure integration credentials as server-owned under **Settings > Remote Orca
Servers > Advanced**.
