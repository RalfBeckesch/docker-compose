# Paperless-ngx – Self-Hosted Document Management (Docker Setup)

This repository contains a Docker Compose stack for [Paperless-ngx](https://docs.paperless-ngx.com/),
a self-hosted document management system with OCR, full-text search, and email ingestion.
Supported architectures: `amd64`, `arm`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `webserver` | `paperless-ngx:2.20` | Main application, exposed via `PAPERLESS_EXPORT_PORT` (loopback only) |
| `db` | `postgres:16` | Primary relational database |
| `broker` | `redis:7` | Message broker for async task queue |
| `gotenberg` | `gotenberg:8.25` | Converts Office/`.eml` files to PDF |
| `tika` | `apache/tika:latest` | Extracts text from Office documents for OCR |

The webserver waits for `db` to pass its healthcheck before starting. Gotenberg runs with JavaScript disabled and only allows local `file:///tmp/*` paths for security.

## Quickstart

1. Copy the env template and fill in all required values:
   ```bash
   cp env-dist-2 docker-compose.env
   ```
2. Pull all images:
   ```bash
   docker compose pull
   ```
3. Create the initial superuser:
   ```bash
   docker compose run --rm webserver createsuperuser
   ```
4. Start the stack:
   ```bash
   docker compose up -d
   ```

**Update:** `docker compose pull && docker compose up -d`

## Configuration (`docker-compose.env`)

The file `env-dist-2` is the configuration template. Variables marked **[CHANGE ON NEW INSTANCE]** must be set before first deployment.

### Mandatory on every new instance

| Variable | Description |
|---|---|
| `PAPERLESS_URL` | Public URL, e.g. `https://dms.example.com` — must match your reverse proxy |
| `PAPERLESS_SECRET_KEY` | Long random string for session signing — generate with `openssl rand -hex 64` |
| `POSTGRES_PASSWORD` | PostgreSQL password — use a strong, unique value |

> ⚠️ **Never commit `docker-compose.env` to a public repository** — it contains passwords and the secret key. Add it to `.gitignore`.

### Key optional settings

| Variable | Default | Description |
|---|---|---|
| `PAPERLESS_TIME_ZONE` | `Europe/Berlin` | Server timezone |
| `PAPERLESS_OCR_LANGUAGE` | `deu` | Primary OCR language (Tesseract code) |
| `PAPERLESS_OCR_LANGUAGES` | `eng fra frk ...` | Additional language packs to install |
| `PAPERLESS_CONSUMER_POLLING` | `60` | Polling interval in seconds (use `0` for inotify on local volumes) |
| `PAPERLESS_EMAIL_TASK_CRON` | `*/2 * * * *` | Email ingestion schedule |
| `USERMAP_UID` / `USERMAP_GID` | `1000` | Host user/group for file permission mapping |
| `PAPERLESS_EXPORT_PORT` | `127.0.0.1:18182` | Host port binding (loopback only — use a reverse proxy) |

## Data Directories

All data is stored on the host under `./data/` by default:

| Path | Purpose |
|---|---|
| `./data/ppl-data` | Application data |
| `./data/ppl-media` | Stored documents |
| `./data/ppl-consume` | Incoming documents (drop files here) |
| `./data/ppl-export` | Exported documents |
| `./data/ppl-backup` | Backup output |
| `./data/pgdata` | PostgreSQL data |
| `./data/redisdata` | Redis data |

> **NFS/SMB consume directory:** If `ppl-consume` is a network share, keep `PAPERLESS_CONSUMER_POLLING` > 0. For local volumes, set it to `0` to use `inotify` instead.
