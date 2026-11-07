# Open Notebook – Self-Hosted Research Notebook (Docker Setup)

This repository contains a Docker Compose stack for
[Open Notebook](https://github.com/lfnovo/open-notebook), a self-hosted
alternative to Google NotebookLM: sources in, notes and summaries out, with any
LLM provider you configure.
Supported architectures: `amd64`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `open_notebook` | `lfnovo/open_notebook:1.15.1` | Next.js UI on `8502`, FastAPI backend on `5055` and a background worker — all in one image under supervisord |
| `surrealdb` | `surrealdb/surrealdb:v2.7.0` | Document database (RocksDB) for sources, notes, embeddings and the job queue |

The UI and the API listen on separate ports. Browsers load the page from `8502`
and call the API directly on `5055` — both ports have to be reachable, or
`API_URL` must point the browser at the UI address. See
[Access from another machine](#access-from-another-machine).

## Quickstart

1. Copy the env template and generate the secrets:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
   Fill in `OPEN_NOTEBOOK_ENCRYPTION_KEY`, `OPEN_NOTEBOOK_PASSWORD` and
   `SURREAL_PASSWORD`. Or let the bootstrap script generate all three.
2. Run the bootstrap script:
   ```bash
   ./scripts/bootstrap.sh
   ```
   It creates `.env` if missing (generating the encryption key and both
   passwords), creates the data directories, validates the Compose file, pulls
   the images, starts the stack and waits for `/health`.
3. Open <http://127.0.0.1:8502> and sign in with the password from `.env`.
4. Configure providers in the UI under **Manage → Models**. Credentials are
   stored encrypted in the database — they do not belong in `.env`.

**Update:** run `./scripts/upgrade.sh <version>`. It verifies the tag against
Docker Hub, takes a verified backup, bumps the version and waits for health.
A plain `docker compose pull && docker compose up -d` also works, but skips the
backup — which is the only way back after an encryption-format change.

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `OPEN_NOTEBOOK_VERSION` | `1.15.1` | Pinned image tag (never `latest`) |
| `SURREALDB_VERSION` | `v2.7.0` | Pinned SurrealDB image tag |
| `COMPOSE_PROJECT_NAME` | `open-notebook` | Prefix for container and network names |
| `BIND_ADDR` | `127.0.0.1` | Interface the UI and API are published on |
| `OPEN_NOTEBOOK_UI_PORT` | `8502` | Host port of the web UI |
| `OPEN_NOTEBOOK_API_PORT` | `5055` | Host port of the REST API |
| `SURREAL_PORT` | `8000` | Host port of the database, loopback debugging only |
| `OPEN_NOTEBOOK_ENCRYPTION_KEY` | `CHANGEME` | Encrypts provider credentials — `openssl rand -hex 32` |
| `OPEN_NOTEBOOK_PASSWORD` | `CHANGEME` | UI/API password; empty disables authentication |
| `SURREAL_USER` | `root` | Database user |
| `SURREAL_PASSWORD` | `CHANGEME` | Database password — `openssl rand -hex 32` |
| `SURREAL_URL` | `ws://surrealdb:8000/rpc` | Database URL inside the compose network |
| `SURREAL_NAMESPACE` | `open_notebook` | SurrealDB namespace |
| `SURREAL_DATABASE` | `open_notebook` | SurrealDB database |
| `SURREAL_UID` / `SURREAL_GID` | `0` / `0` | User the database container runs as |
| `OPEN_NOTEBOOK_MAX_UPLOAD_SIZE_MB` | `100` | Largest request body the API accepts |
| `OPEN_NOTEBOOK_WORKER_MAX_TASKS` | `5` | Concurrent background jobs (1 on single-GPU setups) |
| `API_URL` | empty | API address as the browser reaches it |
| `SURREAL_DATA` | `./data/open-notebook/surreal` | RocksDB data directory |
| `NOTEBOOK_DATA` | `./data/open-notebook/notebook` | Uploads and caches |
| `BACKUP_DIR` | `./backups` | Where `scripts/backup.sh` writes its sets |
| `BACKUP_KEEP_DAYS` | `7` | Retention in days |

> ⚠️ **Keep your `.env` out of version control** — it contains three secrets.

## Data Directories

| Path | Mount | Purpose |
|---|---|---|
| `./data/open-notebook/surreal` | `/mydata` | RocksDB files: sources, notes, embeddings, job queue |
| `./data/open-notebook/notebook` | `/app/data` | Uploads, uv/Playwright/HuggingFace caches, tokenizer cache |

Both directories are required. The database holds the documents, the
application folder holds the uploads — one without the other is an instance that
starts but shows nothing.

### Permissions

The vendor ships SurrealDB with `user: root` because a bind mount owned by the
host user is only writable for uid 0 inside the container. This stack makes that
configurable: with `SURREAL_UID=0` (the default) the database writes as root and
the files belong to root, so `scripts/backup.sh` needs `sudo`. Set
`SURREAL_UID`/`SURREAL_GID` to your own `id -u`/`id -g` and run
`sudo chown -R <uid>:<gid> ./data/open-notebook/surreal` once to keep everything
operator-owned and backups password-free.

## Scripts

| File | Purpose |
|---|---|
| `scripts/bootstrap.sh` | First-time setup: `.env` with generated secrets, data directories, pull, start, health check |
| `scripts/upgrade.sh` | Version bump with registry check, verified backup, resolved-image assertion |
| `scripts/backup.sh` | Vendor procedure: stop, archive both data folders, start again, verify, retention |

### Backups

The project's documentation prescribes the procedure: stop the services and copy
both data folders.

```bash
docker compose down
tar czf open-notebook-backup.tgz surreal_data notebook_data
docker compose up -d
```

`scripts/backup.sh` does exactly that, plus the house conventions: a timestamped
set with the resolved image tags, a copy of `.env`, a manifest, verification and
retention. Stopping matters: RocksDB writes continuously, and a copy taken from a
running database can be torn. Downtime is a few seconds. The script starts the
stack again even when a step fails. Basis:
[Open Notebook – Docker Compose](https://github.com/lfnovo/open-notebook/blob/main/docs/1-INSTALLATION/docker-compose.md#back-up).

## Pitfalls

| Case | Behaviour / remedy |
|---|---|
| **`OPEN_NOTEBOOK_ENCRYPTION_KEY` lost or changed** | Stored provider credentials can no longer be decrypted. It is in `.env`, which every backup set contains |
| **`OPEN_NOTEBOOK_PASSWORD` empty** | Authentication is **off** — anyone who can reach the ports gets in. Set it as soon as the ports leave loopback |
| **Only the UI port published** | The browser calls the API on port `5055` of the page's host and fails. Publish both ports or set `API_URL` to the UI's public URL |
| **Both ports published, `API_URL` set** | API calls go through the Next.js `/api/*` forwarding, capped at 100 MB. Uploads above that need direct API access |
| **Bind mount owned by another user** | SurrealDB cannot write its RocksDB files and exits. `SURREAL_UID`/`SURREAL_GID` and the directory owner must match |
| **Root-owned data directories** | `scripts/backup.sh` cannot read the files as the operator. Run it with `sudo`, or chown the directories and set `SURREAL_UID`/`SURREAL_GID` |
| **Major jump without release notes** | The v1 line changed the credential encryption format at v1.15.0. Read the release notes, keep the pre-upgrade backup |
| **`docker compose down -v`** | Harmless here — the stack uses bind mounts, not named volumes. `down -v` deletes nothing |
| **Uploads > 100 MB** | Raise `OPEN_NOTEBOOK_MAX_UPLOAD_SIZE_MB`; a reverse proxy's `client_max_body_size` applies on top |
| **Ollama on the host** | Containers cannot reach `127.0.0.1:11434`. Set `OLLAMA_HOST=0.0.0.0:11434`, allow the port for Docker networks only, and use `http://host.docker.internal:11434` as the base URL |

## Access from another machine

The browser loads the UI from port `8502` and calls the API on port `5055` of the
same host name. So either:

- publish **both** ports beyond loopback (`BIND_ADDR=0.0.0.0`), or
- publish only `8502` and set `API_URL` to the address the UI is opened with,
  e.g. `API_URL=https://notebook.example.com`. API calls then go through the UI
  server and only one port needs to be reachable.

A password is mandatory in both cases. For HTTPS and domains, put a reverse
proxy in front and set `API_URL` to the public URL — without an `/api` suffix.
