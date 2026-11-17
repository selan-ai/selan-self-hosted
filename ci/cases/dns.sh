#!/usr/bin/env bash
# SELAN_TLS=dns: Let's Encrypt over DNS-01 through the provider's API. CI has no zone of its own, so the
# provider refuses the token; the case proves the rest: the provider and token reach Caddy, Caddy has a way
# out and tries a DNS-01 challenge with that provider, the token stays out of output and Caddy's saved
# config, and install.sh fails plainly when the certificate does not come.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

# Let's Encrypt refuses a name without a public suffix before any challenge, so these names are
# under selan.ai, where the hetzner API refuses CI's token: no record is ever written.
dns=(SELAN_TLS=dns SELAN_DNS_PROVIDER=hetzner SELAN_PROXY_HOST=gw.ci-dns.selan.ai)
refused 1 "SELAN_DNS_PROVIDER 'nowhere' is not one of" SELAN_TLS=dns SELAN_DNS_PROVIDER=nowhere
refused 1 'SELAN_DNS_TOKEN is not set' "${dns[@]}" -u SELAN_DNS_TOKEN
refused 1 'SELAN_DNS_TOKEN is empty or has characters' "${dns[@]}" "SELAN_DNS_TOKEN=two words"
pass "SELAN_TLS=dns refuses an unknown provider and a missing or malformed token"

if [ -n "$caddy_image" ]; then
  # Stock Caddy has no DNS modules: ci/dind-test.sh built caddy/Dockerfile and copied it in.
  docker load -i /tmp/selan-caddy.tar >/dev/null
  export SELAN_CADDY_IMAGE=selan-caddy:ci SELAN_UNSIGNED_OK="$stand_in selan-caddy:ci"
fi
export COMPOSE_FILE="$root/compose.yaml:$root/compose.dns.yaml:$root/ci/compose.ci.yaml"
token=ci-dns-token-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
refused 1 'readyz did not answer within 30 seconds' "${dns[@]}" SELAN_DNS_TOKEN="$token" SELAN_READY_TIMEOUT=30
grep -qx "SELAN_DNS_PROVIDER='hetzner'" .env || fail ".env does not name the provider"
grep -qx "COMPOSE_FILE='$root/compose.yaml:$root/compose.dns.yaml'" .env || fail ".env does not add compose.dns.yaml"
docker inspect -f '{{json .NetworkSettings.Networks}}' selan-caddy-1 | grep -q selan_egress || fail "Caddy has no way out"
for _ in $(seq 30); do
  compose logs caddy 2>&1 | grep -q 'dns-01' && break
  sleep 2
done
compose logs caddy 2>&1 | grep -q 'dns-01' || fail "Caddy did not try a DNS-01 challenge: $(compose logs --tail 20 caddy)"
compose logs caddy 2>&1 | grep -q 'presenting for challenge: adding temporary record' ||
  fail "Caddy did not ask the provider's API for the challenge record"
! grep -q "$token" /tmp/refused.log || fail "the DNS token is in install.sh's output"
! compose logs caddy 2>&1 | grep -q "$token" || fail "the DNS token is in Caddy's log"
! compose exec -T caddy sh -c 'cat /config/caddy/autosave.json' | grep -q "$token" || fail "the DNS token is in Caddy's saved config"
[ "$(mode .env)" = "root 600" ] || fail ".env holding the DNS token is $(mode .env)"
pass "DNS-01: Caddy, with a way out, asks the provider's API for the challenge record; the token stays in .env and Caddy's environment only"
