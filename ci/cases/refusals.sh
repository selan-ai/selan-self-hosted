#!/usr/bin/env bash
# Every setting install.sh refuses, each naming its variable; the questions it asks on a terminal, answered
# there; a release with no codename in /etc/os-release; a VPN address found on its own; a run as non-root,
# from outside a checkout and from a checkout elsewhere than /opt/selan; unpinned and unknown images; and
# an OpenBao that does not start; a kernel without nf_tables; a Docker that will not start.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

# Before Docker is installed: a Debian-like release that names no codename.
cp /etc/os-release /tmp/os-release
printf 'ID=pop\nID_LIKE="ubuntu debian"\nNAME="Pop!_OS"\n' >/etc/os-release
refused 1 "cannot tell this release's codename" -u SELAN_PROXY_HOST
cp /tmp/os-release /etc/os-release
pass "a Debian-like release without a codename is refused before Docker is installed"

refused 1 'SELAN_PROXY_HOST is not set \(.*\); export it and run again' -u SELAN_PROXY_HOST
refused 1 "SELAN_PROXY_HOST 'gw_bad' is not a host name" SELAN_PROXY_HOST=gw_bad
refused 1 "SELAN_GATEWAY_HOST 'mcp_bad' is not a host name" SELAN_GATEWAY_HOST=mcp_bad
refused 1 "SELAN_KEYS_HOST 'keys_bad' is not a host name" SELAN_KEYS_HOST=keys_bad
refused 1 'SELAN_BIND_ADDR is not set' -u SELAN_BIND_ADDR
refused 1 "SELAN_BIND_ADDR '8.8.8.8' is not a private IPv4 address" SELAN_BIND_ADDR=8.8.8.8
refused 1 "SELAN_BIND_ADDR '172.32.0.1' is not a private" SELAN_BIND_ADDR=172.32.0.1
refused 1 'SELAN_TLS is not set' -u SELAN_TLS
refused 1 "SELAN_TLS is dns or files .*, not 'acme'" SELAN_TLS=acme
refused 1 'ALLOWED_CIDRS is private_ranges or' 'ALLOWED_CIDRS=10.0.0.0/8;rm'
refused 1 "'ftp://control' is not a base URL" CONTROL_BASE_URL=ftp://control
refused 1 'SELAN_VAULT is not set' -u SELAN_VAULT
refused 1 "SELAN_VAULT is openbao or own, not 'aws'" SELAN_VAULT=aws
refused 1 'VAULT_PREFIX is a path ending in /' VAULT_PREFIX=kv/selan
pass "each malformed or missing setting is refused, naming its variable"

own=(SELAN_VAULT=own VAULT_ADDR=http://127.0.0.1:1 KEYS_VAULT_ROLE_ID=role KEYS_VAULT_SECRET_ID=secret)
# The proxy's image swapped for one install.sh must refuse (ci/compose.image.yaml), so nothing starts.
swap="COMPOSE_FILE=$COMPOSE_FILE:$root/ci/compose.image.yaml"
unpinned=("$swap" CI_PROXY_IMAGE=python:3.13-alpine)
refused 1 'python:3.13-alpine is not pinned by digest' "${own[@]}" "${unpinned[@]}"
refused 1 'signers.txt names nobody who signs docker.io/library/python' "${own[@]}" "$swap" \
  CI_PROXY_IMAGE=docker.io/library/python@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
pass "an image that is not pinned, or that signers.txt names no signer for, is refused before anything runs"

apt-get install -y -qq iproute2 >/dev/null
ip link add wg0 type veth peer name wg0-peer
ip addr add 100.64.0.9/32 dev wg0
rm -f .env
refused 1 'is not pinned by digest' -u SELAN_BIND_ADDR "${own[@]}" "${unpinned[@]}"
grep -q 'listens  100.64.0.9:443' /tmp/refused.log || fail "the address on wg0 was not found"
ip link del wg0
pass "without SELAN_BIND_ADDR the address on a VPN interface (wg0) is used"

chmod 666 /var/tmp/paths.trace
status=0
su nobody -s /bin/bash -c "cd $root && bash ci/traced-install.sh" >/tmp/refused.log 2>&1 || status=$?
if [ "$status" != 1 ] || ! grep -q 'run as root' /tmp/refused.log; then fail "a run as nobody was not refused: $(cat /tmp/refused.log)"; fi
mkdir -p /tmp/lone && cp install.sh /tmp/lone/
status=0
bash ci/traced-install.sh /tmp/lone/install.sh >/tmp/refused.log 2>&1 || status=$?
if [ "$status" != 1 ] || ! grep -q 'run install.sh from a clone of' /tmp/refused.log; then fail "a lone install.sh was not refused"; fi
cp -a "$root" /srv/selan
status=0
(cd /srv/selan && env SELAN_PROXY_HOST=gw_bad bash ci/traced-install.sh) >/tmp/refused.log 2>&1 || status=$?
grep -q 'Installing from /srv/selan' /tmp/refused.log || fail "a checkout elsewhere did not run"
pass "install.sh refuses non-root and a copy outside a checkout, and runs from a checkout elsewhere without taking it over"

# The questions, on a terminal: every answer typed, two of them unseen.
asked() { # asked <answers> [env ...]: install.sh on a pseudo-terminal, each answer typed after its question
  local answers=$1
  shift
  rm -f .env
  printf '%b' "$answers" | while IFS= read -r answer; do sleep 2; printf '%s\n' "$answer"; done |
    env -u SELAN_NONINTERACTIVE "$@" script -qefc "bash $root/ci/traced-install.sh" /tmp/asked.log >/dev/null 2>&1 || true
}
asked 'gw.asked.test\n10.9.8.7\ndns\nhetzner\nasked-dns-token\nown\nhttp://127.0.0.1:1\nasked-role\nasked-secret\n' \
  -u SELAN_PROXY_HOST -u SELAN_BIND_ADDR -u SELAN_TLS -u SELAN_VAULT "${unpinned[@]}"
for line in "SELAN_PROXY_HOST='gw.asked.test'" "SELAN_BIND_ADDR='10.9.8.7'" "SELAN_TLS='dns'" "SELAN_DNS_PROVIDER='hetzner'" \
  "SELAN_DNS_TOKEN='asked-dns-token'" "SELAN_VAULT='own'" "VAULT_ADDR='http://127.0.0.1:1'" \
  "KEYS_VAULT_ROLE_ID='asked-role'" "KEYS_VAULT_SECRET_ID='asked-secret'"; do
  grep -qx "$line" .env || fail "the answer $line did not reach .env: $(tail -n 5 /tmp/asked.log)"
done
! grep -q 'asked-dns-token\|asked-secret' /tmp/asked.log || fail "a secret answer was shown on the terminal"
mkdir -p /tmp/pem && printf -- '-----BEGIN CERTIFICATE-----\n' >/tmp/pem/c.pem && printf -- '-----BEGIN PRIVATE KEY-----\n' >/tmp/pem/k.pem
rm -f certs/*.pem
asked '/tmp/pem/c.pem\n/tmp/pem/k.pem\n' SELAN_TLS=files "${own[@]}" "${unpinned[@]}"
if ! cmp -s /tmp/pem/c.pem certs/fullchain.pem || ! cmp -s /tmp/pem/k.pem certs/privkey.pem; then
  fail "the asked certificate paths were not copied in"
fi
asked '\n\n' -u KEYS_VAULT_ROLE_ID -u KEYS_VAULT_SECRET_ID SELAN_VAULT=own VAULT_ADDR=http://127.0.0.1:1
grep -q 'SELAN_VAULT=own needs KEYS_VAULT_ROLE_ID and KEYS_VAULT_SECRET_ID' /tmp/asked.log || fail "empty AppRole answers were not refused"
rm -f certs/*.pem .env
pass "on a terminal every question is asked and its answer kept, tokens and secret ids unseen, empty AppRole answers refused"

echo 'this is not hcl {' >>openbao.hcl
refused 1 'OpenBao is not answering' SELAN_READY_TIMEOUT=10
git checkout -q -- openbao.hcl
pass "an OpenBao that does not start is reported, with where to read its log"

service docker stop >/dev/null 2>&1 || true
mv /usr/bin/dockerd /usr/bin/dockerd.away
# A kernel without nf_tables but with legacy iptables, as on some hosts with their own Docker daemon:
# stand-ins for both binaries say so, whatever this runner's kernel has.
nft=$(readlink -f /usr/sbin/iptables-nft)
legacy=$(readlink -f /usr/sbin/iptables-legacy)
update-alternatives --set iptables /usr/sbin/iptables-nft >/dev/null
mv "$nft" "$nft.real" && printf '#!/bin/sh\nexit 1\n' >"$nft" && chmod +x "$nft"
mv "$legacy" "$legacy.real" && printf '#!/bin/sh\nexit 0\n' >"$legacy" && chmod +x "$legacy"
refused 1 'Docker is installed but not running'
switched=$(readlink /etc/alternatives/iptables)
mv "$nft.real" "$nft" && mv "$legacy.real" "$legacy"
[ "$switched" = /usr/sbin/iptables-legacy ] || fail "without nf_tables install.sh did not switch to iptables-legacy ($switched)"
mv /usr/bin/dockerd.away /usr/bin/dockerd
pass "without nf_tables install.sh switches to iptables-legacy, and a Docker that will not start is reported"
