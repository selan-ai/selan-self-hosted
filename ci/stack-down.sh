#!/usr/bin/env bash
# Removes what ci/stack-test.sh brought up, volumes included, and the files install.sh wrote.
set -euo pipefail

cd "$(dirname "$0")/.."
export SELAN_PROXY_IMAGE=unused SELAN_GATEWAY_IMAGE=unused SELAN_BIND_ADDR=127.0.0.1
export SELAN_PROXY_HOST=gw.selan-ci.test SELAN_GATEWAY_HOST=mcp.selan-ci.test
export COMPOSE_FILE="$PWD/compose.yaml:$PWD/ci/compose.ci.yaml"
docker compose --project-directory "$PWD" --profile openbao down -v --remove-orphans
rm -f .env openbao-init.json
