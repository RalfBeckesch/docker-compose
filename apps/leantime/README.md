# Leantime – Self-Hosted Project Management (Docker Setup)

This directory contains a Docker Compose stack for [Leantime](https://leantime.io),
a project management system built for people who do not want to be project
managers: kanban, Gantt, list and calendar views, sprints, goals, timesheets,
wikis and an API. It is backed by MariaDB and designed to stay updatable: the
version lives in a single place, state lives in bind-mounted host directories,
and every upgrade takes a verified backup first.
Supported architectures: `amd64`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `leantime` | `leantime/leantime:${LEANTIME_VERSION}` | PHP/Laravel application and web UI, exposed via `LEAN_BIND_ADDR`/`LEAN_HOST_PORT` |
| `db` | `mariadb:${MARIADB_VERSION}` | MariaDB database backend |

The `leantime` service waits for the `db` healthcheck to pass before starting.
Each service mounts a dedicated data directory on the host (all under `./data/`).

The `leantime` container runs as uid 1000, gid 0 and does not take ownership of
its four writable directories itself — see [Data Directories](#data-directories)
and [Pitfalls](#pitfalls).

### Why MariaDB instead of MySQL

Leantime's requirements list "MySQL 8.0+ or MariaDB 10.6+". The maintainers run
their own cloud instances on MariaDB ([discussion #1782](https://github.com/Leantime/leantime/discussions/1782)),
and the upstream Helm chart deploys MariaDB. This stack therefore pins MariaDB
11.4 (LTS). The service still reads the classic `MYSQL_*` variable names, which
the official `mariadb` image supports, so the same `.env` works if you ever
switch the service back to the `mysql` image.

## Quickstart

1. Copy the env template and fill in every `CHANGEME` value:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
2. Run the bootstrap script (creates the data directories, sets the file
   ownership, pulls the images, starts the stack and waits until `/health`
   answers):
   ```bash
   ./scripts/bootstrap.sh
   ```
3. Open the instance and create the first account — it becomes the admin.
4. Put a reverse proxy in front of it for TLS termination (see
   [Reverse Proxy](#reverse-proxy)) and set `LEAN_APP_URL` to the external URL.

Without the script: `docker compose pull && docker compose up -d`. Note that this
skips the `chown` on the four directories, and uploads/plugins/logs will fail
until it is applied.

**Update:** `./scripts/upgrade.sh <version>` — or, without backup and verification,
`docker compose pull && docker compose up -d`.

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.
It is read twice: by Compose for interpolation and as `env_file` by both services.

### All settings

| Variable | Default | Description |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `leantime` | Prefix used in all `container_name` values |
| `LEANTIME_VERSION` | `3.13.2` | Leantime image tag — pinned to a released version, never `latest` |
| `MARIADB_VERSION` | `11.4` | MariaDB image tag — an LTS release |
| `LEAN_BIND_ADDR` | `127.0.0.1` | Interface the web UI is published on — loopback behind a reverse proxy, `0.0.0.0` for LAN |
| `LEAN_HOST_PORT` | `8080` | Host port mapped to the container's port 8080 |
| `LEAN_PORT` | `8080` | Port Leantime uses inside the container — fixed by the image, do not change |
| `MARIADB_DATA` | `./data/leantime/mariadb` | Host path for the MariaDB data directory |
| `LEAN_USERFILES` | `./data/leantime/userfiles` | Uploaded files and project attachments |
| `LEAN_PUBLIC_USERFILES` | `./data/leantime/public-userfiles` | Logos and publicly served files |
| `LEAN_PLUGINS` | `./data/leantime/plugins` | Installed plugins |
| `LEAN_LOGS` | `./data/leantime/logs` | Application logs (`storage/logs`) |
| `LEAN_APP_URL` | `http://localhost:8080/` | Public base URL incl. scheme and trailing slash — required for password-reset and invitation mails |
| `LEAN_APP_DIR` | _(empty)_ | Subfolder the app is served from, without trailing slash |
| `LEAN_UID` / `LEAN_GID` | `1000` / `0` | User/group of the container process and owner of the four directories |
| `LEAN_SITENAME` | `Leantime` | Name shown in the UI and in mails |
| `LEAN_LANGUAGE` | `en-US` | Default language for new users |
| `LEAN_DEFAULT_TIMEZONE` | `America/Winnipeg` | Default timezone for new users |
| `LEAN_DEBUG` | `0` | Debug flag — keep at `0` in production |
| `LEAN_SESSION_PASSWORD` | _(required)_ | Session salting key — generate with `openssl rand -hex 32`; changing it logs everyone out |
| `LEAN_SESSION_EXPIRATION` | `480` | Session idle timeout in **minutes** (480 = 8 h) |
| `LEAN_SESSION_SECURE` | `false` | Serve cookies over HTTPS only — set to `true` behind TLS |
| `LEAN_ALLOW_TELEMETRY` | `false` | Anonymous daily usage summary — `false` sends nothing |
| `LEAN_NEWS_ENABLED` | `false` | Leantime's news widget — `false` for instances without outbound access |
| `LEAN_LOG_CHANNELS` | `single` | Log channels — `single` writes `storage/logs/leantime.log` |
| `LEAN_USE_REDIS` | `false` | Redis cache/session backend — not part of this stack |
| `MYSQL_ROOT_PASSWORD` | _(required)_ | Database root password |
| `MYSQL_DATABASE` | `leantime` | Database name created on first startup |
| `MYSQL_USER` | `leantime` | Database user — mapped onto `LEAN_DB_USER` by the Compose file |
| `MYSQL_PASSWORD` | _(required)_ | Database password — mapped onto `LEAN_DB_PASSWORD` by the Compose file |
| `BACKUP_DIR` | `./backups` | Host path for the timestamped backup sets |
| `BACKUP_KEEP_DAYS` | `7` | Retention in days |

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` since it contains
> three secrets.

The app-specific variables are documented in the application's own template,
`config/sample.env` in the [Leantime repository](https://github.com/Leantime/leantime/blob/v3.13.2/config/sample.env).
It is the authoritative source — the `sample.env` in the `docker-leantime` repo is
an older copy and still claims `LEAN_SESSION_EXPIRATION` is in seconds.

## Data Directories

All persistent data is stored on the host under `./data/leantime/`, as defined in `.env`:

| Path | Service | Purpose |
|---|---|---|
| `./data/leantime/mariadb/` | `db` | MariaDB data files |
| `./data/leantime/userfiles/` | `leantime` | Uploads and attachments |
| `./data/leantime/public-userfiles/` | `leantime` | Logos and public files |
| `./data/leantime/plugins/` | `leantime` | Installed plugins |
| `./data/leantime/logs/` | `leantime` | Application logs |

All five are bind mounts. A backup tool that enumerates named volumes will not
find them, which is why `scripts/backup.sh` captures the database and the four
application directories explicitly.

## Upgrade

```bash
./scripts/upgrade.sh 3.13.3          # patch release, runs without a prompt
./scripts/upgrade.sh 3.14.0          # minor release, prompts and warns about migration
./scripts/upgrade.sh 3.14.0 --yes    # minor release without the prompt
```

The script, in this order:

1. Verifies the target tag exists in the registry (HTTP 200/404, no guessing).
2. Detects patch vs. minor/major. Major jumps are refused — the guide requires
   deactivating all plugins first. So are 3.6.0 and 3.6.1 (redirect loops and
   missing JS assets, fixed in 3.6.2).
3. Creates `backups/<timestamp>/` and records the running image tags and `.env`.
4. Dumps the database **while the stack is still up** (`--single-transaction`)
   and archives the four directories.
5. Bumps `LEANTIME_VERSION` in `.env`.
6. Checks the **resolved** Compose configuration — if it would not start the target
   tag, the script aborts instead of starting the wrong version.
7. Pulls, starts, waits for `/health`, runs `php bin/leantime db:migrate`.
8. Prints the rollback commands.

### Version policy

| | |
|---|---|
| Pinning | Exactly one version in `.env`. Never `latest`. |
| Patch releases (`3.13.2` → `3.13.3`) | Bug and security fixes, treated as low risk. |
| Minor releases (`3.13` → `3.14`) | New features and schema migrations — read the release notes first. |
| Major releases (`3.x` → `4.x`) | Not automated. Deactivate all plugins, then follow the guide by hand. |
| Downgrade | Not supported. The only way back is a restore from the backup. |

Migration order matters: a backup taken *before* the image bump is the only way
back, because the new version migrates the schema in place.

## Backup and Restore

Manually:

```bash
docker compose exec -T db sh -c 'exec mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" \
  --single-transaction --quick --triggers --default-character-set=utf8mb4 "$MYSQL_DATABASE"' \
  | gzip > backups/db-$(date +%F).sql.gz
tar -czf backups/files-$(date +%F).tar.gz -C . data/leantime/userfiles \
  data/leantime/public-userfiles data/leantime/plugins data/leantime/logs
```

`-T` makes the client write through to the host pipe instead of allocating a TTY.
The password stays inside the container's environment: the single quotes keep the
host's shell out of it.

`./scripts/backup.sh` does both steps, verifies the gzip integrity, the dump
header and the archive entries, prunes sets older than `BACKUP_KEEP_DAYS` and
prints the restore commands. Sets land in `$BACKUP_DIR` (default `./backups`).

**Rollback after an upgrade.** Resetting `LEANTIME_VERSION` alone is **not**
enough: the newer version migrated the schema, an older Leantime cannot read it,
and importing the dump into an already-migrated database fails on duplicate
tables. The path leads through the database:

```bash
docker compose down
sed -i 's/^LEANTIME_VERSION=.*/LEANTIME_VERSION=<previous version>/' .env
docker compose up -d db
docker compose exec -T db mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" \
  -e 'DROP DATABASE IF EXISTS leantime; CREATE DATABASE leantime;'
gunzip -c backups/<timestamp>/db.sql.gz | docker compose exec -T db \
  mariadb -uroot -p"$MYSQL_ROOT_PASSWORD" leantime
docker compose up -d
```

Always restore a dump with the **same version** that created it.

## Reverse Proxy

The stack publishes HTTP on `LEAN_BIND_ADDR:LEAN_HOST_PORT` and expects TLS
termination upstream (Apache2 + Certbot, Traefik, Nginx Proxy Manager, Caddy).
Set `LEAN_APP_URL` to the external URL including the trailing slash, for example
`https://leantime.example.com/`, keep `LEAN_BIND_ADDR=127.0.0.1`, and set
`LEAN_SESSION_SECURE=true` once TLS is active.

Caddy example:

```
leantime.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

If the proxy rewrites the `Host` header, set `LEAN_APP_URL` to the public URL —
otherwise browser form submissions are rejected by the origin check.

## Scripts

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Main stack definition |
| `env-dist` | Environment template copied to `.env` |
| `scripts/bootstrap.sh` | First-time setup: `.env` creation with generated secrets, data directories, ownership, pull, start, readiness wait |
| `scripts/upgrade.sh` | Version bump with verified backup, resolved-config check, migration run and rollback instructions |
| `scripts/backup.sh` | `mariadb-dump` plus directory archive, with verification, retention and restore instructions |

## Pitfalls

| Case | Behaviour / remedy |
|---|---|
| **Four directories not owned by `LEAN_UID:LEAN_GID`** | Uploads, plugin installs and log writes fail with `permission denied` while the container itself looks healthy. `scripts/bootstrap.sh` applies the `chown` |
| **`PUID`/`PGID` in `.env`** | They are **build args** in the image. The published image is fixed at uid 1000/gid 0 — set `LEAN_UID`/`LEAN_GID` and `user:` instead |
| **`LEAN_SESSION_EXPIRATION` in seconds** | The unit is **minutes** (Laravel's `session.lifetime`). 480 = 8 h. The docker-repo's sample.env wrongly suggests 28800 |
| **`LEAN_APP_URL` empty** | Password-reset and invitation mails are not sent. Set the public URL incl. scheme and trailing slash |
| **`LEAN_PORT` changed** | It is the container's internal port, fixed by the image's nginx config. Change `LEAN_HOST_PORT`, not `LEAN_PORT` |
| **`env_file: .env` on the app service** | It passes the whole file, so `MYSQL_ROOT_PASSWORD` is visible inside the app container. The app does not use it; keep the file mode 600 and treat container access as admin access |
| **MariaDB ↔ MySQL data directory** | The formats are not interchangeable. A switch needs dump/restore, not a volume swap |
| **MariaDB major upgrade** (`11.4` → `11.8`) | The Compose file sets `MARIADB_AUTO_UPGRADE=1`, so the entrypoint runs `mariadb-upgrade` and writes a `system_mysql_backup_*.sql.zst` into the data directory. Take a `scripts/backup.sh` backup before changing `MARIADB_VERSION` anyway |
| **App's own `db:backup`** | `php bin/leantime db:backup` writes into `LEAN_DB_BACKUP_PATH` **inside** the container (default `backupdb/`), which is not mounted and disappears on recreate. Use `scripts/backup.sh` |
| **`utf8mb4_0900_ai_ci`** | MySQL 8's default collation does not exist in MariaDB. This stack pins `utf8mb4_unicode_ci`, which both engines support |
| **Broken releases 3.6.0 / 3.6.1** | Redirect loops and missing JS assets. `scripts/upgrade.sh` refuses them; use 3.6.2+ |
| **`down -v`** | Removes volumes. Not used anywhere in the scripts — do not add it manually |
| **`$` in passwords** | Compose interpolates; write `$` as `$$`. Values generated by `openssl rand -hex 32` contain no `$` |
| **Migration runs on first request** | The app redirects to `/update` when the schema is behind. `scripts/upgrade.sh` runs `php bin/leantime db:migrate` explicitly; `db:status` shows the current state |

## Verification

The stack scripts are covered by the repository-wide harness
`tests/run-stack-script-tests.sh` (stubbed Docker CLI, no daemon needed):
bootstrap idempotency and secret generation, backup set contents and retention,
upgrade flow including the resolved-image assertion. `bash -n` and
`shellcheck -S style` run clean on all three scripts.

**Not checkable locally** — happens on the target host: image pull, container
start, MariaDB initialisation, the readiness wait, file ownership and the first
account creation.

## Sources

- Documentation: https://docs.leantime.io/
- Docker installation: https://docs.leantime.io/installation/docker-based-installation
- Backup & restore: https://docs.leantime.io/installation/backup-restore
- Upgrade guide: https://docs.leantime.io/installation/upgrade-guide
- System requirements: https://github.com/Leantime/leantime (README, "System Requirements")
- MariaDB support statement: https://github.com/Leantime/leantime/discussions/1782
- Application env template: `config/sample.env` at tag `v3.13.2`
- `/health` route: `app/Domain/Status/routes.php` at tag `v3.13.2`
