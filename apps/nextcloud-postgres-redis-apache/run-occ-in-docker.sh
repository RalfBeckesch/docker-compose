#!/bin/bash
# =============================================================================
# Helper script to run occ commands inside the Nextcloud Docker container,
# for example to rescan all files or execute maintenance commands.
# =============================================================================
# Run this AFTER the stack is up and Nextcloud has been fully initialised:
# docker compose up -d
# # wait ~60 seconds until initialisation has completed
# bash run-occ-in-docker.sh <occ command>
#
# Example:
#   bash run-occ-in-docker.sh files:scan --all -v
# =============================================================================

PROGNAME=$(basename $0)

# Load environment variables from .env so INSTANCE_NAME is available.
. ./.env

# Abort if INSTANCE_NAME is missing, because it is required to build the
# Nextcloud app container name.
if [ -z "$INSTANCE_NAME" ]; then
	echo INSTANCE_NAME in .env is missing or empty. >&2
	exit 1
fi

NC_CONTAINER="${INSTANCE_NAME}-app"

# Show usage information if no occ parameters were passed.
if [ -z "$*" ];then
	echo -e "Run $PROGNAME followed by the parameters you want to pass to occ." >&2
	echo -e "\tExample:" >&2
	echo -e "\t\t$PROGNAME files:scan --all -v" >&2
	echo -e "\tThis will run:" >&2
	echo -e "\t\tdocker exec -u www-data \"$NC_CONTAINER\" php occ files:scan --all -v" >&2
	exit 1
fi

# Print the full command before executing it for transparency / debugging.
echo "⚙️ Running command: 'docker exec -u www-data \"$NC_CONTAINER\" php occ $*'"
docker exec -u www-data "$NC_CONTAINER" php occ $*
