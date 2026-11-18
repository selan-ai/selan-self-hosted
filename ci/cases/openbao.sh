#!/usr/bin/env bash
# OpenBao on this server, registration tokens present, TLS from Caddy's own CA: install.sh brings the stack
# up (checking OpenBao's cosign signature), it registers, only selan-keys reaches the vault, a re-run
# changes nothing, OpenBao restarted is unsealed by the unseal service with nobody's hands (and, with that
# service stopped, by unseal.sh and by a re-run), and a wrong signer is refused.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

install | tee /tmp/install.log
grep -q '^signed:  quay.io/openbao/openbao' /tmp/install.log || fail "install.sh did not check OpenBao's signature"
pass "install.sh finished, OpenBao's cosign signature checked"

[ "$(mode .env)" = "root 600" ] || fail ".env is $(mode .env), not root 600"
[ "$(mode openbao-init.json)" = "root 600" ] || fail "openbao-init.json is $(mode openbao-init.json), not root 600"
[ "$(mode openbao-unseal.key)" = "root 600" ] || fail "openbao-unseal.key is $(mode openbao-unseal.key), not root 600"
! grep -q selanreg_ .env || fail "a registration token is still in .env after registering"
[ "$(grep -cE "^(PROXY|GATEWAY)_KEYS_TOKEN='[0-9a-f]{64}'$" .env)" = 2 ] || fail ".env has no caller token for the proxy and the gateway each"
pass ".env and openbao-init.json are root 0600, the used tokens left .env, and each caller has its own selan-keys token"

[[ ",$(saved LAUNCH_CONNECTORS)," == *,https://mcp.selan-ci.test/selan/mcp,* ]] ||
  fail ".env's LAUNCH_CONNECTORS does not admit Selan's own MCP on this gateway: $(saved LAUNCH_CONNECTORS)"
given=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' selan-proxy-1 | sed -n 's/^LAUNCH_CONNECTORS=//p')
[ "$given" = "$(saved LAUNCH_CONNECTORS)" ] || fail "the proxy was given LAUNCH_CONNECTORS '$given', not .env's"
pass "the proxy's launch allowlist admits the connectors on this server's own gateway by default"

for host in gw mcp keys; do
  code=$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host.selan-ci.test:443:127.0.0.1" "https://$host.selan-ci.test/readyz")
  [ "$code" = 200 ] || fail "https://$host.selan-ci.test/readyz answered $code"
done
pass "/readyz answers 200 through Caddy for the proxy, the gateway and selan-keys"
[ "$(control_log | grep -c 'accepted')" = 3 ] || fail "control did not see exactly three registrations: $(control_log)"
! grep -q refused <<<"$(control_log)" || fail "control refused a registration: $(control_log)"
for component in proxy gateway keys; do
  grep -q "RegisterServer from OWN_SERVERS_COMPONENT_${component^^} at https://.*selan-ci.test: accepted, signing " <<<"$(control_log)" ||
    fail "the $component did not register at its https address with its public key"
  loose=$(docker run --rm -v "selan_$component-identity:/d:ro" "$probe" find /d -type f ! -perm 600 ! -user 65532)
  held=$(docker run --rm -v "selan_$component-identity:/d:ro" "$probe" find /d -type f -size +0)
  [ -z "$loose" ] && [ -n "$held" ] || fail "the $component's identity volume holds no key, or one not 0600 and its own: $loose"
done
grep -q 'OWN_SERVERS_COMPONENT_KEYS at https://.*: accepted, signing .* sealing ' <<<"$(control_log)" ||
  fail "selan-keys did not register its sealing key"
for component in PROXY GATEWAY KEYS; do
  grep -q "Poll from OWN_SERVERS_COMPONENT_$component, signed" <<<"$(control_log)" || fail "the ${component,,} never polled control, signed"
done
pass "the proxy, the gateway and selan-keys registered once each with their tokens, keep their keys at 0600 in their own volumes, and poll control signed"
grep -q 'ResolveSession, signed: no session' <<<"$(control_log)" || fail "the gateway's boot probe did not ask control, signed"
! grep -q '^selan-auth ' <<<"$(control_log)" || fail "a component asked selan-auth, which takes no server's token: $(control_log)"
pass "the gateway looks sessions up through control, signed, and never asks selan-auth"

bao_root=$(sed -n 's/^ *"root_token": *"\([^"]*\)".*/\1/p' openbao-init.json)
# shellcheck disable=SC2016 # BAO_TOKEN is read inside the container, from stdin.
printf '%s' "$bao_root" | compose exec -T openbao sh -c 'BAO_TOKEN=$(cat) bao kv put kv/selan/ci-key value=not-a-key provider=openrouter' >/dev/null
answer=$(key_read "$(saved PROXY_KEYS_TOKEN)" ci-key)
[[ "$answer" == *'"value":"not-a-key"'*' 200' ]] || fail "the proxy's token did not read a key through selan-keys: $answer"
answer=$(key_read "$(saved GATEWAY_KEYS_TOKEN)" ci-key)
[[ "$answer" == *' 403' ]] || fail "the gateway's token read the proxy's key: $answer"
answer=$(key_read "$(printf '0%.0s' $(seq 64))" ci-key)
[[ "$answer" == *' 401' ]] || fail "an unknown token was not refused: $answer"
pass "selan-keys reads the vault with its AppRole: the proxy's token reads a model key, the gateway's is refused it, a stranger's is refused"

[ -z "$(docker port selan-openbao-1)" ] || fail "openbao publishes a port: $(docker port selan-openbao-1)"
vault_ip=$(ip_on openbao vault)
curl -s --max-time 4 "http://$vault_ip:8200/v1/sys/health" >/dev/null && fail "the host reaches the vault at $vault_ip"
for net in inside egress front bridge; do
  attach=$net
  [ "$net" = bridge ] || attach=selan_$net
  docker run --rm --network "$attach" "$curl_image" -s --max-time 4 "http://$vault_ip:8200/v1/sys/health" >/dev/null 2>&1 &&
    fail "a container on $net reaches the vault at $vault_ip"
  docker run --rm --network "$attach" "$curl_image" -s --max-time 4 "http://openbao:8200/v1/sys/health" >/dev/null 2>&1 &&
    fail "a container on $net reaches the vault by name"
done
pass "the vault publishes no port and answers nothing from the host, inside, egress, front or the default bridge"
for component in proxy gateway caddy postgres; do
  grep -q '^VAULT_' <<<"$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "selan-$component-1")" &&
    fail "the $component is given a VAULT_ setting"
done
for component in proxy gateway; do
  reaches "$component" openbao 8200 && fail "the $component reaches the vault by name"
  reaches "$component" "$vault_ip" 8200 && fail "the $component reaches the vault at $vault_ip"
done
reaches keys openbao 8200 || fail "selan-keys does not reach the vault"
pass "only selan-keys reaches the vault: the proxy and the gateway have no VAULT_ setting and no route to it"
for component in proxy keys caddy; do
  reaches "$component" postgres 5432 && fail "the $component reaches the gateway's database"
done
reaches gateway postgres 5432 || fail "the gateway does not reach its database"
[ -z "$(docker port selan-postgres-1)" ] || fail "postgres publishes a port"
pass "only the gateway reaches its Postgres, which publishes no port"

compose exec -T openbao wget -q -T 4 -O /dev/null http://1.1.1.1 >/dev/null 2>&1 && fail "the vault reaches the internet"
compose exec -T caddy wget -q -T 4 -O /dev/null http://1.1.1.1 >/dev/null 2>&1 && fail "caddy reaches the internet"
reaches proxy 1.1.1.1 443 || fail "the proxy cannot reach the internet"
pass "only the proxy, the gateway and selan-keys have a way out; the vault and Caddy have none"

code=$(docker run --rm --network selan_front -e "C=$(ip_on caddy front)" --entrypoint sh "$curl_image" -c \
  'curl -sk -o /dev/null -w "%{http_code}" --resolve gw.selan-ci.test:443:$C https://gw.selan-ci.test/readyz')
[ "$code" = 200 ] || fail "a private address was refused by Caddy ($code)"

before=$(sha256sum openbao-init.json .env)
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN >/dev/null
[ "$before" = "$(sha256sum openbao-init.json .env)" ] || fail "a second run changed openbao-init.json or .env"
pass "a second run of install.sh, without the used tokens, changes nothing and is ready again"

unsealed() { # unsealed <seconds>: OpenBao answers unsealed within that long
  for _ in $(seq "$(($1 / 2))"); do
    compose exec -T openbao bao status >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
compose restart openbao >/dev/null 2>&1
unsealed 60 || fail "OpenBao stayed sealed after compose restart: $(compose logs --no-log-prefix unseal | tail -n 3)"
docker restart selan-openbao-1 >/dev/null
unsealed 60 || fail "OpenBao stayed sealed after docker restart: $(compose logs --no-log-prefix unseal | tail -n 3)"
grep -q 'OpenBao was sealed; unsealed it.' <<<"$(compose logs --no-log-prefix unseal)" ||
  fail "the unseal service did not say it unsealed OpenBao"
# selan-keys first: the proxy asks whether it is ready as it starts, and then only every five minutes.
compose restart keys >/dev/null 2>&1
for name in keys gw mcp; do
  [ "$name" != gw ] || compose restart proxy gateway >/dev/null 2>&1
  for _ in $(seq 60); do ready "$name" -k && break; sleep 2; done
  ready "$name" -k || fail "$name is not ready after a restart and unseal"
done
[ "$(control_log | grep -c 'RegisterServer')" = 3 ] || fail "a restart registered again instead of keeping its identity"
pass "OpenBao restarted, by compose or by docker, is unsealed by the unseal service with nobody's hands; all three are ready again and did not register again"

compose stop unseal >/dev/null 2>&1
compose restart openbao >/dev/null 2>&1
compose exec -T openbao bao status >/dev/null 2>&1 && fail "OpenBao came back unsealed with the unseal service stopped"
./unseal.sh
compose exec -T openbao bao status >/dev/null 2>&1 || fail "unseal.sh left OpenBao sealed"
pass "with the unseal service stopped, unseal.sh opens OpenBao by hand"

compose restart openbao >/dev/null 2>&1
compose exec -T openbao bao status >/dev/null 2>&1 && fail "OpenBao came back unsealed with the unseal service stopped"
before=$(sha256sum .env)
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN >/dev/null
compose exec -T openbao bao status >/dev/null 2>&1 || fail "a re-run of install.sh left OpenBao sealed"
[ "$before" = "$(sha256sum .env)" ] || fail "a re-run on a sealed vault changed .env"
[ "$(docker inspect -f '{{.State.Running}}' selan-unseal-1)" = true ] || fail "a re-run did not start the unseal service again"
pass "a re-run of install.sh on a sealed vault unseals it, starts the unseal service again and changes nothing"

old=$(grep '^KEYS_VAULT_SECRET_ID=' .env)
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN KEYS_VAULT_SECRET_ID=not-a-secret-id >/dev/null
[ "$old" != "$(grep '^KEYS_VAULT_SECRET_ID=' .env)" ] || fail "a secret id that no longer logs in was kept"
ready keys -k || fail "selan-keys is not ready with its new secret id"
pass "a secret id that no longer logs in is replaced, and selan-keys is ready with the new one"

cp signers.txt /tmp/signers.txt
sed -i 's#github\\.com/openbao/openbao/#github\\.com/someone-else/openbao/#' signers.txt
status=0
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN >/tmp/install.log 2>&1 || status=$?
cp /tmp/signers.txt signers.txt
if [ "$status" = 0 ] || ! grep -q 'openbao.* is not signed by' /tmp/install.log; then
  fail "install.sh did not refuse an image signed by somebody else: $(tail -n 5 /tmp/install.log)"
fi
pass "install.sh refuses an image whose signature names another signer than signers.txt"

cp openbao-init.json /tmp/openbao-init.json
sed -i '/"unseal_keys_b64"/,+1d' openbao-init.json
refused 1 'no unseal key in .*openbao-init.json' -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN
cp /tmp/openbao-init.json openbao-init.json
pass "an init file without an unseal key is refused"

cp openbao-init.json /tmp/openbao-init.json
sed -i '/"root_token"/d' openbao-init.json
refused 1 'no root token in .*openbao-init.json' -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN
cp /tmp/openbao-init.json openbao-init.json
pass "an init file without a root token is refused"

mv openbao-init.json /tmp/openbao-init.json
refused 1 'already initialised but .*openbao-init.json is missing' -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN
mv /tmp/openbao-init.json openbao-init.json
compose rm -sf openbao >/dev/null 2>&1
docker volume rm selan_openbao-data >/dev/null
refused 1 "OpenBao's data is empty but .*openbao-init.json exists" -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN
pass "install.sh refuses an initialised OpenBao without its init file, and an init file without OpenBao's data"
