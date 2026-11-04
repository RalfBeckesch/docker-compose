# 🐳 docker-compose

Personal Docker Compose configurations for self-hosted services — production-ready, opinionated, and built for real infrastructure at customers and at my homelab (usually Proxmox -> Debian VMs).

---

## Structure

Each directory contains a self-contained Compose stack:

- `docker-compose.yaml` — service definitions
- `env-dist` — environment variable template (no real secrets ever committed)
- `README.md` — service-specific notes (where applicable)
- `scripts/` — optional helper scripts for a stack (e.g. bootstrap, upgrade)

---

## Examples

### ☁️ Nextcloud
High-performance Nextcloud setup based on the official Apache image.

**Stack:** `nextcloud:apache` · `PostgreSQL 16` · `Redis 7` · `Imaginary`

- PostgreSQL instead of MariaDB — better performance, no workarounds needed
- Redis for file locking and session cache (pure in-memory, no disk writes)
- Imaginary as external preview service (libvips, ~10× faster than GD)
- OPcache + JIT tuning via bind-mounted `opcache.ini`
- Apache tuning via `nextcloud.conf` (KeepAlive, mod_deflate, cache headers)
- Dedicated cron container instead of web-cron

---

## Principles

- **Bind mounts over named volumes** — data stays transparent on the host, easy to back up
- **Runtime data under `./data/`** — every stack keeps its data in a `data/` directory next to its
  Compose file (configurable per app via `.env`), so a single `.gitignore` rule covers all of them
- **`.env` files for all secrets** — no passwords in `docker-compose.yaml`, ever
- **Healthchecks** on all critical services with `condition: service_healthy`
- **`unless-stopped`** as the default restart policy
- **Alpine images** where available — smaller attack surface, faster pulls

---

## Usage

```bash
git clone https://github.com/RalfBeckesch/docker-compose.git
cd docker-compose/apps/<service>
cp env-dist .env
# edit .env and fill in your values
chmod 600 .env
docker compose up -d
```

---

## Upgrades

A version bump is **not** `docker compose pull && docker compose up -d` for most of
these stacks: their databases are migrated in place, and a migrated database cannot be
read by the old image again. The stacks that carry state therefore ship an
`upgrade.sh` in `apps/<service>/scripts/`, which

1. verifies that the target image tag actually exists in the registry,
2. classifies the jump (patch / minor / major) and asks before a risky one,
3. writes a backup and refuses to continue if it is not verifiable
   (database dump with a PostgreSQL header, `.env`, data directories),
4. pins the new tag in the stack's env file — one value, not an edit of the Compose file,
5. resolves the Compose file and asserts which image would really start,
6. starts the stack, waits until it answers, and prints rollback instructions.

```bash
cd docker-compose/apps/mealie
./scripts/upgrade.sh v3.14.0          # asks before a risky jump
./scripts/upgrade.sh v3.14.0 --yes    # non-interactive
```

`stirling-pdf` and `searxng` have **no** upgrade script on purpose: neither keeps a
database that a new image would have to migrate, so `pull` + `up -d` is the complete
and correct procedure there. `forgejo` has no script because the stack does not exist
yet.

---

## Backups

`apps/<service>/scripts/backup.sh` writes a verified, timestamped backup set. The
procedure is not invented: each script follows what the vendor documents for its own
application, because a generic "tar the folder" is wrong more often than it is right.

| Stack | What the script does | Basis |
|---|---|---|
| vikunja | `vikunja dump` (config, files, whole database) + `pg_dump` | [Vikunja CLI](https://vikunja.io/docs/cli/#dump) |
| nextcloud | maintenance mode on → `pg_dump` → archive → mode off, with a trap so the mode never stays on | [Nextcloud admin manual](https://docs.nextcloud.com/server/stable/admin_manual/maintenance/backup.html) |
| paperless-ngx | `document_exporter` into the export mount + `pg_dump`, after checking that nothing is being consumed | [Paperless docs](https://docs.paperless-ngx.com/administration/#making-backups) |
| vaultwarden | SQLite online backup via `sqlite3 .backup` (+ `integrity_check`); without `sqlite3` a short stop-and-copy of `db.sqlite3`, `-wal` and `-shm` | [Vaultwarden wiki](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault) |
| mealie | `pg_dump` + data directory (the built-in backups are BETA and need an admin token) | [Mealie docs](https://docs.mealie.io/documentation/admin/backups-and-exports) |
| ntfy | `pg_dump` (cache, users, ACLs, tokens) + config directory; message cache and attachments are deliberately skipped — they expire after 12h / 3h | [ntfy config docs](https://docs.ntfy.sh/config/) |
| stirling-pdf | short stop → archive `${extraConfigs}` (settings, keystore, built-in database), custom files, pipeline | [Stirling-PDF configs](https://docs.stirlingpdf.com/) |
| searxng | archive the configuration mount (`settings.yml`, `limiter.toml`, `favicons.toml`) while the container keeps running; cache and Valkey are deliberately skipped | [SearXNG Docker docs](https://docs.searxng.org/admin/installation-docker.html) |

Every set contains the app's `.env` (mode 600), a `MANIFEST.txt` describing what was
captured, and the resolved image tags (`images.txt`). Each script verifies what it
wrote — the *uncompressed* PostgreSQL header, the archive entries, the SQLite magic
bytes — and prints restore instructions instead of stopping at "done".

```bash
cd docker-compose/apps/vaultwarden
./scripts/backup.sh                 # keep 7 days, from BACKUP_KEEP_DAYS
./scripts/backup.sh --keep-days 30  # override per run
```

Retention: a set older than `BACKUP_KEEP_DAYS` is deleted. That model is borrowed
from the widely used container backup tools — [`offen/docker-volume-backup`](https://github.com/offen/docker-volume-backup)
(~4k stars, local/S3/WebDAV, GPG, rotation) and [`prodrigestivill/postgres-backup-local`](https://github.com/prodrigestivill/postgres-backup-local)
(daily/weekly/monthly rotation). If you want offsite copies, notifications or
encryption without writing it yourself, those are the tools to put next to this repo;
the scripts here deliberately stop at a local, verifiable set.

**A backup on the same disk is not a backup.** `BACKUP_DIR` defaults to `./backups`
next to the stack — copy that directory to another machine or medium. And test a
restore before you need it: every script prints the exact steps.

```bash
# nightly at 03:20, for every stack that has a backup script
20 3 * * * cd /opt/stacks/docker-compose/apps/mealie && ./scripts/backup.sh >> /var/log/mealie-backup.log 2>&1
```

## Infrastructure

These configurations are designed to run on:

- **Hypervisor:** Proxmox VE
- **Guest OS:** Debian / Alpine Linux
- **Reverse proxy:** upstream proxy (Apache2 + Certbot / Traefik / Nginx Proxy Manager) handles SSL termination
- **Networking:** all services communicate over internal Docker networks; only the app port is exposed

---

## License

MIT — use freely, no warranties.
