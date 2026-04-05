#!/bin/bash
# =============================================================================
# Post-Install: Configure Nextcloud after first startup
# =============================================================================
# Run this AFTER the stack is running and Nextcloud has been fully initialized:
# docker compose up -d
# # wait ~60 seconds until initialization has completed
# bash post-install.sh

set -euo pipefail

. ./.env

if [ -z "$INSTANCE_NAME" ]; then
	echo INSTANCE_NAME in .env is missing or empty. >&2
	exit 1
fi

NC_CONTAINER="${INSTANCE_NAME}-app"

echo "⚙️ Configuring Redis cache..."
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"

echo "⚙️ Enabling Imaginary preview service..."
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set preview_imaginary_url --value="http://imaginary:9000"
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set enabledPreviewProviders 0 --value="OC\\Preview\\Imaginary"
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set enabledPreviewProviders 1 --value="OC\\Preview\\ImaginaryPDF"
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set enabledPreviewProviders 2 --value="OC\\Preview\\OpenDocument"
docker exec -u www-data "$NC_CONTAINER" php occ config:system:set enabledPreviewProviders 3 --value="OC\\Preview\\Movie"

echo "⚙️ Switching background jobs to cron..."
docker exec -u www-data "$NC_CONTAINER" php occ background:cron

echo "⚙️ Adding missing database indices..."
docker exec -u www-data "$NC_CONTAINER" php occ db:add-missing-indices

echo "⚙️ Converting database columns (bigint)..."
docker exec -u www-data "$NC_CONTAINER" php occ db:convert-filecache-bigint --no-interaction

echo "✅ Post-install completed! Nextcloud is ready."
echo ""
echo "Admin panel: http://localhost:${HTTP_PORT:-8080}"
echo "Status: docker exec -u www-data $NC_CONTAINER php occ status"
