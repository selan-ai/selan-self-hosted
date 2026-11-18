#!/usr/bin/env bash
# The check from outside, against stand-ins for public DNS and check-host.net (ci/fake_outside.py):
# a public address that answers is refused with exit 2; closed, unknown and no public address are said.
# Also: install.sh at a release tag says the tag.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

git -c user.name=ci -c user.email=ci@example.invalid tag v0.0.0-ci
install | tee /tmp/install.log >/dev/null
grep -q 'Installing from /opt/selan at v0.0.0-ci' /tmp/install.log || fail "install.sh did not say the tag"
grep -q 'Skipped: SELAN_OUTSIDE_CHECK=no.' /tmp/install.log || fail "SELAN_OUTSIDE_CHECK=no did not skip"
pass "at a tag install.sh names it, and SELAN_OUTSIDE_CHECK=no skips the check"

docker run -d --name fake-outside -p 127.0.0.1:8099:8099 -v "$root/ci:/ci:ro" "$probe" python /ci/fake_outside.py >/dev/null
for _ in $(seq 20); do curl -s -o /dev/null http://127.0.0.1:8099/ && break; sleep 1; done
check=(-u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN SELAN_OUTSIDE_CHECK=yes)

refused 2 'WARNING: .*203.0.113.7:443.* answers from the internet' "${check[@]}" \
  SELAN_PUBLIC_DNS=http://127.0.0.1:8099/public SELAN_CHECK_HOST=http://127.0.0.1:8099/mixed
grep -q '203.0.113.8:443' /tmp/refused.log || fail "the server's own way out was not checked"
! grep -Eq '203.0.113.7:(80|8080|8200)' /tmp/refused.log || fail "a closed or unknown port was called exposed"
pass "a public address that answers is refused with exit 2, naming only the ports that answer"

install "${check[@]}" SELAN_PUBLIC_DNS=http://127.0.0.1:8099/public SELAN_CHECK_HOST=http://127.0.0.1:8099/closed >/tmp/install.log
grep -q 'From outside, nothing answers on 203.0.113.7 203.0.113.8 at ports 443, 80, 8080 or 8200.' /tmp/install.log ||
  fail "closed ports were not said: $(tail -n 3 /tmp/install.log)"
install "${check[@]}" SELAN_PUBLIC_DNS=http://127.0.0.1:8099/public SELAN_CHECK_HOST=http://127.0.0.1:8099/unknown >/tmp/install.log
grep -q 'Could not check .* from outside (check-host.net did not answer)' /tmp/install.log || fail "unknown ports were not said"
install "${check[@]}" SELAN_PUBLIC_DNS=http://127.0.0.1:8099/private SELAN_CHECK_HOST=http://127.0.0.1:8099/closed >/tmp/install.log
grep -q 'Not checked: neither public DNS nor this server' /tmp/install.log || fail "no public address was not said"
pass "closed ports, a checker that does not answer, and no public address are each said, with exit 0"
