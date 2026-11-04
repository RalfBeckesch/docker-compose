# SearXNG – Self-Hosted Meta Search Engine (Docker Setup)

This repository contains a Docker Compose stack for [SearXNG](https://docs.searxng.org/),
a privacy-respecting metasearch engine that queries other engines without tracking its users.
Supported architectures: `amd64`, `arm64` (the image also carries `arm`).

## Services

| Service | Image | Description |
|---|---|---|
| `searxng` | `searxng/searxng:2026.11.2-cccbc9e15` | Main application, exposed via `SEARXNG_PORT` |
| `valkey` | `valkey/valkey:9-alpine` | Rate-limit counters and cache for the bot protection (limiter) |

The application listens on `8080` inside the container; the port is published on
`127.0.0.1` only. For public access put a reverse proxy in front and set
`SEARXNG_BASE_URL` to the external URL.

## Quickstart

1. Copy the env template and adjust values as needed:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
2. Generate the secret and put it into `.env` (`SEARXNG_SECRET`):
   ```bash
   openssl rand -hex 32
   ```
3. Run the bootstrap script:
   ```bash
   ./scripts/bootstrap.sh
   ```

**Update:** change `SEARXNG_VERSION` in `.env`, then
`docker compose pull && docker compose up -d`.

There is **no upgrade script**: SearXNG keeps no database that a new image would
have to migrate. The configuration lives in `settings.yml` and is read by any
version; a version bump is a tag change plus `pull` and `up -d`. Back up before
you bump anyway — `./scripts/backup.sh` covers the configuration.

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `SEARXNG_VERSION` | `2026.11.2-cccbc9e15` | Pinned image tag (never `latest`) |
| `VALKEY_VERSION` | `9-alpine` | Valkey image tag |
| `SEARXNG_PORT` | `42180` | Host port the web UI is published on (bound to `127.0.0.1`) |
| `SEARXNG_BASE_URL` | `http://localhost:42180/` | Public URL, used for links and the OpenSearch descriptor |
| `SEARXNG_SECRET` | `CHANGEME` | Secret for cookies and CSRF tokens — generate with `openssl rand -hex 32` |
| `SEARXNG_LIMITER` | `true` | Bot protection via Valkey |
| `SEARXNG_PUBLIC_INSTANCE` | `false` | Set to `true` when reachable from the internet |
| `SEARXNG_IMAGE_PROXY` | `false` | Proxy result thumbnails through the instance |
| `SEARXNG_CONFIG` | `./data/searxng/config` | Configuration mount (`/etc/searxng`) |
| `SEARXNG_DATA` | `./data/searxng/cache` | Cache mount (`/var/cache/searxng`) |
| `VALKEY_DATA` | `./data/searxng/valkey` | Valkey data directory |
| `BACKUP_DIR` | `./backups` | Where `scripts/backup.sh` writes its sets |
| `BACKUP_KEEP_DAYS` | `7` | Retention in days |

The Compose file maps these onto the `SEARXNG_*` variables SearXNG understands
(`SEARXNG_BASE_URL`, `SEARXNG_SECRET`, `SEARXNG_LIMITER`, `SEARXNG_PUBLIC_INSTANCE`,
`SEARXNG_IMAGE_PROXY`, `SEARXNG_VALKEY_URL`). `SEARXNG_VALKEY_URL` is wired to the
`valkey` service, so the limiter works without editing `settings.yml`.

> ⚠️ **Keep your `.env` out of version control** — it contains the secret.

## Data Directories

| Path | Mount | Purpose |
|---|---|---|
| `./data/searxng/config` | `/etc/searxng` | `settings.yml`, `limiter.toml`, `favicons.toml` — the actual state |
| `./data/searxng/cache` | `/var/cache/searxng` | `faviconcache.db` and similar caches, rebuilt on demand |
| `./data/searxng/valkey` | `/data` | Valkey RDB with rate-limit counters and cache |

`settings.yml` is optional: without it the instance runs on the built-in defaults,
configured entirely through the environment variables. Engine selections, UI
tweaks and per-engine settings need the file — create it in
`./data/searxng/config/settings.yml`.

## Scripts

| File | Purpose |
|---|---|
| `scripts/bootstrap.sh` | First-time setup: `.env` creation with a generated secret, data directories, pull, start, health check |
| `scripts/backup.sh` | Configuration archive with verification, retention and restore instructions |

## Pitfalls

| Case | Behaviour / remedy |
|---|---|
| **Valkey container without a `SEARXNG_VALKEY_URL`** | SearXNG ignores it and the limiter stays off, while the container runs and looks healthy. This stack wires the URL explicitly; verify with `docker compose exec searxng env \| grep VALKEY` |
| **Limiter and public access** | With `SEARXNG_LIMITER=true` but `SEARXNG_PUBLIC_INSTANCE=false`, the limiter uses its internal defaults. Set both consistently — public instance + limiter is the recommended combination |
| **`SEARXNG_BASE_URL` without scheme or trailing slash** | Links in the UI and the OpenSearch descriptor break. Always `https://host/`, including the slash |
| **Changing `SEARXNG_SECRET`** | Invalidates sessions and saved preferences for every user. Generate once and keep it in the backup |
| **`latest` tag** | Upstream publishes dated rollups. `latest` can jump several versions overnight; this stack pins a rollup and expects you to bump it deliberately |
| **No `settings.yml` in the backup set** | Not an error — the instance may be configured by environment variables only. The backup script warns and the manifest records it |
| **Container stopped for a backup** | Not necessary here: `settings.yml` is only written when an administrator changes something. The script copies it while the stack runs |
