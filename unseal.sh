#!/usr/bin/env bash
# Unseals the OpenBao this stack runs, with the key install.sh wrote to openbao-init.json.
# OpenBao starts sealed after every restart; the `unseal` service unseals it, and install.sh and a person run this.
set -euo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
init="$dir/openbao-init.json"
# The container by its name, not through compose: at boot nothing else of the stack's settings is needed.
bao() { docker exec -i selan-openbao-1 bao "$@"; }

[ "$(id -u)" = 0 ] || { echo "error: run as root" >&2; exit 1; }
[ -f "$init" ] || { echo "error: $init is missing; OpenBao cannot be unsealed without it" >&2; exit 1; }

# 0 unsealed, 2 sealed, anything else not answering yet (just started, or Docker still coming up).
for _ in $(seq 60); do
  status=0
  bao status >/dev/null 2>&1 || status=$?
  [ "$status" = 0 ] && exit 0
  [ "$status" = 2 ] && break
  sleep 2
done
[ "$status" = 2 ] || { echo "error: OpenBao is not answering; docker compose logs openbao" >&2; exit 1; }

key=$(grep -A1 '"unseal_keys_b64"' "$init" | tail -n 1 | tr -d ' ",')
[[ "$key" =~ ^[A-Za-z0-9+/=]+$ ]] || { echo "error: no unseal key in $init" >&2; exit 1; }
sealed=$(bao write -field=sealed sys/unseal key=- <<<"$key")
[ "$sealed" = false ] || { echo "error: OpenBao is still sealed" >&2; exit 1; }
echo "OpenBao is unsealed."
