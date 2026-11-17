#!/usr/bin/env bash
# Brings the stack up the way a server does, through install.sh, with OpenBao, stand-ins for the
# proxy and gateway and a fake control, then checks it is ready and the vault is walled in.
# Needs root and Docker; leaves the stack running for `docker compose logs` (ci/stack-down.sh removes it).
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
pass() { printf 'ok: %s\n' "$*"; }

stand_in=python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
curl_image=curlimages/curl@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
export SELAN_PROXY_IMAGE=$stand_in SELAN_GATEWAY_IMAGE=$stand_in
export COMPOSE_FILE="$root/compose.yaml:$root/ci/compose.ci.yaml"
export SELAN_REGISTRATION_TOKEN=selanreg_ci-stack-test
export SELAN_PROXY_HOST=gw.selan-ci.test SELAN_BIND_ADDR=127.0.0.1
export CONTROL_BASE_URL=http://fake-control:8080 SELAN_OUTSIDE_CHECK=no

compose() { docker compose --project-directory "$root" "$@"; }
mode() { stat -c '%U %a' "$1"; }
ip_on() { docker inspect -f "{{(index .NetworkSettings.Networks \"selan_$2\").IPAddress}}" "selan-$1-1"; }
reaches() { # reaches <container> <host> <port>: a TCP connect from inside a container
  compose exec -T "$1" python -c "import socket; socket.create_connection(('$2', $3), timeout=4)" >/dev/null 2>&1
}

./install.sh
pass "install.sh finished"

[ "$(mode .env)" = "root 600" ] || fail ".env is $(mode .env), not root 600"
[ "$(mode openbao-init.json)" = "root 600" ] || fail "openbao-init.json is $(mode openbao-init.json), not root 600"
! grep -q selanreg_ .env || fail "the registration token is still in .env after registering"
pass ".env and openbao-init.json are root 0600, and the used token left .env"

for host in gw mcp; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host.selan-ci.test:443:127.0.0.1" "https://$host.selan-ci.test/readyz")
  [ "$code" = 200 ] || fail "https://$host.selan-ci.test/readyz answered $code"
done
pass "/readyz answers 200 through Caddy for the proxy and the gateway"
[ "$(compose logs fake-control | grep -c 'accepted')" -ge 2 ] || fail "control did not see both registrations"
pass "the proxy and the gateway registered with control using the token"

[ -z "$(docker port selan-openbao-1)" ] || fail "openbao publishes a port: $(docker port selan-openbao-1)"
vault_ip=$(ip_on openbao inside)
curl -s --max-time 4 "http://$vault_ip:8200/v1/sys/health" >/dev/null && fail "the host reaches the vault at $vault_ip"
for net in egress front bridge; do
  attach=$net
  [ "$net" = bridge ] || attach=selan_$net
  docker run --rm --network "$attach" "$curl_image" -s --max-time 4 "http://$vault_ip:8200/v1/sys/health" >/dev/null 2>&1 &&
    fail "a container on $net reaches the vault at $vault_ip"
  docker run --rm --network "$attach" "$curl_image" -s --max-time 4 "http://openbao:8200/v1/sys/health" >/dev/null 2>&1 &&
    fail "a container on $net reaches the vault by name"
done
pass "the vault publishes no port and answers nothing from the host, egress, front or the default bridge"
reaches proxy openbao 8200 || fail "the proxy does not reach the vault on inside"
pass "the proxy reaches the vault on inside"

compose exec -T openbao wget -q -T 4 -O /dev/null http://1.1.1.1 >/dev/null 2>&1 && fail "the vault reaches the internet"
compose exec -T caddy wget -q -T 4 -O /dev/null http://1.1.1.1 >/dev/null 2>&1 && fail "caddy reaches the internet"
reaches proxy 1.1.1.1 443 || fail "the proxy cannot reach the internet"
pass "only the proxy and gateway have a way out; the vault and Caddy have none"

code=$(docker run --rm --network selan_front -e "C=$(ip_on caddy front)" --entrypoint sh "$curl_image" -c \
  'curl -sk -o /dev/null -w "%{http_code}" --resolve gw.selan-ci.test:443:$C https://gw.selan-ci.test/readyz')
[ "$code" = 200 ] || fail "a private address was refused by Caddy ($code)"

before=$(sha256sum openbao-init.json .env)
env -u SELAN_REGISTRATION_TOKEN ./install.sh >/dev/null
[ "$before" = "$(sha256sum openbao-init.json .env)" ] || fail "a second run changed openbao-init.json or .env"
pass "a second run of install.sh, without the used token, changes nothing and is ready again"

compose restart openbao >/dev/null 2>&1
compose exec -T openbao bao status >/dev/null 2>&1 && fail "OpenBao came back unsealed by itself"
./unseal.sh
compose restart proxy gateway >/dev/null 2>&1
for _ in $(seq 30); do
  curl -sfk -o /dev/null --resolve gw.selan-ci.test:443:127.0.0.1 https://gw.selan-ci.test/readyz && break
  sleep 2
done
curl -sfk -o /dev/null --resolve gw.selan-ci.test:443:127.0.0.1 https://gw.selan-ci.test/readyz || fail "not ready after a restart and unseal"
pass "after a restart OpenBao is sealed, unseal.sh opens it and the proxy is ready again"
