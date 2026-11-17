#!/usr/bin/env bash
# Removes what ci/dind-test.sh brought up: the Ubuntu container, and its Docker daemon's volume.
set -euo pipefail

docker rm -f selan-ci-ubuntu >/dev/null 2>&1 || true
docker volume rm selan-ci-ubuntu-docker >/dev/null 2>&1 || true
