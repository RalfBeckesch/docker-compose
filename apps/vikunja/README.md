# Vikunja – Self-Hosted Task Management (Docker Setup)

This directory contains a Docker Compose stack for [Vikunja](https://vikunja.io),
a self-hosted task and project management application with a web UI, REST API,
CalDAV support, and mobile/desktop clients. It is backed by PostgreSQL and designed
to stay updatable: the version lives in a single place, state lives in bind-mounted
host directories, and every upgrade takes a verified backup first.
Supported architectures: `amd64`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `vikunja` | `vikunja/vikunja:${VIKUNJA_VERSION}` | Task management API and web frontend in one container, exposed via `BIND_ADDR`/`HTTP_PORT` |
| `db` | `postgres:${POSTGRES_VERSION}` | PostgreSQL database backend |

The `vikunja` service waits for the `db` healthcheck to pass before starting.
Each service mounts a dedicated data directory on the host (both under `./data/`).

The `vikunja` container runs as UID 1000 and does not take ownership of its files
directory itself — see [Data Directories](#data-directories) and the
`the files directory` note under [Pitfalls](#pitfalls).

## Quickstart

1. Copy the env template and fill in every `CHANGEME` value:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
2. Run the bootstrap script (creates the data directories, sets the file
   ownership, pulls the images, starts the stack and waits until Vikunja answers):
   ```bash
   ./scripts/bootstrap.sh
   ```
3. Open the instance, register your account, then disable self-registration:
   ```bash
   # set VIKUNJA_ENABLE_REGISTRATION=false in .env, then
   docker compose up -d
   ```
4. Put a reverse proxy in front of it for TLS termination (see
   [Reverse Proxy](#reverse-proxy)).

Without the script: `docker compose pull && docker compose up -d`. Note that this
skips the `chown` on the files directory, and uploads will fail until it is applied.

**Update:** `./scripts/upgrade.sh <version>` — or, without backup and verification,
`docker compose pull && docker compose up -d`.

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `vikunja` | Prefix used in all `container_name` values |
| `VIKUNJA_VERSION` | `2.7.1` | Vikunja image tag — pinned to a released version, never `latest` |
| `POSTGRES_VERSION` | `18` | PostgreSQL image tag — the version Vikunja's CI tests |
| `BIND_ADDR` | `127.0.0.1` | Interface the web UI is published on — loopback behind a reverse proxy, `0.0.0.0` for LAN |
| `HTTP_PORT` | `3456` | Host port mapped to the container's port 3456 |
| `VIKUNJA_FILES` | `./data/vikunja-files` | Host path for attachments, avatars and other uploads |
| `POSTGRES_DATA` | `./data/postgres` | Host path for persistent PostgreSQL data files |
| `VIKUNJA_PUBLIC_URL` | `http://localhost:3456/` | Public URL exactly as reachable in the browser, trailing slash included |
| `VIKUNJA_SERVICE_SECRET` | _(required)_ | Signs login tokens — generate with `openssl rand -hex 32`; changing it invalidates all sessions |
| `VIKUNJA_TIMEZONE` | `America/Winnipeg` | Timezone for date handling and CalDAV |
| `VIKUNJA_ENABLE_REGISTRATION` | `true` | Self-registration — set to `false` once all accounts exist |
| `VIKUNJA_CORS_ENABLE` | `true` | CORS handling — leave enabled while `VIKUNJA_PUBLIC_URL` is correct |
| `VIKUNJA_UID` / `VIKUNJA_GID` | `1000` | User/group of the container process and owner of `VIKUNJA_FILES` |
| `POSTGRES_DB` | `vikunja` | Database name created on first startup |
| `POSTGRES_USER` | `vikunja` | PostgreSQL username — shared by both services |
| `POSTGRES_PASSWORD` | _(required)_ | PostgreSQL password — shared by both services |

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` since it contains
> the database password and the token secret.

## Data Directories

All persistent data is stored on the host under `./data/`, as defined in `.env`:

| Path | Service | Purpose |
|---|---|---|
| `./data/vikunja-files/` | `vikunja` | Attachments, avatars, uploaded files |
| `./data/postgres/` | `db` | PostgreSQL database files (PGDATA) |

Both directories are bind mounts. A backup tool that enumerates named volumes will
not find them, which is why `scripts/upgrade.sh` backs these host paths up explicitly.

> **Backup:** Back up both directories, ideally as a matched pair from the same point
> in time. A plain `pg_dump` is the consistent way to capture the database — see
> [Backup and Restore](#backup-and-restore).
>
> Project deletion in Vikunja is permanent: there is no trash, recycle bin or undo.

## Upgrade

```bash
./scripts/upgrade.sh 2.7.2          # patch release, runs without a prompt
./scripts/upgrade.sh 2.8.0          # minor release, prompts and warns about migration
./scripts/upgrade.sh 2.8.0 --yes    # minor release without the prompt
```

The script, in this order:

1. Verifies the target tag exists in the registry (no guessing).
2. Detects patch vs. minor/major, and asks for confirmation on the latter.
3. Creates `backup/<timestamp>/` and records the running image tags and `.env`.
4. Runs `pg_dump` **while the stack is still up** and verifies it (gzip integrity,
   minimum size, `PostgreSQL database dump` marker).
5. Stops the stack (plain `down`, never `down -v`).
6. Archives `.env` and both data directories into `data.tar.gz`.
7. Bumps `VIKUNJA_VERSION` in `.env`.
8. Checks the **resolved** Compose configuration — if it would not start the target
   tag, the script aborts instead of starting the wrong version.
9. Pulls, starts, waits for `/api/v1/info`, and confirms the running image.
10. Prints the rollback commands.

### Version policy

| | |
|---|---|
| Pinning | Exactly one version in `.env`. Never `latest`, never `unstable`. |
| Patch releases (`2.7.1` → `2.7.2`) | Bug and security fixes, treated as low risk. |
| Minor releases (`2.7` → `2.8`) | New features and sometimes breaking API changes — read the release article's "Things to check when upgrading" section first. |
| Intermediate versions | Not required: Vikunja migrates straight to the target version. |
| Downgrade | Not supported. The only way back is a restore from the backup described below. |

Vikunja has no LTS branch. `2.7.1` was chosen because it is the newest stable
release and carries 41 security fixes (2 high, 24 medium, 15 low); older versions
mean open advisories rather than more stability.

## Backup and Restore

Manually:

```bash
docker compose exec -T db pg_dump -U vikunja -d vikunja | gzip > backup/db-$(date +%F).sql.gz
tar -czf backup/files-$(date +%F).tar.gz data/vikunja-files
```

Use `-T` so `pg_dump` writes through to the host file instead of allocating a TTY,
and so the archive does not end up inside the container.

**Rollback after an upgrade.** Resetting `VIKUNJA_VERSION` alone is **not** enough:
the newer version migrated the database schema, an older Vikunja cannot read it, and
restoring a `pg_dump` into an already-migrated database fails. The path leads through
the data directory:

```bash
docker compose down
sed -i 's/^VIKUNJA_VERSION=.*/VIKUNJA_VERSION=<previous version>/' .env
rm -rf data/postgres/*                 # discard the migrated schema (the dump remains in backup/)
docker compose up -d db
gunzip -c backup/<timestamp>/db.sql.gz | docker compose exec -T db psql -U vikunja -d vikunja
docker compose up -d
```

As an alternative without a database restore, unpack `backup/<timestamp>/data.tar.gz`,
which holds `.env` and both data directories as they were before the upgrade.

Always restore a dump with the **same version** that created it.

## Reverse Proxy

The stack publishes HTTP on `BIND_ADDR:HTTP_PORT` and expects TLS termination
upstream (Apache2 + Certbot, Traefik, Nginx Proxy Manager, Caddy). Set
`VIKUNJA_PUBLIC_URL` to the external URL including the trailing slash, for example
`https://vikunja.example.com/`, and keep `BIND_ADDR=127.0.0.1`.

Caddy example:

```
vikunja.example.com {
    reverse_proxy 127.0.0.1:3456
}
```

## Scripts

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Main stack definition |
| `env-dist` | Environment template copied to `.env` |
| `scripts/bootstrap.sh` | First-time setup: `.env` creation with generated secrets, data directories, ownership, pull, start, readiness wait |
| `scripts/upgrade.sh` | Version bump with verified backup, resolved-config check, verification and rollback instructions |
| `scripts/backup.sh` | `vikunja dump` (config, files and database in one archive) plus `pg_dump`, with verification, retention and restore instructions |
| `scripts/test-deploy.sh` | Test matrix for everything checkable without a running Docker daemon |

Backups: `./scripts/backup.sh` uses Vikunja's own `dump` command — configuration,
uploaded files and the complete database in one archive — and takes a plain
`pg_dump` on top, which is the faster way back after a failed upgrade. The
archive is written into the mounted files directory and moved out afterwards.
Sets land in `$BACKUP_DIR` (default `./backups`), pruned after `BACKUP_KEEP_DAYS`.

## Pitfalls

| Case | Behaviour / remedy |
|---|---|
| **postgres:18 data path** | `PGDATA=/var/lib/postgresql/18/docker` inside the image, with `/var/lib/postgresql` declared as the volume — hence the mount point here. `postgres:16/17` used `.../data`. A wrong mount leaves the real data outside the volume and it disappears on the next container recreation. Verify the live mounts: `docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' vikunja-db` |
| **PostgreSQL major upgrade (18 → 19)** | The PGDATA path carries the major version. A new image finds nothing at the new path and initialises an empty database. Dump the data and move it over with `pg_upgrade` or a restore — do not just swap the tag |
| **Files directory not owned by `VIKUNJA_UID`** | Uploads and avatar storage fail with `permission denied` while the container itself looks healthy |
| **Rootless Docker** | Permission checks happen at kernel level with a different UID mapping → set `user: "0:0"` on the service. `vikunja doctor` detects this case |
| **`down -v`** | Removes volumes. Not used anywhere in the scripts — do not add it manually |
| **`$` in passwords** | Compose interpolates; write `$` as `$$`. Values generated by `openssl rand -hex 32` contain no `$`, so `set -a; . ./.env` in the scripts reads them cleanly |
| **Self-registration left open** | Set `VIKUNJA_ENABLE_REGISTRATION=false` and run `docker compose up -d` once all accounts exist |
| **Wrong `VIKUNJA_PUBLIC_URL`** | CORS is enabled: the frontend loads but receives no API responses. The URL must match the browser exactly, trailing slash included |
| **No healthcheck for Vikunja** | The upstream image ships none. The stack therefore uses `depends_on` for start ordering only and verifies readiness with the wait loop in `scripts/bootstrap.sh`; the healthcheck is supplied commented out |
| **`docker exec` inherits no host environment** | Paths, users and database names are set explicitly in the scripts or read from `.env` |

## Verification

`scripts/test-deploy.sh [path-to-shellcheck]` runs the test matrix that worked without a
Docker daemon (working copy in `$TMPDIR`):

| Check | Content |
|---|---|
| Syntax | `bash -n` for both scripts |
| ShellCheck | `shellcheck -S style` without findings |
| Compose | YAML parse, pinning (no `latest`/`unstable`, every `image:` line driven by `${…}`), PGDATA not overridden, `${VAR}` in the Compose file ↔ keys in `env-dist` in both directions |
| Arguments | `--help`, missing/invalid target version, `latest`, RC tag, unknown option |
| Registry | Target tag exists (HTTP 200) or is correctly rejected (404) |
| Bootstrap | `.env` creation without Docker: version taken over, secret 32 bytes hex, no active `CHANGEME` assignments, mode 600, upstream CHANGELOG in `ref/`, idempotent second run |
| Fail-fast | Without a daemon, `bootstrap.sh` exits 1 with a clear message instead of half-starting |

Last run 2026-11-04: **28 OK, 0 FAIL** (ShellCheck test needs `shellcheck`, registry test needs network).

**Not checkable locally** — happens on the target host: `docker compose config`,
image pull, container start, PostgreSQL initialisation, the readiness wait, file
ownership, and the first account creation.

## Sources

- Compose reference: https://vikunja.io/docs/full-docker-example/
- Configuration options: https://vikunja.io/docs/config-options/
- Backup: https://vikunja.io/docs/what-to-backup/
- Install & database versions: https://vikunja.io/docs/installing/
- Release 2.7.1: https://vikunja.io/changelog/vikunja-2.7.1-was-released/
- `PGDATA`/`VOLUME` in postgres:18: `docker-library/postgres`, `18/bookworm/Dockerfile`
- `/api/v1/info` route: `go-vikunja/vikunja` v2.7.1, `pkg/routes/routes.go`
