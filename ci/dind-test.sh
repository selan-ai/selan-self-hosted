#!/usr/bin/env bash
# Runs one case of ci/cases/ on a fresh host with its own Docker daemon, as selan-proxy-e2e installs: a
# privileged container (Ubuntu 24.04; Ubuntu booted by systemd for `systemd`; Alpine for `no-debian`)
# with git alone, this commit cloned to /opt/selan, and the case inside it, where install.sh installs
# Docker itself and answers everything from the environment. The lines install.sh ran go to
# ci-out/paths-<case>.txt for ci/paths.py. Leaves the container for its logs; ci/stack-down.sh removes it.
#   bash ci/dind-test.sh <case>      cases: ls ci/cases
set -euo pipefail

cd "$(dirname "$0")/.."
case=${1:?usage: ci/dind-test.sh <case>, a file in ci/cases/ without .sh}
[ -f "ci/cases/$case.sh" ] || { echo "no case ci/cases/$case.sh" >&2; exit 1; }
ubuntu=ubuntu:24.04@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
alpine=alpine:3.22@sha256:49340b346798875b5592e5d420241f2f9cfba5f47e62ebb1446a1b34734e898f
box=selan-ci-$case
mkdir -p ci-out

in_box() { docker exec -i "$box" bash -c "$1"; }
# Only line numbers and command names leave the box: the trace also holds the fake tokens CI uses.
save_paths() {
  docker exec "$box" sh -c 'cat /var/tmp/paths.trace 2>/dev/null' |
    sed -n 's/^+\{1,\}\([0-9]\{1,\}\): \([^ ]*\).*/\1 \2/p' | sort -u >"ci-out/paths-$case.txt" || true
}
trap save_paths EXIT

docker rm -f "$box" >/dev/null 2>&1 || true
docker volume rm "$box-docker" "$box-containerd" >/dev/null 2>&1 || true
# Docker's and containerd's stores on volumes: the inner overlay mounts cannot sit on the outer one's.
run=(docker run -d --privileged --name "$box" --hostname "$box" -v "$box-docker:/var/lib/docker"
  -v "$box-containerd:/var/lib/containerd" -v "$PWD:/src:ro")
case "$case" in
  systemd)
    printf 'FROM %s\nRUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv git ca-certificates >/dev/null && apt-get clean\nSTOPSIGNAL SIGRTMIN+3\nCMD ["/sbin/init"]\n' "$ubuntu" |
      docker build -q -t selan-ci-systemd - >/dev/null
    "${run[@]}" --cgroupns=private selan-ci-systemd >/dev/null
    for _ in $(seq 30); do
      docker exec "$box" systemctl is-system-running 2>/dev/null | grep -Eq 'running|degraded' && break
      sleep 1
    done
    ;;
  no-debian)
    "${run[@]}" "$alpine" sleep infinity >/dev/null
    docker exec "$box" apk add -q bash git
    ;;
  *)
    "${run[@]}" "$ubuntu" sleep infinity >/dev/null
    in_box 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates >/dev/null'
    ;;
esac
# Add server's line clones a tag; CI clones the commit under test, the same way.
in_box 'git config --global safe.directory /src/.git && git init -q /opt/selan && git -C /opt/selan fetch -q --depth 1 file:///src HEAD &&
  git -C /opt/selan -c advice.detachedHead=false checkout -q FETCH_HEAD'
in_box '! command -v docker' || { echo "FAIL: the image already has Docker; install.sh must install it" >&2; exit 1; }
if [ "$case" = systemd ]; then
  in_box 'bash /opt/selan/ci/cases/systemd.sh install </dev/null'
  docker restart "$box" >/dev/null
  in_box 'bash /opt/selan/ci/cases/systemd.sh boot </dev/null'
else
  in_box "bash /opt/selan/ci/cases/$case.sh </dev/null"
fi
