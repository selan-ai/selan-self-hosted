#!/usr/bin/env bash
# Removes what ci/dind-test.sh brought up: every case's container, and its Docker daemon's volume.
set -euo pipefail

for box in $(docker ps -aq --filter name=^selan-ci-); do
  name=$(docker inspect -f '{{.Name}}' "$box")
  docker rm -f "$box" >/dev/null
  docker volume rm "${name#/}-docker" "${name#/}-containerd" >/dev/null 2>&1 || true
done
