# Vaultwarden – Self-Hosted Password Manager (Docker Setup)

This directory contains a Docker Compose stack for [Vaultwarden](https://github.com/dani-garcia/vaultwarden),
an unofficial, lightweight Bitwarden-compatible server written in Rust.
It exposes the full Bitwarden client API and web vault, suitable for self-hosted
personal or team password management.
Supported architectures: `amd64`, `arm`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `bitwarden` | `vaultwarden/server:${VERSION:-latest}` | Main application, exposed via `EXPORT_PORT` |

The service mounts a single data volume for the SQLite database, attachments, icons, and send files.

## Quickstart

1. Copy the env template and adjust values as needed:
   ```bash
   cp env-dist .env
   ```
2. Generate an `ADMIN_TOKEN` hash and add it to `.env` (see [Admin Token](#admin-token) below).
3. Pull the image:
   ```bash
   docker compose pull
   ```
4. Start the stack:
   ```bash
   docker compose up -d
   ```

**Update:** `docker compose pull && docker compose up -d`

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `VERSION` | `latest` | Vaultwarden image tag — left at `latest` here, see the note below |
| `EXPORT_PORT` | `127.0.0.1:8080` | Host binding and port — use `127.0.0.1` behind a reverse proxy |
| `DATA` | `./data/vaultwarden` | Host path for persistent data (DB, attachments, icons) |
| `DOMAIN` | `https://vaultwarden.example.com` | Public-facing URL, must match your reverse proxy config |
| `WEBSOCKET_ENABLED` | `true` | Enable WebSocket for real-time client sync notifications |
| `SIGNUPS_ALLOWED` | `true` | Allow new user self-registration — disable after initial setup |
| `SIGNUPS_DOMAINS_WHITELIST` | _(empty)_ | Comma-separated list of permitted email domains for registration |
| `SMTP_HOST` | _(required)_ | Hostname of the outbound SMTP server |
| `SMTP_PORT` | _(required)_ | SMTP port (`25`, `587` for STARTTLS, `465` for implicit TLS) |
| `SMTP_SECURITY` | _(required)_ | Encryption mode: `starttls`, `force_tls`, or `off` |
| `SMTP_FROM` | _(required)_ | Sender address for outgoing emails |
| `SMTP_USERNAME` | _(required)_ | SMTP authentication username |
| `SMTP_PASSWORD` | _(required)_ | SMTP authentication password |
| `ADMIN_TOKEN` | _(required)_ | Argon2id hash securing the `/admin` panel — **must not be empty** |

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` since it contains
> credentials and your admin token.

### Known issue: `VERSION=latest`

`VERSION` is deliberately left at `latest` in this stack and that deviates from the
"never unpinned" rule used by every other stack here. What that means in practice:

- `docker compose pull` fetches whatever the current release is — *including a newer major
  version with breaking changes*, without any confirmation step.
- There is no way to tell from the stack which version is actually running except by asking
  the container: `docker inspect -f '{{.Config.Image}}' bitwarden`.
- A rollback is therefore always a database restore, never a tag change.

**Before every update:** copy `DATA` (at least `db.sqlite3`) to a second location and take note
of the running version. To pin instead (recommended for a stack in daily use), set a released
tag in `.env` and pull it explicitly:

```bash
VERSION=1.35.0
docker compose pull && docker compose up -d
```

Releases: https://github.com/dani-garcia/vaultwarden/releases

## Admin Token

The `/admin` panel is protected by `ADMIN_TOKEN`. A plain-text password is accepted but an
**Argon2id hash is strongly recommended**.

Generate a hash with the following command (replace `MySecretPassword` with your chosen password):

```bash
echo -n "MySecretPassword" | argon2 "$(openssl rand -base64 32)" -e -id -k 65540 -t 3 -p 4
```

Install `argon2` if not already available:
- **Debian/Ubuntu:** `sudo apt install argon2`
- **macOS:** `brew install argon2`

Copy the full output string (starting with `$argon2id$...`) into `.env`, wrapped in **single quotes**
to prevent shell interpretation of special characters:

```dotenv
ADMIN_TOKEN='$argon2id$v=19$m=65540,t=3,p=4$<salt>$<hash>'
```

## Data Directory

All persistent data is stored on the host under `./data/vaultwarden/` by default:

| Path | Purpose |
|---|---|
| `./data/vaultwarden/db.sqlite3` | Main SQLite database (users, ciphers, organizations) |
| `./data/vaultwarden/attachments/` | User-uploaded file attachments |
| `./data/vaultwarden/sends/` | Bitwarden Send files |
| `./data/vaultwarden/icon_cache/` | Cached website favicons |
| `./data/vaultwarden/config.json` | Runtime configuration written by the admin panel |

> **Backup:** Regularly back up the entire `DATA` directory, especially `db.sqlite3`.
> Vaultwarden includes a built-in scheduled backup, configurable via the admin panel.

## Scripts

| File | Purpose |
|---|---|
| `scripts/upgrade.sh` | Version bump with a stop-copy backup of the SQLite database, start, verification and rollback instructions |
| `scripts/backup.sh` | SQLite online backup (or a short stop without `sqlite3`), plus the data directory with `attachments/` |

```bash
./scripts/upgrade.sh 1.35.0          # asks for confirmation
./scripts/upgrade.sh 1.35.0 --yes    # non-interactive
```

The script stops the stack before copying `DATA`, because a running SQLite file
cannot be copied consistently — that is the whole point of the stop. It then writes
the target tag into `VERSION` in `.env`, which is also the recommended way out of
`VERSION=latest` (see the note above): after one run the stack is pinned to a real
release and the "which version am I actually running" problem is gone.

Vaultwarden has no separate database service, so there is no `pg_dump` step and no
`db.sql.gz`. Everything lives in `backup/<timestamp>/data.tar.gz`.

## Migration Notes

### 2026-11-04 — data directory moved under `./data/`

The persistent data used to live in `./vaultwarden-data`. It now lives under `./data/`
(`./data/vaultwarden`), matching every other stack in this repo and making a single
`.gitignore` rule (`data/`) sufficient.

**This matters for an instance that is already running:** Docker will create an *empty*
directory at the new location on the next start and the instance will look wiped. Move the
existing data before starting:

```bash
mkdir -p data
mv vaultwarden-data data/vaultwarden
```

Then set `DATA=./data/vaultwarden` in `.env`. Pointing `DATA` at the old directory instead is
a supported alternative — the variable wins over the default.

> ⚠️ **Take a copy of `db.sqlite3` before touching anything.** For a password manager, a
> wrong `mv` or a mistyped path is the one failure mode you cannot afford.
