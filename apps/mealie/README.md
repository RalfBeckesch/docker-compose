# Mealie – Self-Hosted Recipe Manager (Docker Setup)

This directory contains a Docker Compose stack for [Mealie](https://github.com/mealie-recipes/mealie),
a self-hosted recipe manager and meal planner with a REST API and modern web interface.
It supports recipe importing from URLs, meal planning, shopping lists, and optional
AI-assisted recipe parsing via OpenAI.
Supported architectures: `amd64`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `mealie` | `ghcr.io/mealie-recipes/mealie:v3.13.1` | Main application, exposed via `EXPORT_PORT`, limited to 1 GB RAM |
| `postgres` | `postgres:17` | PostgreSQL 17 database backend |

The `mealie` service waits for the `postgres` healthcheck to pass before starting.
Each service mounts a dedicated data volume on the host.

## Quickstart

1. Copy the env template and adjust values as needed:
   ```bash
   cp env-dist .env
   ```
2. Pull the images:
   ```bash
   docker compose pull
   ```
3. Start the stack:
   ```bash
   docker compose up -d
   ```

**Update:** `docker compose pull && docker compose up -d`

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `EXPORT_PORT` | `127.0.0.1:8080` | Host binding and port — use `127.0.0.1` behind a reverse proxy |
| `BASE_URL` | _(required)_ | Public-facing URL, must match your reverse proxy config |
| `TZ` | `Europe/Berlin` | Container timezone — affects scheduled tasks and timestamps |
| `LOG_LEVEL` | `INFO` | Log verbosity: `DEBUG`, `INFO`, `WARNING`, `ERROR`, `CRITICAL` |
| `ALLOW_SIGNUP` | `false` | Allow self-registration — keep `false` and invite users via admin panel |
| `MEALIE_DATA` | `./data/mealie` | Host path for persistent Mealie data (recipes, images, backups) |
| `UID` | `1000` | User ID the container process runs as — match the host directory owner |
| `GID` | `1000` | Group ID the container process runs as — match the host directory owner |
| `POSTGRES_DATA` | `./data/postgres` | Host path for persistent PostgreSQL data files |
| `POSTGRES_DB` | `mealie` | Database name created on first startup |
| `POSTGRES_USER` | `mealie` | PostgreSQL username — shared by both services |
| `POSTGRES_PASSWORD` | _(required)_ | PostgreSQL password — shared by both services |
| `SMTP_HOST` | _(Required For email)_ | Hostname of the outbound SMTP server |
| `SMTP_PORT` | _(Required For email)_ | SMTP port (`25`, `587` for STARTTLS, `465` for implicit TLS) |
| `SMTP_FROM_EMAIL` | _(Required For email)_ | Sender address for outgoing emails (invitations, password resets) |
| `SMTP_USER` | _(Required For email)_ | SMTP authentication username |
| `SMTP_PASSWORD` | _(Required For email)_ | SMTP authentication password |
| `OPENAI_API_KEY` | _(Required For AI support)_ | OpenAI API key for AI-assisted recipe parsing — leave empty to disable |

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` since it contains
> database credentials and API keys.

## Data Directories

All persistent data is stored on the host under the paths defined in `.env`:

| Path | Service | Purpose |
|---|---|---|
| `./data/mealie/` | `mealie` | Recipes, images, backups, and application configuration |
| `./data/postgres/` | `postgres` | PostgreSQL database files |

> **Backup:** Regularly back up both data directories. The most critical directory is
> `./data/mealie/` which contains all recipe data. Mealie also provides a built-in
> backup and restore feature accessible via the admin panel under *Site Settings → Backups*.

## Scripts

| File | Purpose |
|---|---|
| `scripts/bootstrap.sh` | First-time setup: `.env` creation with a generated database password, data directories, ownership, pull, start, health check |
| `scripts/upgrade.sh` | Version bump with a verified backup, start, health check and rollback instructions |
| `scripts/backup.sh` | Database dump plus data directory, with verification, retention and restore instructions |

Stack update in short:

```bash
cp env-dist .env && chmod 600 .env   # once
./scripts/bootstrap.sh               # once
./scripts/upgrade.sh v3.14.0         # later, per release
```

All image tags live in `.env` (`MEALIE_VERSION`, `POSTGRES_VERSION`), so an upgrade
changes one value instead of editing the Compose file. The script writes a
verifiable database dump plus the data directory into `backup/<timestamp>/` and
refuses to continue if either is not intact.

## Migration Notes

### 2026-11-04 — data directories moved under `./data/`

The persistent directories used to be `./mealie-data` and `./postgres-data`. They now live
under `./data/` (`./data/mealie`, `./data/postgres`), matching every other stack in this repo
and making a single `.gitignore` rule (`data/`) sufficient.

**This matters for an instance that is already running:** the paths in the Compose file
changed, so Docker will create *empty* directories at the new locations on the next start,
and the instance will look wiped. Move the existing data before starting:

```bash
mkdir -p data
mv mealie-data data/mealie
mv postgres-data data/postgres
```

Then set `MEALIE_DATA=./data/mealie` and `POSTGRES_DATA=./data/postgres` in `.env`.
Replacing `./mealie-data` with the new path in `.env` while leaving the old directory on disk
is a supported alternative — the variables are the source of truth, the defaults are not.
