#!/bin/sh
# The `unseal` service, beside OpenBao for as long as it runs: whenever OpenBao answers sealed (after a crash,
# a restart of its container, an upgrade's `compose up`, or a reboot), it unseals it with the key install.sh
# keeps root-only in openbao-unseal.key. Otherwise it only waits. README, "The vault".
set -u
key=/run/selan/openbao-unseal.key
while :; do
  bao status >/dev/null 2>&1
  case $? in
    0) sleep 5 ;;
    2)
      if bao write -field=sealed sys/unseal key=- <"$key" | grep -qx false; then
        echo "OpenBao was sealed; unsealed it."
      else
        echo "OpenBao is sealed and the key in openbao-unseal.key did not unseal it." >&2
        sleep 30
      fi
      ;;
    *) sleep 2 ;;
  esac
done
