# selan-self-hosted

Public install for Selan's Own proxy: a company's own proxy, MCP gateway, selan-keys and vault, inside its VPN.
`README.md` is the contract; `docs/design/self-hosted-secrets.md` in selan-control is the design.

## Rules

- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, shellcheck-clean, readable top to bottom.
  `install.sh` also runs under macOS's bash 3.2 (the local skill): no `mapfile`, no `"${empty[@]}"`.
- `install.sh` is idempotent: a second run with nothing new changes no file. The cases check it.
- No pipe into `grep -q` or `head`: it leaves at the match, and under `pipefail` its writer's broken pipe
  fails the line. Read the output into a variable, then match it; `check` refuses one.
- Every path of `install.sh` is taken by a case in `ci/cases/` (README, "Tests"): a new branch or `fail`
  gets its case in the same pull request, or `ci/paths.py` fails the build. Excuse a line in
  `ci/paths-allowed.txt` only when no CI host can reach it, and say why.
- `install.sh` runs unattended: every question it asks has an environment variable, and without a terminal
  (or with `SELAN_NONINTERACTIVE=1`) a missing one fails naming it. selan-proxy-e2e installs it this way in
  a fresh Ubuntu container with its own Docker daemon, and `ci/dind-test.sh` does the same.
- A secret (a registration token, a caller's selan-keys token, the DNS token, an AppRole secret id, the
  unseal key, the root token) never lands on a command line, in a log or in output. It goes through the
  environment, stdin or a root-only file.
- Every image in `compose.yaml` is pinned by digest; a release bumps one by pull request after trying it.
  Caddy is ours (`caddy/`): a change there publishes from `main` (`caddy-image`), then a PR pins it.
- The vault shares the `vault` network with selan-keys alone, with no ports; only `keys` gets `VAULT_*`
  and an AppRole. The proxy and the gateway reach keys with `SELAN_KEYS_URL` and their own
  `SELAN_KEYS_TOKEN`, never the vault; the `openbao` case asserts they cannot. The proxy, the gateway
  and keys join `egress`, and Caddy with `SELAN_TLS=dns` (`compose.dns.yaml`), for Let's Encrypt and
  the DNS provider.
- Nothing is served by Selan at install time: the line clones a release tag, and `install.sh` runs from
  that checkout and never fetches this repository or anything from selan.ai.
- `install.sh` checks every image's cosign signature against `signers.txt` before pulling it; a new image
  gets its signer line in the same pull request. `SELAN_UNSIGNED_OK` is for CI's stand-ins only.
- A release is a `vX.Y.Z` tag on `main`, cut once `check` is green; Add server's line names it.

## Checks, before pushing

```sh
git ls-files -z '*.sh' | xargs -0 shellcheck
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
for c in ci/cases/*.sh; do bash ci/dind-test.sh "$(basename "$c" .sh)"; done   # privileged containers
python3 ci/paths.py ci-out/paths-*.txt && bash ci/stack-down.sh
```

`main` takes changes by pull request only. Commits carry no AI attribution.
