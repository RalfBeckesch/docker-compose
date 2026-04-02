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
| `VERSION` | `latest` | Vaultwarden image tag — pin to a release for reproducibility |
| `EXPORT_PORT` | `127.0.0.1:8080` | Host binding and port — use `127.0.0.1` behind a reverse proxy |
| `DATA` | `./vaultwarden-data` | Host path for persistent data (DB, attachments, icons) |
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

All persistent data is stored on the host under `./vaultwarden-data/` by default:

| Path | Purpose |
|---|---|
| `./vaultwarden-data/db.sqlite3` | Main SQLite database (users, ciphers, organizations) |
| `./vaultwarden-data/attachments/` | User-uploaded file attachments |
| `./vaultwarden-data/sends/` | Bitwarden Send files |
| `./vaultwarden-data/icon_cache/` | Cached website favicons |
| `./vaultwarden-data/config.json` | Runtime configuration written by the admin panel |

> **Backup:** Regularly back up the entire `DATA` directory, especially `db.sqlite3`.
> Vaultwarden includes a built-in scheduled backup, configurable via the admin panel.
