#!/usr/bin/env bash
# Prints the Caddy image CI should run: nothing while compose.yaml pins a release (compose names it),
# else a local build of caddy/Dockerfile, until the first build is published and pinned.
set -euo pipefail

cd "$(dirname "$0")/.."
if ! grep -qF "image: \${SELAN_CADDY_IMAGE:?" compose.yaml; then
  exit 0
fi
docker build -q -t selan-caddy:ci caddy >/dev/null
echo selan-caddy:ci
