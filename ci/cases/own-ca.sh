#!/usr/bin/env bash
# SELAN_TLS=files: the company's own CA. A CA made here issues one certificate for the three names;
# install.sh copies it in, and every name answers with it, checked against that CA alone (no -k).
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssl >/dev/null
ca=/root/ca
mkdir -p "$ca"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=ci-ca \
  -keyout "$ca/ca.key" -out "$ca/ca.pem" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=gw.selan-ci.test \
  -keyout "$ca/key.pem" -out "$ca/req.csr" 2>/dev/null
printf 'subjectAltName=DNS:gw.selan-ci.test,DNS:mcp.selan-ci.test,DNS:keys.selan-ci.test\n' >"$ca/san"
openssl x509 -req -in "$ca/req.csr" -CA "$ca/ca.pem" -CAkey "$ca/ca.key" -CAcreateserial -days 2 \
  -extfile "$ca/san" -out "$ca/cert.pem" 2>/dev/null
cat "$ca/cert.pem" "$ca/ca.pem" >"$ca/fullchain.pem"

files=(SELAN_TLS=files)
refused 1 'SELAN_TLS_CERT is not set' "${files[@]}"
refused 1 'SELAN_TLS_KEY is not set' "${files[@]}" SELAN_TLS_CERT="$ca/fullchain.pem"
refused 1 '/nowhere.pem is not a file' "${files[@]}" SELAN_TLS_CERT=/nowhere.pem SELAN_TLS_KEY="$ca/key.pem"
refused 1 '/nowhere.pem is not a file' "${files[@]}" SELAN_TLS_CERT="$ca/fullchain.pem" SELAN_TLS_KEY=/nowhere.pem
refused 1 'is not a PEM certificate chain' "${files[@]}" SELAN_TLS_CERT=/etc/hostname SELAN_TLS_KEY="$ca/key.pem"
refused 1 'is not a PEM private key' "${files[@]}" SELAN_TLS_CERT="$ca/fullchain.pem" SELAN_TLS_KEY=/etc/hostname
pass "SELAN_TLS=files refuses missing paths, missing files and files that are not PEM"

install "${files[@]}" SELAN_TLS_CERT="$ca/fullchain.pem" SELAN_TLS_KEY="$ca/key.pem" >/dev/null
for name in gw mcp keys; do ready "$name" --cacert "$ca/ca.pem" || fail "$name does not answer with the company CA's certificate"; done
[ "$(stat -c %a certs/fullchain.pem) $(stat -c %a certs/privkey.pem)" = "644 600" ] || fail "the certificate files have the wrong modes"
pass "every name answers with the company CA's certificate, checked against that CA alone"

hash=$(sha256sum .env certs/fullchain.pem certs/privkey.pem)
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN "${files[@]}" >/dev/null
[ "$hash" = "$(sha256sum .env certs/fullchain.pem certs/privkey.pem)" ] || fail "a re-run changed .env or the certificates"
install -u SELAN_REGISTRATION_TOKEN -u SELAN_KEYS_REGISTRATION_TOKEN "${files[@]}" SELAN_TLS_CERT="$ca/fullchain.pem" SELAN_TLS_KEY="$ca/key.pem" >/dev/null
[ "$hash" = "$(sha256sum .env certs/fullchain.pem certs/privkey.pem)" ] || fail "a re-run with the same files changed them"
pass "re-runs, with the certificates already in place or given again, change nothing"
