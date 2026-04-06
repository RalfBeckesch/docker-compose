 
# Nextcloud – Self-Hosted Cloud Storage (Docker Setup)

This directory contains a Docker Compose stack for [Nextcloud](https://nextcloud.com),
a self-hosted file sync, share, and collaboration platform with a web UI, desktop / mobile clients,
and a broad app ecosystem. This setup is optimized for homelab and small-team deployments and uses
PostgreSQL, Redis, Imaginary, and a dedicated cron container for better performance and reliability.
Supported architectures: `amd64`, `arm64`.

## Services

| Service | Image | Description |
|---|---|---|
| `db` | `postgres:${POSTGRES_VERSION}` | PostgreSQL database backend |
| `redis` | `redis:${REDIS_VERSION}` | In-memory cache and transactional file locking |
| `app` | `nextcloud:${NEXTCLOUD_VERSION}` | Main Nextcloud application (Apache2 + mod_php) |
| `imaginary` | `ghcr.io/nextcloud-releases/aio-imaginary:latest` | External preview service based on libvips |
| `cron` | `nextcloud:${NEXTCLOUD_VERSION}` | Dedicated background job runner using `/cron.sh` |

The stack uses an internal bridge network for inter-service communication.
Only the `app` service exposes an HTTP port to the host system.

## Quickstart

1. Copy the env template and adjust values as needed:
   ```bash
   cp env-dist .env
   chmod 600 .env
   ```
2. Pull the images:
   ```bash
   docker compose pull
   ```
3. Start the stack:
   ```bash
   docker compose up -d
   ```
4. Wait about 60 seconds for the initial Nextcloud setup to finish, then run the post-install script:
   ```bash
   bash post-install.sh
   ```

**Update:** `docker compose pull && docker compose up -d`

## Configuration (`.env`)

The file `env-dist` is the configuration template. Copy it to `.env` before deployment.

### All settings

| Variable | Default | Description |
|---|---|---|
| `INSTANCE_NAME` | `nextcloud-apache` | Prefix used in all `container_name` values |
| `POSTGRES_VERSION` | `16-alpine` | PostgreSQL image tag |
| `POSTGRES_DATA` | `./data/postgres` | Host path for persistent PostgreSQL data files |
| `POSTGRES_DB` | `nextcloud` | Database name created on first startup |
| `POSTGRES_USER` | `nextcloud` | PostgreSQL username used by Nextcloud |
| `POSTGRES_PASSWORD` | _(required)_ | PostgreSQL password |
| `NEXTCLOUD_VERSION` | `31-apache` | Nextcloud image tag used by the app and cron services |
| `NEXTCLOUD_DATA` | `/srv/nextcloud-data` | Host path for Nextcloud user data |
| `NEXTCLOUD_APP_DATA` | `./data/nextcloud-app` | Host path for the Nextcloud application directory |
| `NEXTCLOUD_CONFIG` | `./data/nextcloud-config` | Host path for the Nextcloud configuration directory |
| `NEXTCLOUD_ADMIN_USER` | `admin` | Initial admin username, evaluated only on first startup |
| `NEXTCLOUD_ADMIN_PASSWORD` | _(required)_ | Initial admin password, evaluated only on first startup |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `localhost nc.mycloud.org` | Space-separated list of allowed hostnames / IPs |
| `NEXTCLOUD_URL` | `https://nc.mycloud.org` | Public-facing base URL of the instance |
| `HTTP_PORT` | `8080` | Host port exposed by the app container |
| `TRUSTED_PROXIES` | `172.16.0.0/12 127.0.0.1` | Reverse proxy subnet(s) used for forwarded client IP handling |
| `NC_PHONE_REGION` | `DE` | Default phone region for the Contacts app |
| `REDIS_VERSION` | `7-alpine` | Redis image tag |
| `REDIS_PASSWORD` | _(required)_ | Redis password used for cache and file locking |

> ⚠️ **Keep your `.env` out of version control** — add it to `.gitignore` since it contains
> database credentials, admin credentials, and the Redis password.

## Runtime Files

The stack uses additional local configuration files mounted into the containers:

| File | Purpose |
|---|---|
| `docker-compose.yaml` | Main stack definition |
| `env-dist` | Environment template copied to `.env` |
| `apache/nextcloud.conf` | Custom Apache VirtualHost configuration |
| `php/opcache.ini` | PHP OPcache + JIT tuning |
| `post-install.sh` | One-time post-install configuration helper |
| `run-occ-in-docker.sh` | Helper script to run `occ` commands inside the app container |

## Post-Install Script

After the first startup, `post-install.sh` applies additional Nextcloud settings that are not fully handled by environment variables alone.

It performs the following tasks:

- Configures Redis as local cache, distributed cache, and file-locking backend.
- Enables Imaginary as the preview provider.
- Switches background jobs from web-cron to cron mode.
- Adds missing database indices.
- Converts file cache columns to `bigint`.

Run it once after the initial deployment:

```bash
bash post-install.sh
```

## OCC Helper Script

The included `run-occ-in-docker.sh` script is a convenience wrapper for executing `occ`
commands inside the running Nextcloud application container.

Example:

```bash
bash run-occ-in-docker.sh files:scan --all -v
```

This is useful for maintenance tasks such as rescanning files, checking status, or running repair commands.

## Apache Configuration

The custom `apache/nextcloud.conf` file is mounted into the app container and applies several HTTP-level optimisations:

- KeepAlive enabled for connection reuse.
- Compression via `mod_deflate`.
- Browser caching headers via `mod_expires`.
- Security headers such as `Referrer-Policy`, `X-Content-Type-Options`, and `X-Frame-Options`.

The configuration keeps Apache self-contained and avoids the need for custom rewrite logic outside the container.

## PHP / OPcache Tuning

The `php/opcache.ini` file enables and tunes OPcache for Nextcloud:

- `opcache.memory_consumption=256`
- `opcache.max_accelerated_files=20000`
- `opcache.interned_strings_buffer=16`
- `opcache.jit=tracing`
- `opcache.jit_buffer_size=128M`

This reduces repeated PHP compilation overhead and improves response times significantly on larger Nextcloud installations.

## Data Directories

All persistent data is stored on the host under the paths defined in `.env`:

| Path | Purpose |
|---|---|
| `./data/postgres/` | PostgreSQL data files |
| `./data/nextcloud-app/` | Nextcloud application files, apps, and runtime files |
| `./data/nextcloud-config/` | Nextcloud configuration files including `config.php` |
| `/srv/nextcloud-data/` | User files and primary Nextcloud data storage |

> **Backup:** Regularly back up both the PostgreSQL data directory and the Nextcloud data directory.
> The most critical data typically lives in `POSTGRES_DATA` and `NEXTCLOUD_DATA`.

## Reverse Proxy

The stack exposes HTTP on `HTTP_PORT` and expects SSL termination to happen in an upstream reverse proxy
such as Traefik, Nginx Proxy 

### Apache Reverse Proxy for `collabora CODE`

```
AllowEncodedSlashes On
ProxyPreserveHost On
ProxyRequests Off

# Browser assets
ProxyPass        /browser http://127.0.0.1:9980/browser retry=0
ProxyPassReverse /browser http://127.0.0.1:9980/browser

# Discovery / capabilities
ProxyPass        /hosting/discovery    http://127.0.0.1:9980/hosting/discovery retry=0
ProxyPassReverse /hosting/discovery    http://127.0.0.1:9980/hosting/discovery
ProxyPass        /hosting/capabilities http://127.0.0.1:9980/hosting/capabilities retry=0
ProxyPassReverse /hosting/capabilities http://127.0.0.1:9980/hosting/capabilities

# WebSocket
ProxyPassMatch   ^/cool/(.*)/ws$ ws://127.0.0.1:9980/cool/$1/ws nocanon

# Admin websocket
ProxyPass        /cool/adminws ws://127.0.0.1:9980/cool/adminws

# REST / download / upload
ProxyPass        /cool http://127.0.0.1:9980/cool
ProxyPassReverse /cool http://127.0.0.1:9980/cool
```
