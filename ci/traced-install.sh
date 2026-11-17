#!/usr/bin/env bash
# Runs install.sh (or the copy named) traced by line to /var/tmp/paths.trace, for ci/paths.py. CI only: the
# trace shows every value install.sh handles, which in CI are fakes.
exec 9>>/var/tmp/paths.trace
BASH_XTRACEFD=9
PS4='+${LINENO}: '
set -x
# shellcheck source=install.sh
. "${1:-./install.sh}"
