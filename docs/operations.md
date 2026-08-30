# Operations

This guide covers routine service management, project containers, backup, upgrades, and
troubleshooting.

[Back to README](../README.md) · [Configuration](configuration.md) · [Security](security.md)

## Status And Logs

```bash
docker compose ps
docker compose logs -f orca
docker compose exec orca kilo mcp list
```

The service health check probes Orca Web on container loopback. RepoWise startup is also
gated by loopback checks for its API and UI processes.

## Run Project Containers

Projects live under `/home/orca/orca/projects`. Docker and Compose commands can run directly
from an Orca terminal:

```bash
cd /home/orca/orca/projects/example
docker compose up -d
docker compose ps
docker compose logs -f
```

The mounted socket uses the host Docker engine. The server Compose project creates the
external `orca-network`, allowing child containers to communicate by container name.

### Publish Application Ports

Map the host port to the port on which the application actually listens. For an application
that listens on container port `80`:

```yaml
services:
  app:
    image: docker/welcome-to-docker
    container_name: welcome
    restart: unless-stopped
    ports:
      - "3001:80"
    networks:
      - orca-network

networks:
  orca-network:
    external: true
```

Open it from the Docker host at `http://localhost:3001`. From another container attached to
`orca-network`, use `http://welcome:80`.

A mapping such as `3001:3001` only works when the child process listens on port `3001`.

### Bind-Mount Caveat

The host daemon resolves bind-mount sources on the host, not inside `orca-server`. A path
such as `/home/orca/orca/projects/example` cannot be passed directly to `docker run -v`
unless that path also exists on the host. Prefer a named volume, a host bind-mounted project
root, or a Docker build context.

## Persistence

The `orca-home` volume stores:

- Projects and worktrees under `/home/orca/orca`
- Orca state and paired-device keys
- Kilo, GitHub CLI, and managed-agent credentials
- Terminal history and user configuration
- User caches under `/home/orca/.cache`

Runtime credentials, rendered pairing pages, generated Nginx configuration, and the
RepoWise API key are ephemeral.

## Backup And Restore

Stop Orca to create a consistent archive:

```bash
docker compose stop orca
mkdir -p backups
docker run --rm \
  -v orca-server_orca-home:/source:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf /backup/orca-home.tgz -C /source .
docker compose start orca
```

Compose derives volume names from the project directory. Confirm the name with
`docker volume ls` when using a custom project name.

Restore into an empty volume:

```bash
docker compose down
docker volume create orca-server_orca-home
docker run --rm \
  -v orca-server_orca-home:/target \
  -v "$PWD/backups:/backup:ro" \
  alpine tar xzf /backup/orca-home.tgz -C /target
docker compose up -d
```

## Upgrade

Back up the home volume, update pinned versions in `.env`, then rebuild:

```bash
docker compose build --pull
docker compose up -d --force-recreate orca
docker compose logs -f orca
```

BuildKit cache mounts reuse downloaded dependencies. Use `--no-cache` only for a full
refresh or cache troubleshooting. Orca releases may migrate persisted state; rolling back
an image can require restoring the matching volume backup.

## Troubleshooting

### Child App Returns An Empty Response

```bash
docker exec <container> ss -lntp
docker logs <container>
docker inspect <container> --format '{{json .NetworkSettings.Ports}}'
```

The host side of `HOST:CONTAINER` is browser-facing. The container side must match the
application's actual listener.

### Docker Permission Denied

```bash
stat -c '%u %g %a' /var/run/docker.sock
docker compose exec orca id
docker compose exec orca stat -c '%u %g %a' /var/run/docker.sock
```

Set `DOCKER_GID` to the socket group ID and recreate the service.

### Client Cannot Pair

- Confirm `ORCA_PAIRING_ADDRESS` is reachable from the client.
- Keep `ORCA_PORT` open only on trusted networks.
- Disable guest-network or access-point client isolation.
- Ensure the reverse proxy supports WebSocket upgrades.
- Confirm the advertised scheme and external port match the proxy.

On Windows, allow the default port on Private networks from elevated PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Orca Server TCP 6770" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 6770 -Profile Private
```

### RepoWise Health API Returns 401 Or 403

Confirm that the running image contains the current Nginx integration and that requests are
going through port `7339`, not directly to port `7337`:

```bash
docker compose up -d --build --force-recreate orca
docker compose logs orca
docker compose exec orca sh -lc 'ss -lntp | grep -E ":7337|:7339|:7340"'
```

The API must listen on `127.0.0.1:7337`; Nginx owns the public dashboard port and supplies
the ephemeral bearer token.
