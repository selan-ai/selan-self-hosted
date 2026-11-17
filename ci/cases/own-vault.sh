#!/usr/bin/env bash
# The company's own Vault: an OpenBao dev server on this host stands in for it, with an AppRole for
# selan-keys. install.sh runs no OpenBao, changes nothing in that Vault, and selan-keys reads through it.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

own=(SELAN_VAULT=own)
# A fresh server: this first, refused run is also the one that installs Docker.
refused 1 'VAULT_ADDR is not set' "${own[@]}"

docker run -d --name own-vault -p 8201:8200 \
  quay.io/openbao/openbao:2.7.2@sha256:5046911075e137e154ce49ab051502f4ec7cf367d484ae4a4dce665d9b90561f \
  server -dev -dev-root-token-id=ci-root -dev-listen-address=0.0.0.0:8200 >/dev/null
ov() { docker exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN=ci-root own-vault bao "$@"; }
for _ in $(seq 30); do ov status >/dev/null 2>&1 && break; sleep 1; done
ov secrets enable -path=kv kv-v2 >/dev/null
ov auth enable approle >/dev/null
ov policy write selan-keys - >/dev/null <<'POLICY'
path "kv/data/selan/*" { capabilities = ["create", "read", "update", "delete"] }
path "kv/metadata/selan/*" { capabilities = ["read", "list", "delete"] }
POLICY
ov write auth/approle/role/selan-keys token_policies=selan-keys >/dev/null
role=$(ov read -field=role_id auth/approle/role/selan-keys/role-id)
secret=$(ov write -f -field=secret_id auth/approle/role/selan-keys/secret-id)
address=http://$(hostname -I | awk '{ print $1 }'):8201
state() { ov policy list; ov auth list -format=json | grep -o '"[a-z]*/":' ; ov read -format=json auth/approle/role/selan-keys | grep -v request_id; }
before=$(state)

refused 1 "VAULT_ADDR 'vault' is not a URL" "${own[@]}" VAULT_ADDR=vault
refused 1 'KEYS_VAULT_ROLE_ID is not set' "${own[@]}" VAULT_ADDR="$address"
refused 1 'KEYS_VAULT_SECRET_ID is not set' "${own[@]}" VAULT_ADDR="$address" KEYS_VAULT_ROLE_ID="$role"
refused 1 'an AppRole id has characters' "${own[@]}" VAULT_ADDR="$address" KEYS_VAULT_ROLE_ID="$role" KEYS_VAULT_SECRET_ID='not one'
pass "SELAN_VAULT=own refuses a missing or malformed address, role id and secret id"

install -u SELAN_VAULT VAULT_ADDR="$address" KEYS_VAULT_ROLE_ID="$role" KEYS_VAULT_SECRET_ID="$secret" | tee /tmp/install.log
grep -q "Using your Vault at $address; nothing in it is changed." /tmp/install.log || fail "install.sh did not say it uses the own Vault"
grep -qx "SELAN_VAULT='own'" .env || fail ".env does not record SELAN_VAULT=own"
grep -qx "COMPOSE_PROFILES=''" .env || fail ".env still starts OpenBao"
[ -z "$(docker ps -q --filter name=selan-openbao)" ] || fail "OpenBao runs beside the company's own Vault"
for name in gw mcp keys; do ready "$name" -k || fail "$name is not ready"; done
[ "$(ov kv get -field=value kv/selan/canary)" = not-a-key ] || fail "selan-keys did not write through the own Vault"
[ "$before" = "$(state)" ] || fail "install.sh changed the own Vault's policies, auth methods or AppRole"
for component in proxy gateway; do
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "selan-$component-1" | grep -q '^VAULT_' &&
    fail "the $component is given a VAULT_ setting"
done
pass "SELAN_VAULT=own (implied by VAULT_ADDR): no OpenBao, the Vault unchanged, selan-keys reads and writes through it"

hash=$(sha256sum .env)
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN -u SELAN_VAULT >/dev/null
[ "$hash" = "$(sha256sum .env)" ] || fail "a re-run with the own Vault changed .env"
pass "a re-run with the own Vault, its settings read back from .env, changes nothing"
