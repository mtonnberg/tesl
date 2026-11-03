#!/bin/sh
# Drained, latest-image rollout for a versioned Worker-topology application.
set -eu
if [ "$#" -ne 1 ]; then
  printf '%s\n' 'usage: sh deploy-worker.sh COMPOSE_FILE' >&2
  exit 2
fi
compose_file=$1
docker compose -f "$compose_file" config --quiet
docker compose -f "$compose_file" pull
docker compose -f "$compose_file" stop app schema-worker
docker compose -f "$compose_file" up --force-recreate --abort-on-container-exit --exit-code-from schema-deploy schema-deploy
# The migration exit status gates this point. Avoid rerunning the completed job
# while replacing the services with the same immutable image.
docker compose -f "$compose_file" up -d --no-deps --force-recreate schema-worker app
