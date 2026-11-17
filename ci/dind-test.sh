#!/usr/bin/env bash
# The stack test on a fresh Ubuntu with its own Docker daemon, as selan-proxy-e2e installs it: a privileged
# Ubuntu container with git alone, this commit cloned to /opt/selan, then ci/stack-test.sh inside it, whose
# install.sh installs Docker itself and answers every question from the environment.
# Leaves the container running for its logs; ci/stack-down.sh removes it.
set -euo pipefail

cd "$(dirname "$0")/.."
ubuntu=ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
box=selan-ci-ubuntu

docker rm -f "$box" >/dev/null 2>&1 || true
docker volume rm "$box-docker" >/dev/null 2>&1 || true
# /var/lib/docker on a volume: the inner daemon's overlay cannot sit on the outer one's.
docker run -d --privileged --name "$box" --hostname "$box" -v "$box-docker:/var/lib/docker" \
  -v "$PWD:/src:ro" "$ubuntu" sleep infinity >/dev/null
in_box() { docker exec -i "$box" bash -c "$1"; }
in_box 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates >/dev/null'
# Add server's line clones a tag; CI clones the commit under test, the same way.
in_box 'git config --global safe.directory /src/.git && git init -q /opt/selan && git -C /opt/selan fetch -q --depth 1 file:///src HEAD &&
  git -C /opt/selan -c advice.detachedHead=false checkout -q FETCH_HEAD'
in_box '! command -v docker' || {
  echo "FAIL: the Ubuntu image already has Docker; install.sh must be the one to install it" >&2
  exit 1
}
in_box 'cd /opt/selan && SELAN_NONINTERACTIVE=1 bash ci/stack-test.sh </dev/null'
