# Orca Remote Server on Docker

Run [Orca](https://www.onorca.dev/) as an always-on, headless Docker service and pair desktop, mobile, or browser clients with it.

This image extracts a pinned Orca AppImage without FUSE, runs `orca serve` as an unprivileged user, persists the Orca home directory, and includes the tools needed for remote agent workflows.

[Quick Start](#quick-start) | [Configuration](#configuration) | [Project Containers](#run-project-containers) | [Operations](#operations) | [Troubleshooting](#troubleshooting) | [Security](#security)

## Features

- Headless Orca runtime for `amd64` and `arm64`
- Authenticated Orca Web, Desktop pairing, and Mobile pairing pages
- Persistent projects, worktrees, credentials, configuration, and terminal history
- Kilo Code CLI with a dynamic OpenAI-compatible provider
- Codebase Memory MCP with an authenticated graph UI
- GitHub CLI and non-interactive token support
- Docker CLI, Compose, and Buildx through the host Docker socket
- Deliberate, pinned upgrades with checksum verification for Codebase Memory
- Unprivileged runtime without FUSE or `--privileged`

## Requirements

- Docker Engine with the Compose plugin
- An `amd64` or `arm64` Linux host, or Docker Desktop
- A private network such as Tailscale/WireGuard, or an authenticated TLS reverse proxy with WebSocket support

## Quick Start

1. Create the local environment file:

```bash
cp .env.example .env
```

2. Set at least these values in `.env`:

```dotenv
ORCA_PAIRING_ADDRESS=192.168.1.4
ORCA_WEB_USER=orca
ORCA_WEB_PASSWORD=replace-with-a-long-random-password
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@example.com
KILO_API_KEY=replace-with-provider-api-key
```

`ORCA_PAIRING_ADDRESS` must be reachable by the clients you intend to pair. Use a LAN IP, Tailscale address, hostname, or HTTPS reverse-proxy URL.

3. Set the Docker socket group ID. Docker Desktop commonly uses `0`; Linux hosts can query it directly:

```bash
stat -c '%g' /var/run/docker.sock
```

```dotenv
DOCKER_GID=0
```

4. Build and start Orca:

```bash
docker compose up -d --build
docker compose logs -f orca
```

5. Confirm service health:

```bash
docker compose ps
```

## Endpoints

| URL | Purpose | Authentication |
|---|---|---|
| `http://localhost:6770` | Orca Web | `ORCA_WEB_USER` / `ORCA_WEB_PASSWORD` |
| `http://localhost:6770/desktop` | Desktop pairing QR | Orca Web credentials |
| `http://localhost:6770/mobile` | Mobile pairing QR | Orca Web credentials |
| `http://localhost:9749` | Codebase Memory graph UI | Orca Web credentials |

The default host ports are controlled by `ORCA_PORT` and `CODEBASE_MEMORY_PORT`.

Pairing URLs and QR codes are credentials. Do not put them in source control, screenshots, issue trackers, or synchronized browser history.

## Configuration

All operator configuration lives in `.env`. Compose refuses to start when required values are missing.

### Orca

| Variable | Default | Description |
|---|---|---|
| `ORCA_VERSION` | `v1.4.188` | Pinned Orca release downloaded during the build |
| `ORCA_PAIRING_ADDRESS` | required | Address advertised to Desktop and Mobile clients |
| `ORCA_PORT` | `6770` | Host port for Orca Web and pairing traffic |
| `ORCA_HOSTNAME` | `orca-server` | Hostname shown in terminals and tab titles |
| `ORCA_WEB_USER` | required | Browser and graph UI username |
| `ORCA_WEB_PASSWORD` | required | Browser and graph UI password |
| `GIT_USER_NAME` | required | Global Git commit author name |
| `GIT_USER_EMAIL` | required | Global Git commit author email |
| `GH_TOKEN` | empty | Optional fine-grained GitHub token |

Pairing address examples:

```dotenv
# Private LAN:
ORCA_PAIRING_ADDRESS=192.168.1.4

# Tailscale:
ORCA_PAIRING_ADDRESS=100.64.0.10

# TLS reverse proxy:
ORCA_PAIRING_ADDRESS=https://orca.example.com
```

A bare address receives `ORCA_PORT` automatically. Include an explicit port in `ORCA_PAIRING_ADDRESS` when external routing uses another port.

### Kilo Provider

The entrypoint renders Kilo's provider configuration from `.env` every time the container starts. Provider changes require container recreation, not an image rebuild.

| Variable | Default | Description |
|---|---|---|
| `KILO_PROVIDER_ID` | `9router` | Lowercase provider key used in `provider/model` |
| `KILO_PROVIDER_NAME` | `9Router` | Provider display name |
| `KILO_PROVIDER_NPM` | `@ai-sdk/openai-compatible` | AI SDK provider package |
| `KILO_BASE_URL` | `https://9router.akasia.dev/v1` | OpenAI-compatible API base URL |
| `KILO_MODEL_ID` | `gpt-5.6-sol` | Model identifier sent to the provider |
| `KILO_MODEL_NAME` | `GPT-5.6 SOL` | Model display name |
| `KILO_API_KEY` | empty | Provider API key |

Example:

```dotenv
KILO_PROVIDER_ID=9router
KILO_PROVIDER_NAME=9Router
KILO_PROVIDER_NPM=@ai-sdk/openai-compatible
KILO_BASE_URL=https://9router.akasia.dev/v1
KILO_MODEL_ID=gpt-5.6-sol
KILO_MODEL_NAME=GPT-5.6 SOL
KILO_API_KEY=replace-with-provider-api-key
```

`KILO_PROVIDER_ID` accepts lowercase letters, digits, periods, underscores, and hyphens. The generated config keeps the API key as `{env:KILO_API_KEY}` instead of writing the secret into the file.

Apply and inspect provider changes:

```bash
docker compose up -d --force-recreate orca
docker compose exec orca kilo debug config
```

### Codebase Memory

| Variable | Default | Description |
|---|---|---|
| `CODEBASE_MEMORY_VERSION` | `v0.10.8` | Pinned Codebase Memory release |
| `CODEBASE_MEMORY_PORT` | `9749` | Authenticated graph UI host port |

The build downloads the architecture-specific portable binary and validates its published SHA-256 checksum. Graph data persists at `/home/orca/.local/share/codebase-memory-mcp` in the `orca-home` volume.

Verify the integration:

```bash
docker compose exec orca codebase-memory-mcp --version
docker compose exec orca kilo mcp list
```

### Docker Engine

| Variable | Default | Description |
|---|---|---|
| `DOCKER_CLI_VERSION` | `29.1.3` | Docker CLI image used during the build |
| `DOCKER_GID` | `0` | Supplementary group allowed to access `docker.sock` |

The container mounts `/var/run/docker.sock` and uses Docker-outside-of-Docker. Commands inside Orca control the host engine:

```bash
docker compose exec orca docker version
docker compose exec orca docker compose version
docker compose exec orca docker ps
```

Docker socket access is effectively root-level host access. See [Security](#security) before enabling untrusted agent access.

## Agent Authentication

### GitHub

Set a fine-grained token for non-interactive startup:

```dotenv
GH_TOKEN=github_pat_your_token
```

```bash
docker compose up -d --force-recreate orca
docker compose exec orca gh auth status
```

Alternatively, use GitHub's device flow once:

```bash
docker compose exec orca gh auth login --web --git-protocol https
docker compose exec orca gh auth status
```

GitHub CLI stores credentials under `/home/orca/.config/gh` in the persistent home volume.

### Managed Agents

Open a container shell to register supported accounts:

```bash
docker compose exec orca bash
orca account add --agent claude
orca account add --agent codex
orca account list
```

In Orca, configure integration credentials as server-owned under **Settings > Remote Orca Servers > Advanced**.

## Run Project Containers

Orca projects live under `/home/orca/orca/projects`. Docker and Compose commands can run directly from an Orca terminal:

```bash
cd /home/orca/orca/projects/example
docker compose up -d
docker compose ps
docker compose logs -f
```

### Publish Application Ports

Map a host port to the port on which the child application actually listens. For example, `docker/welcome-to-docker` listens on container port `80`:

```yaml
services:
  app:
    image: docker/welcome-to-docker
    container_name: welcome
    restart: unless-stopped
    ports:
      - "3001:80"
```

Open the published application from Windows or Orca Web:

```text
http://localhost:3001
```

Processes running inside `orca-server` have a separate loopback interface. From an Orca terminal or agent tool, use Docker Desktop's host gateway:

```text
http://host.docker.internal:3001
```

A mapping such as `3001:3001` only works when the child application listens on port `3001`. If it listens on `80`, use `3001:80`.

### Bind-Mount Caveat

The host daemon resolves bind-mount source paths on the host, not inside `orca-server`. A container path such as `/home/orca/orca/projects/example` cannot be passed directly to `docker run -v`. Use a named volume, a host bind-mounted project root, or a Docker build context.

## Operations

### Status and Logs

```bash
docker compose ps
docker compose logs -f orca
docker compose exec orca kilo mcp list
```

### Backup

Stop Orca for a consistent archive of the persistent home volume:

```bash
docker compose stop orca
mkdir -p backups
docker run --rm \
  -v orca-server_orca-home:/source:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf /backup/orca-home.tgz -C /source .
docker compose start orca
```

Compose derives volume names from the project directory. Confirm the actual name with `docker volume ls` if you changed the Compose project name.

### Upgrade

Update pinned versions in `.env`, back up the home volume, then rebuild:

```bash
docker compose build --pull
docker compose up -d
docker compose logs -f orca
```

BuildKit cache mounts reuse downloaded Debian packages. Use `docker compose build --pull --no-cache` only for a full dependency refresh or cache troubleshooting.

New Orca releases can migrate persisted state. Restoring an older image may also require restoring the matching volume backup.

## Troubleshooting

### Child App Returns an Empty Response

Confirm the internal listener and published mapping:

```bash
docker exec <container> ss -lntp
docker logs <container>
docker inspect <container> --format '{{json .NetworkSettings.Ports}}'
```

The host side of `HOST:CONTAINER` is the browser-facing port. The container side must match the application's internal listener.

### Docker Permission Denied

Check socket ownership on the host and group membership inside Orca:

```bash
stat -c '%u %g %a' /var/run/docker.sock
docker compose exec orca id
docker compose exec orca stat -c '%u %g %a' /var/run/docker.sock
```

Set `DOCKER_GID` to the socket's group ID and recreate the service.

### Client Cannot Pair

- Confirm `ORCA_PAIRING_ADDRESS` is reachable from the client.
- Keep the host firewall open for `ORCA_PORT` only on trusted networks.
- Disable guest-network or access-point client isolation.
- Ensure a reverse proxy supports WebSocket upgrades.

On a Windows Docker host, allow the default port on Private networks from an elevated PowerShell prompt:

```powershell
New-NetFirewallRule -DisplayName "Orca Server TCP 6770" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 6770 -Profile Private
```

## Persistence

The `orca-home` volume stores:

- Projects and worktrees under `/home/orca/orca`
- Orca state and paired-device keys
- Kilo, GitHub CLI, and agent credentials
- Terminal history and user configuration
- Codebase Memory indexes

`/home/orca/.cache` is a disposable tmpfs mount and is cleared when the container is recreated.

## Security

- Never expose Orca or the graph UI directly to the public Internet.
- Prefer Tailscale, WireGuard, SSH forwarding, or an authenticated TLS reverse proxy.
- Treat pairing grants and QR codes as passwords.
- Use a long, unique `ORCA_WEB_PASSWORD` and HTTPS on untrusted networks.
- Restrict `GH_TOKEN` to the minimum repository permissions required.
- Docker socket access allows agents to start privileged containers, mount host filesystems, inspect other containers, and access host-managed secrets.
- Do not provide this deployment to untrusted users or agents.
- The container itself runs as the unprivileged `orca` user and does not require `--privileged`.
- Headless Orca does not auto-update; upgrades are explicit image rebuilds.
- Embedded browser computer-use features are limited on a headless VPS.

## Project Layout

```text
.
|-- .codebase-memory/       # Optional shared graph snapshot
|-- docker/
|   |-- entrypoint.sh       # Startup, configuration, pairing, and UI lifecycle
|   |-- kilo/kilo.jsonc     # Provider-neutral Kilo template
|   |-- nginx/nginx.conf    # Authenticated Orca and graph UI proxy
|   `-- web/                # Login, landing, pairing, and compatibility assets
|-- .env.example            # Operator configuration template
|-- Dockerfile              # Multi-stage Orca, Docker CLI, Kilo, and MCP image
|-- docker-compose.yml      # Runtime service, ports, volume, and socket mount
`-- README.md
```

Local `.kilo/` state is excluded from Git and Docker. Runtime credentials, rendered pairing pages, and generated nginx configuration remain ephemeral.

## References

- [Remote Orca Servers](https://www.onorca.dev/docs/remote-servers)
- [Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md)
- [Codebase Memory MCP](https://github.com/DeusData/codebase-memory-mcp)
