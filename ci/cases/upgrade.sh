#!/usr/bin/env bash
# An upgrade as README's "Upgrade" does it: a server installed from an older release, with a key in its vault,
# checks out this commit and runs install.sh again with the same settings, twice. It exits 0, every service
# runs on the image this compose.yaml pins, the key is still read through selan-keys, `selan-keys` is
# installed, and the second run changes nothing.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

# The release whose upgrade stopped at "path is already in use at kv/": an older proxy, and no selan-keys command.
from=v0.2.4
wrapper=/usr/local/bin/selan-keys

# Read whole before it runs: the checkout under this file moves to $from and back.
main() {
  local new bao_root old_pins running answer before
  new=$(git rev-parse HEAD)
  git fetch -q --depth 1 https://github.com/selan-ai/selan-self-hosted tag "$from"
  git -c advice.detachedHead=false checkout -q "$from"
  # Untraced: ci/paths.py counts this commit's install.sh, not $from's.
  bash install.sh >/tmp/install.log 2>&1 || fail "installing $from exited $?: $(tail -n 5 /tmp/install.log)"
  grep -q "Installing from /opt/selan at $from " /tmp/install.log || fail "the first install was not at $from"
  [ ! -e "$wrapper" ] || fail "$from already installed $wrapper"
  bao_root=$(sed -n 's/^ *"root_token": *"\([^"]*\)".*/\1/p' openbao-init.json)
  # shellcheck disable=SC2016 # BAO_TOKEN is read inside the container, from stdin.
  printf '%s' "$bao_root" | compose exec -T openbao sh -c 'BAO_TOKEN=$(cat) bao kv put kv/selan/ci-key value=not-a-key provider=openrouter' >/dev/null
  old_pins=$(compose config --images | sort -u)
  pass "$from installed, with a key in its vault"

  git -c advice.detachedHead=false checkout -q "$new"
  install >/tmp/upgrade.log 2>&1 || fail "the upgrade from $from exited $?: $(tail -n 5 /tmp/upgrade.log)"
  [ "$old_pins" != "$(compose config --images | sort -u)" ] || fail "$from pins the images this commit does: nothing was upgraded"
  running=$(compose ps --format '{{.Image}}' | sort -u)
  [ "$running" = "$(compose config --images | sort -u)" ] || fail "the stack runs other images than this compose.yaml pins: $running"
  pass "the upgrade from $from exits 0 and every service runs on the image this commit pins"

  answer=$(key_read "$(saved PROXY_KEYS_TOKEN)" ci-key)
  [[ "$answer" == *'"value":"not-a-key"'*' 200' ]] || fail "the key stored under $from is not read after the upgrade: $answer"
  [ "$(mode "$wrapper")" = "root 755" ] || fail "the upgrade left $wrapper missing or not root 755"
  cmp -s selan-keys.sh "$wrapper" || fail "$wrapper is not selan-keys.sh"
  pass "the vault keeps its key, selan-keys reads it with the proxy's token, and $wrapper is installed"

  before=$(sha256sum .env openbao-init.json "$wrapper")
  install >/tmp/upgrade.log 2>&1 || fail "a second run at this commit exited $?: $(tail -n 5 /tmp/upgrade.log)"
  [ "$before" = "$(sha256sum .env openbao-init.json "$wrapper")" ] || fail "a second run at this commit changed .env, openbao-init.json or $wrapper"
  pass "a second run at this commit, with the same settings, exits 0 and changes nothing"
}

main
