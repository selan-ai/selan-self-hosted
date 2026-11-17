#!/usr/bin/env bash
# Registration tokens missing, malformed, then present; the per-caller selan-keys tokens made once, kept,
# and refused when .env holds a broken one.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

refused 1 'SELAN_REGISTRATION_TOKEN is not set: copy the line from Settings' -u SELAN_REGISTRATION_TOKEN
refused 1 'SELAN_KEYS_REGISTRATION_TOKEN is not set: copy the line from Settings' -u SELAN_KEYS_REGISTRATION_TOKEN
refused 1 'SELAN_REGISTRATION_TOKEN does not look like selanreg_' SELAN_REGISTRATION_TOKEN=reg_wrong
refused 1 'SELAN_KEYS_REGISTRATION_TOKEN does not look like selanreg_' SELAN_KEYS_REGISTRATION_TOKEN='selanreg_has space'
[ ! -e .env ] || fail "a refused first run wrote .env"
pass "a first run without, or with a malformed, registration token is refused before anything is written"

install >/dev/null
[ "$(control_log | grep -c 'accepted')" = 3 ] || fail "not three registrations"
! grep -q selanreg_ .env || fail "a used registration token is still in .env"
callers=$(grep -E '^(PROXY|GATEWAY)_KEYS_TOKEN=' .env)
pass "with both tokens the server registers, and the used tokens leave .env"

install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN >/dev/null
[ "$callers" = "$(grep -E '^(PROXY|GATEWAY)_KEYS_TOKEN=' .env)" ] || fail "a re-run made new caller tokens"
pass "a re-run without tokens keeps the caller tokens"

cp .env /tmp/env
sed -i "s/^PROXY_KEYS_TOKEN=.*/PROXY_KEYS_TOKEN='short'/" .env
refused 1 'PROXY_KEYS_TOKEN in .* is not 64 hex characters' -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN
cp /tmp/env .env
pass "a broken caller token in .env is refused, naming it"
