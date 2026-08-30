# Security

Orca Remote Server is a private, single-operator development environment. Its convenience
features deliberately grant substantial access to projects, credentials, agents, and the
host Docker engine.

[Back to README](../README.md) · [Configuration](configuration.md) · [Operations](operations.md)

## Trust Model

- Only trusted people and agents should access the deployment.
- Orca Web authentication protects browser routes but does not create tenant isolation.
- The persistent home volume contains source code, paired-device keys, credentials, and state.
- A mounted Docker socket is effectively root-level access to the Docker host.
- Project containers may share the `orca-network` and communicate by container name.

Do not use this deployment as a sandbox for untrusted code or users.

## Network Exposure

Never expose the raw services directly to the public Internet. Prefer, in order:

1. Tailscale or WireGuard
2. SSH port forwarding
3. An authenticated TLS reverse proxy with WebSocket support

Use HTTPS whenever traffic leaves a trusted host. Restrict firewall rules to known private
networks and source addresses.

The default published ports are:

| Port | Purpose | Recommendation |
| --- | --- | --- |
| `6770` | Orca Web and pairing | Private network or authenticated TLS proxy only |
| `7339` | RepoWise dashboard | Private network or authenticated TLS proxy only |

RepoWise's internal API (`7337`) and UI (`7340`) are not published. They listen on container
loopback and are accessed through Nginx.

## Credentials

- Use a long, unique `ORCA_WEB_PASSWORD`.
- Treat pairing URLs and QR codes as passwords.
- Keep `.env` out of Git, screenshots, logs, issue trackers, and chat.
- Restrict `GH_TOKEN` to the minimum repositories and permissions required.
- Use narrowly scoped provider API keys with spend limits where available.
- Rotate credentials after accidental exposure and invalidate paired devices when needed.
- Protect volume backups at least as strongly as the live server.

The Kilo configuration references `KILO_API_KEY` from the environment rather than writing it
to the generated config. RepoWise uses an ephemeral API key generated for each container
startup and injected only into its process and Nginx proxy configuration.

## Docker Socket Risk

The container mounts `/var/run/docker.sock` so agents can build and run project containers.
Any process with socket access can generally:

- Start privileged containers
- Mount host filesystems
- Inspect other containers and their environment
- Read host-managed secrets
- Modify host networking and persistent volumes

Setting `DOCKER_GID` controls Unix socket access but does not reduce these capabilities once
access is granted. For stronger isolation, run Orca on a dedicated VM or host.

## Runtime Boundaries

- Orca runs as the unprivileged `orca` user.
- The container itself does not require `--privileged`.
- The AppImage is extracted during build, so runtime FUSE access is unnecessary.
- Browser access is protected by Nginx and an Apache-compatible password file.
- Runtime login pages, sessions, pairing files, Nginx config, and RepoWise API keys are
  generated in a temporary directory and removed at shutdown.
- Headless Orca does not auto-update; upgrades are explicit image rebuilds.

These controls reduce accidental exposure but do not neutralize Docker socket privileges.

## Reverse Proxy Checklist

- Terminate TLS with a valid certificate.
- Preserve WebSocket `Upgrade` and `Connection` headers.
- Forward the original host and scheme where required.
- Disable caching for authentication and pairing routes.
- Apply request-size and timeout limits appropriate for long agent sessions.
- Add an identity-aware proxy or private-network policy in front of Nginx where possible.
- Do not route external traffic directly to RepoWise ports `7337` or `7340`.

## Incident Response

If a credential or pairing grant is exposed:

1. Remove public access or stop the service.
2. Rotate `ORCA_WEB_PASSWORD`, `GH_TOKEN`, and provider API keys as applicable.
3. Revoke affected GitHub and managed-agent sessions.
4. Remove unrecognized paired clients from Orca.
5. Recreate the container to rotate ephemeral sessions and the RepoWise API key.
6. Review Docker containers, images, volumes, and host changes made during the exposure window.
