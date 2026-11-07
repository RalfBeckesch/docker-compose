# Forgejo – Self-Hosted Git Forge (Docker Setup)

This repository contains a Docker Compose stack for [Forgejo](https://forgejo.org/),
a community-driven git forge (a Gitea fork) for hosting repositories, issues, pull
requests and package registries.
Supported architectures: `amd64`, `arm64`, `arm`.

## Services

| Service | Image | Description |
|---|---|---|
| `server` | `codeberg.org/forgejo/forgejo:17.0.1` | Web UI, REST API and the built-in SSH server, exposed via `FORGEJO_HTTP_PORT` and `FORGEJO_SSH_PORT` |
| `db` | `postgres:18` | Persistent database |

The web UI listens on `3000` and the SSH server on `22` inside the container.
Both ports are published on the host; the UI on `127.0.0.1` by default, SSH on all
interfaces because git clients have to reach it. For public access put a reverse
proxy in front and set `FORGEJO_ROOT_URL` to the external URL.

## Quickstart

1. Copy the env template and adjust values as needed:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
2. Generate the three secrets and put them into `.env`
   (`FORGEJO_SECRET_KEY`, `FORGEJO_INTERNAL_TOKEN`, `FORGEJO_JWT_SECRET`):
   ```bash
   openssl rand -hex 32   # SECRET_KEY and JWT_SECRET
   openssl rand -hex 40   # INTERNAL_TOKEN
   ```
3. Run the bootstrap script:
   ```bash
   ./scripts/bootstrap.sh
   ```
4. Open `FORGEJO_ROOT_URL` and create the first account — it becomes the
   administrator. Then set `FORGEJO_DISABLE_REGISTRATION=true` in `.env` and run
   `docker compose up -d` to apply it.

**Update:** run `./scripts/upgrade.sh <version>` — it verifies the tag, writes a
verified backup and refuses a major jump, which the upstream guide requires to be
done by hand. A plain `docker compose pull && docker compose up -d` also works,
but skips the backup and the version checks.

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.
The Compose file translates these values into the `FORGEJO__<section>__<KEY>`
environment variables the image understands and renders into
`/data/gitea/conf/app.ini`.

### All settings

| Variable | Default | Description |
|---|---|---|
| `FORGEJO_VERSION` | `17.0.1` | Pinned image tag (never `latest`) |
| `POSTGRES_VERSION` | `18` | PostgreSQL image tag |
| `COMPOSE_PROJECT_NAME` | `forgejo` | Prefix for container and network names |
| `BIND_ADDR` | `127.0.0.1` | Interface the web UI is published on |
| `FORGEJO_HTTP_PORT` | `3000` | Host port of the web UI |
| `FORGEJO_SSH_PORT` | `2222` | Host port of the built-in SSH server (container port 22) |
| `FORGEJO_SSH_BIND` | `0.0.0.0` | Interface the SSH port is published on |
| `FORGEJO_ROOT_URL` | `http://localhost:3000/` | Public URL, trailing slash included |
| `FORGEJO_DOMAIN` | `localhost` | Host name in clone URLs and e-mails |
| `FORGEJO_SSH_DOMAIN` | `localhost` | Host name in SSH clone URLs |
| `FORGEJO_SECRET_KEY` | `CHANGEME` | Signs session cookies — `openssl rand -hex 32` |
| `FORGEJO_INTERNAL_TOKEN` | `CHANGEME` | Internal API token — `openssl rand -hex 40` |
| `FORGEJO_JWT_SECRET` | `CHANGEME` | Signs OAuth2/JWT tokens — `openssl rand -hex 32` |
| `FORGEJO_DISABLE_REGISTRATION` | `false` | Set to `true` after the admin account exists |
| `FORGEJO_UID` / `FORGEJO_GID` | `1000` / `1000` | Container user; the data directory must belong to it |
| `POSTGRES_DB` | `forgejo` | Database name |
| `POSTGRES_USER` | `forgejo` | Database user |
| `POSTGRES_PASSWORD` | `CHANGEME` | Database password |
| `FORGEJO_DATA` | `./data/forgejo` | Data volume: `app.ini`, repositories, LFS, avatars, SSH keys |
| `POSTGRES_DATA` | `./data/forgejo/postgres` | PostgreSQL data directory |
| `BACKUP_DIR` | `./backups` | Where `scripts/backup.sh` writes its sets |
| `BACKUP_KEEP_DAYS` | `7` | Retention in days |

> ⚠️ **Keep your `.env` out of version control** — it contains four secrets.

## Data Directories

| Path | Mount | Purpose |
|---|---|---|
| `./data/forgejo` | `/data` | `gitea/conf/app.ini`, `git/repositories`, `gitea/data` (avatars, attachments, LFS, indexer), `ssh` host keys |
| `./data/forgejo/postgres` | `/var/lib/postgresql` | PostgreSQL cluster |

The `/data` mount is the entire state of the instance. It must be owned by
`FORGEJO_UID:FORGEJO_GID`; `scripts/bootstrap.sh` applies that. Under rootless
Docker set both to `0:0`, otherwise the container cannot write.

## Scripts

| File | Purpose |
|---|---|
| `scripts/bootstrap.sh` | First-time setup: `.env` with generated secrets, data directories with the right owner, pull, start, health check |
| `scripts/upgrade.sh` | Version bump with registry check, jump classification, verified backup, resolved-image assertion |
| `scripts/backup.sh` | Vendor `forgejo dump` with the server stopped, verification, retention and restore instructions |

### Backups

Forgejo's vendor procedure is the `dump` command, not a folder copy: it packs
`app.ini`, a SQL dump of the database, the repositories, LFS objects, attachments
and customisations into one archive. The documentation is explicit that the
instance has to be **stopped** while the dump runs — a push or migration in flight
can leave repository copy and database dump disagreeing. `scripts/backup.sh` stops
the server container (the database keeps running, the dump needs a live
connection), runs `forgejo dump` in a one-off container of the same image, moves
the archive out of the volume and starts the server again — also when a step
fails. Basis: [Forgejo Docker installation](https://forgejo.org/docs/latest/admin/installation-docker/)
and [Gitea backup and restore](https://docs.gitea.com/administration/backup-and-restore/).

## Pitfalls

| Case | Behaviour / remedy |
|---|---|
| **`/data` not owned by `FORGEJO_UID`** | The container cannot create `app.ini` and exits. `scripts/bootstrap.sh` chowns the directory; a plain `docker compose up -d` does not |
| **Wrong `FORGEJO_ROOT_URL`** | Links, webhooks and OAuth callbacks point at the wrong host. It must match the browser URL exactly, including the trailing slash |
| **`FORGEJO_SSH_PORT` ≠ published port** | Clone URLs advertise the wrong port. The variable is the *published* port; the server always listens on 22 inside |
| **Port 22 already in use** | The host's own sshd owns it. This stack publishes `2222`; git clients use `ssh://git@host:2222/…` |
| **Major version jump** | Forgejo requires manual operations and human verification when crossing a major line. `scripts/upgrade.sh` refuses it and points at the upgrade guide |
| **Registration left open** | Anyone who can reach the UI can create an account. Set `FORGEJO_DISABLE_REGISTRATION=true` once the admin exists |
| **`docker compose down -v`** | Deletes the database volume. The stack uses bind mounts, so `down` alone is safe — never add `-v` |
| **Losing `FORGEJO_SECRET_KEY`** | Invalidates all sessions. It is in `.env`, which every backup set contains |
