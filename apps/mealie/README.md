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
| `MEALIE_DATA` | `./mealie-data` | Host path for persistent Mealie data (recipes, images, backups) |
| `UID` | `1000` | User ID the container process runs as — match the host directory owner |
| `GID` | `1000` | Group ID the container process runs as — match the host directory owner |
| `POSTGRES_DATA` | `./postgres-data` | Host path for persistent PostgreSQL data files |
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
| `./mealie-data/` | `mealie` | Recipes, images, backups, and application configuration |
| `./postgres-data/` | `postgres` | PostgreSQL database files |

> **Backup:** Regularly back up both data directories. The most critical directory is
> `./mealie-data/` which contains all recipe data. Mealie also provides a built-in
> backup and restore feature accessible via the admin panel under *Site Settings → Backups*.
