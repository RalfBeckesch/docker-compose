# 🐳 docker-compose

Personal Docker Compose configurations for self-hosted services — production-ready, opinionated, and built for real infrastructure at customers and at my homelab (usually Proxmox -> Debian VMs).

---

## Structure

Each directory contains a self-contained Compose stack:

- `docker-compose.yaml` — service definitions
- `env-dist` — environment variable template (no real secrets ever committed)
- `README.md` — service-specific notes (where applicable)

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
- **`.env` files for all secrets** — no passwords in `docker-compose.yaml`, ever
- **Healthchecks** on all critical services with `condition: service_healthy`
- **`unless-stopped`** as the default restart policy
- **Alpine images** where available — smaller attack surface, faster pulls

---

## Usage

```bash
git clone https://github.com/RalfBeckesch/docker-compose.git
cd docker-compose/<service>
cp .env.example .env
# edit .env and fill in your values
chmod 600 .env
docker compose up -d
```

---

## Infrastructure

These configurations are designed to run on:

- **Hypervisor:** Proxmox VE
- **Guest OS:** Debian / Alpine Linux
- **Reverse proxy:** upstream proxy (Apache2 + Certbot / Traefik / Nginx Proxy Manager) handles SSL termination
- **Networking:** all services communicate over internal Docker networks; only the app port is exposed

---

## License

MIT — use freely, no warranties.
