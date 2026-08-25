# Orca Remote Server on Docker

Run the Orca ADE runtime on an always-on Linux VPS and pair desktop or mobile clients with it. This image downloads a pinned Orca AppImage, extracts it without FUSE, and runs `orca serve` as an unprivileged user.

## Project layout

```text
.
|-- docker/
|   |-- entrypoint.sh
|   |-- nginx/nginx.conf
|   `-- web/
|       |-- landing.html
|       |-- login.html
|       `-- pairing.html
|-- .env.example
|-- Dockerfile
|-- docker-compose.yml
`-- README.md
```

The repository root contains operator-facing build, configuration, and documentation files. Container implementation details live under `docker/`; generated credentials, pairing pages, and nginx configuration remain ephemeral at runtime.

## Requirements

- Docker Engine with the Compose plugin
- An `amd64` or `arm64` Linux VPS
- A private route such as Tailscale/WireGuard, or an authenticated TLS reverse proxy with WebSocket upgrade support

## Configure

```bash
cp .env.example .env
```

Edit `.env` and replace `ORCA_PAIRING_ADDRESS` with an address clients can reach. Choose one of these patterns:

```dotenv
# Private LAN address
ORCA_PAIRING_ADDRESS=192.168.1.4

# Tailscale address
ORCA_PAIRING_ADDRESS=100.64.0.10

# Authenticated TLS reverse proxy
ORCA_PAIRING_ADDRESS=https://orca.example.com
```

Keep only one `ORCA_PAIRING_ADDRESS` assignment active in `.env`. `ORCA_PORT` controls the host port published to clients and is appended to a bare IP address or hostname. Include an explicit port in `ORCA_PAIRING_ADDRESS` when external routing uses a different one.

`ORCA_HOSTNAME` controls the stable host name shown in terminal prompts and tab titles. It defaults to `orca-server`; use only letters, digits, periods, and hyphens.

`GIT_USER_NAME` and `GIT_USER_EMAIL` are required. Orca needs a valid Git author identity when creating a project and for every commit made by Orca or its agents. Set both values in `.env` before starting the service:

```dotenv
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@example.com
```

Docker Compose stops with a configuration error if either value is missing or empty. On every start, the entrypoint applies them to the global Git configuration stored in the persistent Orca home.

Browser HTTP requests are protected by a login form backed by HTTP Basic credential validation and a per-container session cookie. Set a unique username and strong password in `.env`; Compose refuses to start without both values:

```dotenv
ORCA_WEB_USER=orca
ORCA_WEB_PASSWORD=replace-with-a-long-random-password
```

Enter these credentials when opening Orca Web or the `/desktop` and `/mobile` pairing pages. WebSocket traffic still uses Orca's pairing grants so native Desktop and Mobile clients continue to pair normally. Use HTTPS through Tailscale or an authenticated TLS reverse proxy when sending credentials over a network you do not fully trust.

The service publishes `ORCA_PORT` on all host interfaces so trusted private-network clients can connect. Use host firewall rules to restrict access to your LAN, Tailscale, WireGuard, or authenticated reverse proxy; do not expose it directly to the public Internet.

On a Windows Docker host, allow the published port on Private networks from an elevated PowerShell prompt:

```powershell
New-NetFirewallRule -DisplayName "Orca Server TCP 6770" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 6770 -Profile Private
```

If `ORCA_PORT` is changed, use the same value in the firewall rule. The phone and Windows host must also be on the same LAN without guest-network or access-point client isolation.

## Start and pair

```bash
docker compose build
docker compose up -d
docker compose logs -f orca
```

Open `http://localhost:6770` on the Docker host to use Orca Web. Existing paired browsers continue using their saved runtime grant.

Open `http://localhost:6770/desktop` to display the Desktop pairing QR and full runtime-scoped pairing URI.

Open `http://localhost:6770/mobile` to display a separate Mobile pairing QR. In Orca Mobile, choose **Pair Desktop** and scan the code. It advertises `ORCA_PAIRING_ADDRESS`, so the phone connects through the LAN, Tailscale, or reverse-proxy address configured in `.env`.

The entrypoint creates independent credentials for each client: `/desktop` and Orca Web use the runtime-scoped grant, while `/mobile` serves a mobile-scoped QR with limited access. Treat pairing URLs and QR codes as passwords. Do not put them in source control, browser history sync, screenshots, or issue trackers.

Check status with:

```bash
docker compose ps
```

## Authenticate agents

Agent CLIs and credentials live on the server, not on the paired client. The image includes GitHub CLI. For non-interactive authentication at startup, set a fine-grained token in `.env`:

```dotenv
GH_TOKEN=github_pat_your_token
```

Recreate the service after changing the token:

```bash
docker compose up -d --force-recreate
docker compose exec orca gh auth status
```

The entrypoint configures GitHub CLI and Git HTTPS authentication whenever `GH_TOKEN` is set. The token remains a runtime environment variable; it is not copied into the image or written to the generated pairing pages. Keep `.env` out of source control and grant only the repository permissions Orca needs.

Alternatively, leave `GH_TOKEN` empty and authenticate once with GitHub's device flow:

```bash
docker compose exec orca gh auth login --web --git-protocol https
docker compose exec orca gh auth status
```

Follow the device-login prompt in your browser. GitHub CLI stores its credentials under `/home/orca/.config/gh`, which persists in the `orca-home` volume.

In Orca, open **Settings > Remote Orca Servers > Advanced** and configure GitHub credentials as server-owned instead of **Local Windows**, then use **Re-check** in Integrations.

To authenticate and register supported managed agent accounts, open a shell in the container:

```bash
docker compose exec orca bash
orca account add --agent claude
orca account add --agent codex
orca account list
```

The extracted AppImage may not place the `orca` shim on `PATH`. In that case invoke `/opt/orca/squashfs-root/AppRun` for available headless commands, or install the CLI from Orca using the current official instructions. Any agent CLI installed interactively inside the container is lost when the image is replaced; add repeatable installations to the Dockerfile or mount a dedicated tool volume.

Repositories and worktrees are stored under `/home/orca/orca`, Orca's default project directory. Projects, Orca state, terminal history, paired-device keys, and user configuration all persist in the `orca-home` volume. The disposable application cache uses a memory-backed mount, so it does not inflate persistent-volume backups and is cleared whenever the container is recreated.

## Back up

Stop Orca for a consistent backup, then archive the home volume:

```bash
docker compose stop orca
mkdir -p backups
docker run --rm -v orca-server_orca-home:/source:ro -v "$PWD/backups:/backup" alpine tar czf /backup/orca-home.tgz -C /source .
docker compose start orca
```

Compose derives volume names from the project directory. Confirm the actual names with `docker volume ls` before running backup commands if you changed the Compose project name.

## Upgrade

Change `ORCA_VERSION` in `.env` to an explicit release tag, then rebuild:

```bash
docker compose build --pull --no-cache
docker compose up -d
docker compose logs -f orca
```

Back up first. New Orca versions can migrate persisted state, so rolling back requires restoring the matching state backup as well as the older image.

## Security and limitations

- Never publish port `6768` directly to the public Internet. Prefer Tailscale, WireGuard, SSH forwarding, or an authenticated TLS reverse proxy.
- A reverse proxy must support WebSocket upgrades and route the path used in `ORCA_PAIRING_ADDRESS`.
- Keep the pairing URL private and rotate/revoke grants from Orca when access changes.
- The container runs without FUSE and does not require `--privileged`.
- Orca's embedded browser uses Xvfb and software rendering. Desktop computer-use features are not meaningful on a headless VPS.
- Headless Orca does not auto-update; upgrades are deliberate image rebuilds.
- Orca does not provide the VPS or agent subscriptions. You supply the host, network, provider CLIs, and credentials.

Official references: [Remote Orca Servers](https://www.onorca.dev/docs/remote-servers) and [Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md).