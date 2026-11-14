# InvoiceShelf – Self-Hosted Invoicing (Docker Setup)

This directory contains a Docker Compose stack for
[InvoiceShelf](https://invoiceshelf.com), an open-source application for invoices,
estimates, payments and expenses, with a web UI and a REST API. It is backed by
PostgreSQL and designed to stay updatable: the version lives in a single place,
state lives in bind-mounted host directories, and every upgrade takes a verified
backup first.
Supported architectures: `amd64`, `arm64`.

The stack runs the **official production image** (`invoiceshelf/invoiceshelf`),
which is built on `serversideup/php` and starts nginx, PHP-FPM and Laravel's
scheduler in one container. Upstream's own Compose files live in
[`ref/upstream/`](ref/upstream/) for reference (git-ignored); the files here follow
this repository's conventions.

## Services

| Service | Image | Description |
|---|---|---|
| `invoiceshelf` | `invoiceshelf/invoiceshelf:${INVOICESHELF_VERSION}` | Web UI and API in one container, exposed via `INVOICESHELF_BIND_ADDR`/`INVOICESHELF_HOST_PORT` |
| `db` | `postgres:${POSTGRES_VERSION}` | PostgreSQL 16 database backend |

The `invoiceshelf` service waits for the `db` healthcheck to pass before starting.
Each service mounts a dedicated data directory on the host (all under `./data/`).

The `invoiceshelf` container runs as **uid 82 (www-data), gid 82** and does not
take ownership of its mounted directories itself — see
[Data Directories](#data-directories).

## Quickstart

1. Copy the env template and fill in every `CHANGEME` value:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
2. Run the bootstrap script (creates the data directories, sets the ownership,
   pulls the images, starts the stack and waits until InvoiceShelf answers):
   ```bash
   ./scripts/bootstrap.sh
   ```
3. Open the instance and complete the setup wizard. The first account created
   becomes the super admin.
4. Set `APP_URL`, `SESSION_DOMAIN` and `SANCTUM_STATEFUL_DOMAINS` to the real
   address before you log in — Sanctum rejects a login whose origin does not
   match `SANCTUM_STATEFUL_DOMAINS`.
5. Put a reverse proxy in front of it for TLS termination and set
   `SESSION_SECURE_COOKIE=true` (see [Reverse Proxy](#reverse-proxy)).

Without the script: `docker compose pull && docker compose up -d`. Note that this
skips the `chown` on the storage directories, and the container stops at boot with
`Cannot write to /var/www/html/storage` until it is applied.

**Update:** `./scripts/upgrade.sh <version>` — or, without backup, version check
and migration, `docker compose pull && docker compose up -d`.

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `invoiceshelf` | Prefix used in all `container_name` values |
| `INVOICESHELF_VERSION` | `2.4.7` | InvoiceShelf image tag — pinned to a released version, never `latest` |
| `POSTGRES_VERSION` | `16` | PostgreSQL image tag |
| `INVOICESHELF_BIND_ADDR` | `127.0.0.1` | Interface the web UI is published on — loopback behind a reverse proxy, `0.0.0.0` for LAN |
| `INVOICESHELF_HOST_PORT` | `8090` | Host port mapped to the container's port 8080 |
| `INVOICESHELF_STORAGE` | `./data/invoiceshelf/storage` | Host path for uploads, generated PDFs, sessions, logs and `storage/app/.app_key` |
| `INVOICESHELF_MODULES` | `./data/invoiceshelf/modules` | Host path for installed application modules |
| `POSTGRES_DATA` | `./data/invoiceshelf/postgres` | Host path for persistent PostgreSQL data files |
| `INVOICESHELF_UID` / `INVOICESHELF_GID` | `82` | User/group of the container process and owner of the two storage directories |
| `APP_NAME` | `InvoiceShelf` | Name in the browser tab and in outgoing mail |
| `APP_ENV` | `production` | `production` or `local` |
| `APP_DEBUG` | `false` | Never `true` in production — stack traces reach the browser |
| `APP_KEY` | _(generated)_ | Signs cookies and encrypted values; `scripts/bootstrap.sh` fills it in. Changing it logs everyone out and makes stored credentials unreadable |
| `APP_TIMEZONE` | `UTC` | Timezone for dates in the UI and in documents |
| `APP_URL` | `http://localhost:8090` | Public URL exactly as typed in the browser — wrong values break login and mail links |
| `APP_LOCALE` | `en` | Interface language |
| `DB_CONNECTION` | `pgsql` | Database engine |
| `POSTGRES_DB` | `invoiceshelf` | Database name — shared by both services |
| `POSTGRES_USER` | `invoiceshelf` | PostgreSQL username — shared by both services |
| `POSTGRES_PASSWORD` | _(generated)_ | PostgreSQL password — shared by both services |
| `SESSION_DRIVER` | `file` | Session storage; `file` keeps sessions on the storage volume |
| `SESSION_LIFETIME` | `240` | Session lifetime in minutes |
| `SESSION_DOMAIN` | `localhost` | Bare hostname or IP — no protocol, no path |
| `SANCTUM_STATEFUL_DOMAINS` | `localhost:8090` | Comma-separated `host:port` origins allowed to authenticate with cookies |
| `CACHE_STORE` | `file` | Cache backend; `redis` needs an additional service |
| `QUEUE_CONNECTION` | `sync` | `sync` runs queued work in the request — this stack has no worker container |
| `BROADCAST_CONNECTION` | `log` | Broadcast driver |
| `SCHEDULER_ENABLED` | `true` | Runs Laravel's scheduler in the container — recurring invoices depend on it |
| `AUTORUN_ENABLED` | `true` | Image start-up automation (artisan optimize) |
| `AUTORUN_LARAVEL_MIGRATION` | `false` | Migrations on every boot; `scripts/upgrade.sh` runs them explicitly instead |
| `AUTORUN_LARAVEL_OPTIMIZE` | `false` | Warm the config/route/view caches on boot |
| `PHP_OPCACHE_ENABLE` | `1` | PHP OPcache |
| `DOMPDF_ENABLE_REMOTE` | `false` | Allow dompdf to fetch remote URLs — keep `false`, it is an SSRF risk |
| `TRUSTED_PROXIES` | `*` | Proxies whose `X-Forwarded-*` headers are trusted; set the proxy's address behind a reverse proxy |
| `BACKUP_DIR` | `./backups` | Host path for the timestamped backup sets |
| `BACKUP_KEEP_DAYS` | `7` | Retention in days |

### Optional blocks

`env-dist` carries further settings as commented-out blocks: SMTP/transport
fallbacks (`MAIL_*`), a Gotenberg PDF driver, and the external cron token
(`CRON_JOB_AUTH_TOKEN`). An active line overrides the application's default, so
only enable what you actually use.

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` since it
> contains the database password and `APP_KEY`.

### Mail is configured in the UI, not here

Since InvoiceShelf 2.2.0 the mail transport lives in the **database**, not in the
Compose file. Configure it after the setup wizard:

- **Server-wide:** Administration → Settings → Mail Configuration (super admin)
- **Per company:** Settings → Mail Configuration (company owner)

Supported transports: SMTP, sendmail, PHP `mail()`, Amazon SES, Mailgun, Postmark.
The `MAIL_*` variables in `env-dist` only override the fallback defaults and are
commented out on purpose.

Two rules apply to company owners: they may only use **publicly reachable** mail
hosts, and a local relay must be named in `MAIL_ALLOWED_PRIVATE_HOSTS`
(comma-separated). The super admin is exempt from that restriction.

## Data Directories

All persistent data is stored on the host under `./data/`, as defined in `.env`:

| Path | Service | Purpose |
|---|---|---|
| `./data/invoiceshelf/storage/` | `invoiceshelf` | Uploads, generated PDFs, sessions, logs, `storage/app/.app_key` |
| `./data/invoiceshelf/modules/` | `invoiceshelf` | Installed application modules |
| `./data/invoiceshelf/postgres/` | `db` | PostgreSQL database files (PGDATA) |

All three are bind mounts. A backup tool that enumerates named volumes will not
find them, which is why `scripts/upgrade.sh` backs these host paths up explicitly.

> **Backup:** Take the database with `pg_dump` and archive `storage/` and
> `Modules/` — see [Backup and Restore](#backup-and-restore).
>
> `storage/` must belong to **82:82** on the host. The container never fixes the
> ownership of a bind mount, and stops at boot when it cannot write there.

## Upgrade

```bash
./scripts/upgrade.sh 2.4.8          # patch release, runs without a prompt
./scripts/upgrade.sh 2.5.0          # minor release, prompts and warns about migration
./scripts/upgrade.sh 2.5.0 --yes    # non-interactive
```

The script verifies the tag against the registry, dumps and verifies the database,
archives the storage directories, bumps `INVOICESHELF_VERSION`, resolves the
Compose file to confirm which image would really start, pulls, starts, waits for
`/healthcheck` and runs `php artisan migrate --force`.

Migrations are an explicit step: the vendor's Compose files set
`AUTORUN_LARAVEL_MIGRATION=false`, and the in-app updater is disabled in
containerised installs (`php artisan core:update` prints exactly that and exits).
Without the migration the new code runs against the old schema.

### Version policy

- **2.x only.** The 2.x line is the stable one and receives security patches until
  **2027-09-01**. The 3.x line is an alpha preview (`3.0.0-alpha.x`) and the vendor
  states it must not be used with production data — the script refuses it.
- **2.4.7 is the floor.** PHP fixed CVE-2026-109618 and CVE-2026-109619 (remote code
  execution without signing in); images up to 2.4.6 run the affected PHP 8.4.25.
  If you build the image yourself, build it from 2.4.7 or later.
- **No `latest`, no `nightly`.** `:nightly` is a transitional tag that only points at
  the stable image and will stop updating. Pin the exact version.
- **A major jump is a manual migration**, not a tag swap. The script refuses it.

## Backup and Restore

The vendor documents backups in the UI (Settings → Backups, types *full*, *only db*,
*only files*) and implements them with `spatie/laravel-backup`. That job cannot be
triggered from the command line, so `scripts/backup.sh` performs the same *full*
backup from the host:

```bash
./scripts/backup.sh                 # keep 7 days, from BACKUP_KEEP_DAYS
./scripts/backup.sh --keep-days 30  # override per run
```

A set contains `db.sql.gz` (online `pg_dump`), `data.tar.gz` (`storage/` and
`Modules/`), `env.backup` (mode 600), `MANIFEST.txt` and `images.txt`. The stack
keeps running; the database dump is the authoritative part and is verified by its
PostgreSQL header. Files that change during the archive are reported, not fatal.

Restore: stop the stack, import the dump into an empty database, unpack
`data.tar.gz` over the app directory, start. The script prints the exact commands.
`APP_KEY` must be the same as before the restore, or encrypted values — including
the stored mail credentials — become unreadable.

The in-app backup writes its ZIP into the storage volume. That is convenient for a
quick rollback, but it is not a copy off the machine either.

## Reverse Proxy

Bind the port to loopback (`INVOICESHELF_BIND_ADDR=127.0.0.1`, the default) and let
the proxy handle TLS. Three settings must line up or login fails:

| Setting | Value behind a proxy |
|---|---|
| `APP_URL` | `https://invoices.example.com` |
| `SESSION_DOMAIN` | `invoices.example.com` (no protocol, no path) |
| `SANCTUM_STATEFUL_DOMAINS` | `invoices.example.com` (add `:port` if not 80/443) |
| `SESSION_SECURE_COOKIE` | `true` |
| `TRUSTED_PROXIES` | the proxy's address instead of `*` |

The image listens on port 8080 and serves `/healthcheck` from nginx. A proxy should
forward to that port, not to 443.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/bootstrap.sh` | Creates `.env` (generates `POSTGRES_PASSWORD` and `APP_KEY`), creates the data directories and their ownership, validates Compose, starts the stack, waits for `/healthcheck` |
| `scripts/upgrade.sh` | Version check, verified backup, version bump, resolved-config assertion, pull, start, migrations |
| `scripts/backup.sh` | `pg_dump` + archive of `storage/` and `Modules/`, verification and retention |

Exit codes: `bootstrap.sh` 0/2/3/4/6, `upgrade.sh` 0/2/3/4/5/6, `backup.sh`
0/2/3/5/6. A missing `.env` or an unreachable daemon is always exit 3, never a
partial run.

## Pitfalls

| Pitfall | What happens |
|---|---|
| **Storage ownership** | The container runs as uid 82 and does not chown bind mounts. A host directory owned by your own user makes the container stop with `Cannot write to /var/www/html/storage`. `scripts/bootstrap.sh` fixes it; `docker compose up -d` alone does not |
| **`APP_KEY`** | Generated once and kept in `storage/app/.app_key` when the environment has none. Set it in `.env` to keep it independent of the volume. Changing it logs everyone out and breaks encrypted settings |
| **Migrations are not automatic** | The vendor's Compose files set `AUTORUN_LARAVEL_MIGRATION=false`, and the in-app updater refuses to run in containers. A bare `pull` + `up -d` leaves the old schema in place |
| **`APP_URL` / `SANCTUM_STATEFUL_DOMAINS`** | A mismatch rejects every login with an unauthenticated response. The port belongs in `SANCTUM_STATEFUL_DOMAINS`, not in `SESSION_DOMAIN` |
| **Mail settings are in the database** | `MAIL_*` in the environment are only fallbacks. Configure the transport in the UI, or nothing is sent |
| **Scheduler** | Recurring invoices, overdue flags and estimate expiry are driven by Laravel's scheduler inside the container. `SCHEDULER_ENABLED=false` without a replacement stops all of it |
| **PostgreSQL major upgrade** | `postgres:16` keeps its data in `/var/lib/postgresql/data`. A jump to 18 moves the mount point to `/var/lib/postgresql/<major>/docker`; the data needs a dump/restore, not a volume swap |
| **In-app updater** | Disabled in containers. The "Update" button in the UI does nothing; upgrades go through the image tag |
| **`DOMPDF_ENABLE_REMOTE=true`** | Lets HTML in PDF notes make the server fetch arbitrary URLs. Keep it `false` |
| **`TRUSTED_PROXIES=*`** | Accepts `X-Forwarded-For` from anyone. Fine on a loopback bind, wrong once the port is reachable from a network |

## Verification

Without a Docker daemon this stack is verified statically:

```bash
bash -n apps/invoiceshelf/scripts/*.sh
shellcheck -S style apps/invoiceshelf/scripts/*.sh
python -c "import yaml; yaml.safe_load(open('apps/invoiceshelf/docker-compose.yaml'))"
docker compose -f apps/invoiceshelf/docker-compose.yaml config
```

The script behaviour is covered by `tests/run-stack-script-tests.sh`, which drives
all three scripts against stub binaries (no daemon, no registry).

## Sources

- [InvoiceShelf documentation](https://docs.invoiceshelf.com/)
- [InvoiceShelf/docker – production images and Compose variants](https://github.com/InvoiceShelf/docker)
- [Backups (UI)](https://docs.invoiceshelf.com/guide/backups.html)
- [Email / mail transports](https://docs.invoiceshelf.com/guide/mail.html)
- [Release 2.4.7 – CVE-2026-109618 / CVE-2026-109619](https://github.com/InvoiceShelf/InvoiceShelf/releases/tag/2.4.7)
- [serversideup/php – base image, `/healthcheck` and `AUTORUN_*`](https://serversideup.net/open-source/docker-php/docs/image-variations/fpm-nginx)
