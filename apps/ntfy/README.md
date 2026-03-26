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
| `NTFY_CACHE_DIR` | `./ntfy-cache` | Local cache directory |
| `NTFY_CONFIG_DIR` | `./ntfy-config` | Local config directory |
| `POSTGRES_DATA_DIR` | `./postgres` | Local Postgres data directory |
| `NTFY_BEHIND_PROXY` | `false` | Set to `true` when running behind a reverse proxy |

## Healthchecks

Both containers include built-in healthchecks:
- **ntfy**: HTTP request to `/v1/health` every 60 seconds
- **db**: `pg_isready` check every 10 seconds

ntfy will only start once `db` reports as *healthy* (`depends_on: condition: service_healthy`).
