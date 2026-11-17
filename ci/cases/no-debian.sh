#!/usr/bin/env bash
# A release that is not Debian or Ubuntu (Alpine here): install.sh installs nothing itself, and says what
# to install first, curl and then Docker with the compose plugin.
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"

refused 1 'install curl first; this script installs it only on Debian or Ubuntu'
apk add -q curl
refused 1 'install Docker with the compose plugin first'
pass "on Alpine, install.sh asks for curl and then Docker, installing neither"
