#!/usr/bin/env bash
# /usr/local/bin/selan-keys, as install.sh installs it: selan-keys, run inside its container from any directory.
# `sudo selan-keys import` moves the keys Selan already holds into your vault, printing each as it is stored.
set -euo pipefail

keys=(docker compose --project-directory /opt/selan exec)
# compose gives the command a terminal unless told -T, and fails to when stdin is not one (a pipe, a script).
[ -t 0 ] || keys+=(-T)
exec "${keys[@]}" keys selan-keys "$@"
