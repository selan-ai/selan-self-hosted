#!/usr/bin/env bash
# Brings the stack up the way a server does, through install.sh, with OpenBao (its cosign signature
# checked), stand-ins for the proxy and gateway and a fake control, then checks it is ready, registered
# with both public keys, and that the vault is walled in.
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
caddy_image=$(ci/caddy-image.sh)
[ -z "$caddy_image" ] || export SELAN_CADDY_IMAGE=$caddy_image
export SELAN_PROXY_IMAGE=$stand_in SELAN_GATEWAY_IMAGE=$stand_in
# The stand-ins, and a Caddy built here before the first one is published, are not signed: everything else is checked.
export SELAN_UNSIGNED_OK="$stand_in $caddy_image"
export COMPOSE_FILE="$root/compose.yaml:$root/ci/compose.ci.yaml"
export SELAN_REGISTRATION_TOKEN=selanreg_ci-stack-test
export SELAN_PROXY_HOST=gw.selan-ci.test SELAN_BIND_ADDR=127.0.0.1 SELAN_TLS=internal
export CONTROL_BASE_URL=http://fake-control:8080 SELAN_OUTSIDE_CHECK=no

compose() { docker compose --project-directory "$root" "$@"; }
mode() { stat -c '%U %a' "$1"; }
ip_on() { docker inspect -f "{{(index .NetworkSettings.Networks \"selan_$2\").IPAddress}}" "selan-$1-1"; }
reaches() { # reaches <container> <host> <port>: a TCP connect from inside a container
  compose exec -T "$1" python -c "import socket; socket.create_connection(('$2', $3), timeout=4)" >/dev/null 2>&1
}

./install.sh | tee /tmp/install.log
grep -q '^signed:  quay.io/openbao/openbao' /tmp/install.log || fail "install.sh did not check OpenBao's signature"
pass "install.sh finished, OpenBao's cosign signature checked"

[ "$(mode .env)" = "root 600" ] || fail ".env is $(mode .env), not root 600"
[ "$(mode openbao-init.json)" = "root 600" ] || fail "openbao-init.json is $(mode openbao-init.json), not root 600"
! grep -q selanreg_ .env || fail "the registration token is still in .env after registering"
pass ".env and openbao-init.json are root 0600, and the used token left .env"

for host in gw mcp; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host.selan-ci.test:443:127.0.0.1" "https://$host.selan-ci.test/readyz")
  [ "$code" = 200 ] || fail "https://$host.selan-ci.test/readyz answered $code"
done
pass "/readyz answers 200 through Caddy for the proxy and the gateway"
control_log() { compose logs --no-log-prefix fake-control; }
[ "$(control_log | grep -c 'accepted')" = 2 ] || fail "control did not see exactly two registrations: $(control_log)"
! control_log | grep -q refused || fail "control refused a registration: $(control_log)"
for component in proxy gateway; do
  for key in signing sealing; do
    [ "$(compose exec -T "$component" stat -c '%a' "/var/lib/selan-$component/$key.key")" = 600 ] ||
      fail "the $component's $key private key is not mode 600"
  done
  public=$(compose exec -T "$component" python -c "
import base64, sys; sys.path.insert(0, '/ci'); from keys import ed25519_public, x25519_public
read = lambda name: open('/var/lib/selan-$component/' + name, 'rb').read()
print(base64.b64encode(ed25519_public(read('signing.key'))).decode(), base64.b64encode(x25519_public(read('sealing.key'))).decode())")
  read -r signing sealing <<<"$public"
  control_log | grep -q "OWN_SERVERS_COMPONENT_${component^^} at https://.*: accepted, signing $signing sealing $sealing" ||
    fail "the $component did not register the public halves of its own Ed25519 and X25519 keys"
done
pass "the proxy and the gateway called RegisterServer once each, with the token and the public halves of both key pairs, whose private halves stay at 0600"

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
[ "$(control_log | grep -c 'RegisterServer')" = 2 ] || fail "a restart registered again instead of keeping its identity"
pass "after a restart OpenBao is sealed, unseal.sh opens it, the proxy is ready again and did not register again"

cp signers.txt /tmp/signers.txt
sed -i 's#github\\.com/openbao/openbao/#github\\.com/someone-else/openbao/#' signers.txt
status=0
env -u SELAN_REGISTRATION_TOKEN ./install.sh >/tmp/install.log 2>&1 || status=$?
cp /tmp/signers.txt signers.txt
if [ "$status" = 0 ] || ! grep -q 'openbao.* is not signed by' /tmp/install.log; then
  fail "install.sh did not refuse an image signed by somebody else: $(tail -n 5 /tmp/install.log)"
fi
pass "install.sh refuses an image whose signature names another signer than signers.txt"
