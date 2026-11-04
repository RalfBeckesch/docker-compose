# ntfy – Self-Hosted Notification Service (Docker Setup)

This repository contains a Docker Compose setup for [ntfy](https://ntfy.sh/), a lightweight self-hosted push notification service backed by PostgreSQL.

## Services

| Service | Image | Description |
|---|---|---|
| `ntfy` | `binwiederhier/ntfy:v2.19` | Notification server, listens on port 80 (internal) |
| `db` | `postgres:16-alpine` | PostgreSQL database for ntfy persistence |

Both services communicate over the internal bridge network `ntfy-net` and are not directly exposed externally (except via the configured `NTFY_EXPOSE_PORT`).

## Security

ntfy is configured with **maximum security** defaults:
- Login required (`NTFY_REQUIRE_LOGIN=true`)
- Sign-up disabled (`NTFY_ENABLE_SIGNUP=false`)
- Default access denied (`NTFY_AUTH_DEFAULT_ACCESS=deny-all`)

## Quickstart

1. Create your `.env` file from the provided template:
   ```bash
   cp env-dist .env
   ```
2. Fill in all required variables (see below).
3. Start the stack:
   ```bash
   docker compose up -d
   ```

## Configuration (`.env`)

The file `env-dist` serves as the configuration template. The following variables are **mandatory** — the stack will not start without them:

| Variable | Description |
|---|---|
| `NTFY_BASE_URL` | Public URL of the ntfy instance, e.g. `https://ntfy.example.com` |
| `NTFY_SMTP_SENDER_PASS` | Password for SMTP email delivery |
| `NTFY_AUTH_USERS` | User list (Base64-encoded, generated via [Config Generator](https://docs.ntfy.sh/config/#config-generator)) |
| `POSTGRES_PASSWORD` | PostgreSQL database password |

Optional variables with defaults:

| Variable | Default | Description |
|---|---|---|
| `NTFY_EXPOSE_PORT` | `8080` | External port |
| `NTFY_TZ` | `UTC` | Timezone |
| `NTFY_CACHE_DURATION` | `12h` | Message cache duration |
| `NTFY_UID` / `NTFY_GID` | `1000` | User/group for the ntfy process |
| `NTFY_CACHE_DIR` | `./data/ntfy-cache` | Local cache directory |
| `NTFY_CONFIG_DIR` | `./data/ntfy-config` | Local config directory |
| `POSTGRES_DATA_DIR` | `./data/postgres` | Local Postgres data directory |
| `NTFY_BEHIND_PROXY` | `false` | Set to `true` when running behind a reverse proxy |

## Healthchecks

Both containers include built-in healthchecks:
- **ntfy**: HTTP request to `/v1/health` every 60 seconds
- **db**: `pg_isready` check every 10 seconds

ntfy will only start once `db` reports as *healthy* (`depends_on: condition: service_healthy`).

## Scripts

| File | Purpose |
|---|---|
| `scripts/bootstrap.sh` | First-time setup: `.env` creation with a generated database password, data directories, ownership, pull, start, health check |
| `scripts/upgrade.sh` | Version bump with a verified backup, start, health check and rollback instructions |
| `scripts/backup.sh` | Database dump (auth, ACLs, tokens) plus the config directory, with verification, retention and restore instructions |

Stack update in short:

```bash
cp env-dist .env && chmod 600 .env   # once
./scripts/bootstrap.sh               # once
./scripts/upgrade.sh v2.20           # later, per release
```

All image tags live in `.env` (`NTFY_VERSION`, `POSTGRES_VERSION`). The upgrade
script dumps the database, archives `.env`, the cache and the config directory into
`backup/<timestamp>/`, then restarts the stack and waits for `/v1/health` to report
`"healthy": true` before it reports success.

Authentication is *not* scriptable: `NTFY_AUTH_USERS`, `NTFY_AUTH_ACCESS` and
`NTFY_AUTH_TOKENS` have to be generated with the
[Config Generator](https://docs.ntfy.sh/config/#config-generator) and pasted into `.env`.

## Migration Notes

### 2026-11-04 — data directories moved under `./data/`

The runtime directories used to be `./ntfy-cache`, `./ntfy-config` and `./postgres`. They now
live under `./data/` (`./data/ntfy-cache`, `./data/ntfy-config`, `./data/postgres`), matching
every other stack in this repo and making a single `.gitignore` rule (`data/`) sufficient.

Note that the defaults inside `docker-compose.yaml` were changed too — the entries in
`env-dist` are commented out, so an untouched `.env` follows the new default and would
otherwise still point at the old paths.

**This matters for an instance that is already running:** Docker will create *empty*
directories at the new locations on the next start, and the instance will look wiped.
Move the existing data before starting:

```bash
mkdir -p data
mv ntfy-cache data/ntfy-cache
mv ntfy-config data/ntfy-config
mv postgres data/postgres
```

Then set the three variables in `.env` to the new paths. Keeping the old directory and
pointing `NTFY_CACHE_DIR`, `NTFY_CONFIG_DIR` and `POSTGRES_DATA_DIR` at it is a supported
alternative — the variables win over the defaults.
