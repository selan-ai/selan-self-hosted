#!/usr/bin/env bash
# On a host booted by systemd (ci/dind-test.sh boots one): install.sh starts a stopped Docker with
# systemctl and installs selan-unseal.service; after a reboot Docker restarts the stack and the unit
# unseals OpenBao with nobody's hands. Run as `systemd.sh install`, then the box reboots, then `systemd.sh boot`.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

case "${1:-}" in
  install)
    install >/dev/null
    systemctl is-enabled selan-unseal.service >/dev/null || fail "selan-unseal.service is not enabled"
    systemctl stop docker.socket docker.service
    install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN >/dev/null
    systemctl is-active docker.service >/dev/null || fail "install.sh did not start the stopped Docker"
    pass "with systemd, install.sh enables selan-unseal.service and starts a stopped Docker with systemctl"
    ;;
  boot)
    for _ in $(seq 60); do docker info >/dev/null 2>&1 && break; sleep 2; done
    for _ in $(seq 60); do
      [ "$(systemctl show -p ActiveState --value selan-unseal.service)" != activating ] &&
        compose exec -T openbao bao status >/dev/null 2>&1 && break
      sleep 2
    done
    compose exec -T openbao bao status >/dev/null 2>&1 || fail "OpenBao is sealed after the reboot: $(journalctl -u selan-unseal --no-pager | tail -n 5)"
    # Docker starts the proxy beside a sealed selan-keys, and the proxy asks again only every five minutes.
    for name in keys mcp gw; do
      for _ in $(seq 80); do ready "$name" -k && break; sleep 5; done
      ready "$name" -k || fail "$name is not ready after the reboot"
    done
    pass "after a reboot selan-unseal.service unsealed OpenBao and every name is ready, with nobody's hands"
    ;;
  *) fail "usage: systemd.sh install|boot" ;;
esac
