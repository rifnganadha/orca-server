# Orca Remote Server on Docker

Run the Orca ADE runtime on an always-on Linux VPS and pair desktop or mobile clients with it. This image downloads a pinned Orca AppImage, extracts it without FUSE, and runs `orca serve` as an unprivileged user.

## Requirements

- Docker Engine with the Compose plugin
- An `amd64` or `arm64` Linux VPS
- A private route such as Tailscale/WireGuard, or an authenticated TLS reverse proxy with WebSocket upgrade support

## Configure

```bash
cp .env.example .env
```

Edit `.env` and replace `ORCA_PAIRING_ADDRESS`. It must be the address clients can reach, such as a Tailscale IP (`100.x.y.z`), private DNS name, or a complete proxy URL (`https://orca.example.com/runtime`).

The default bind is `127.0.0.1`, suitable when Tailscale or a reverse proxy runs on the VPS host. To connect directly over a trusted private interface, set `ORCA_BIND_ADDRESS` to that interface's IP. Do not bind this service publicly without an authenticated private-network or proxy layer.

## Start and pair

```bash
docker compose build
docker compose up -d
docker compose logs -f orca
```

The readiness output contains a one-time `orca://pair?code=...` URL. Treat it as a password. In the desktop app, open **Settings > Remote Orca Servers > Add Server** and paste the URL. Do not put pairing URLs in source control, proxy access logs, or issue trackers.

Check status with:

```bash
docker compose ps
```

## Install and authenticate agents

Agent CLIs and credentials live on the server, not on the paired client. Open a shell in the container and install the CLIs you use according to their official Linux instructions:

```bash
docker compose exec orca bash
```

Then authenticate and register supported managed accounts from that shell:

```bash
orca account add --agent claude
orca account add --agent codex
orca account list
```

The extracted AppImage may not place the `orca` shim on `PATH`. In that case invoke `/opt/orca/squashfs-root/AppRun` for available headless commands, or install the CLI from Orca using the current official instructions. Any agent CLI installed interactively inside the container is lost when the image is replaced; add repeatable installations to the Dockerfile or mount a dedicated tool volume.

Repositories and worktrees should be stored under `/workspace`. Orca state, terminal history, paired-device keys, and user configuration persist in the `orca-home` volume.

## Back up

Stop Orca for a consistent backup, then archive both volumes:

```bash
docker compose stop orca
mkdir -p backups
docker run --rm -v orca-server_orca-home:/source:ro -v "$PWD/backups:/backup" alpine tar czf /backup/orca-home.tgz -C /source .
docker run --rm -v orca-server_orca-workspace:/source:ro -v "$PWD/backups:/backup" alpine tar czf /backup/orca-workspace.tgz -C /source .
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