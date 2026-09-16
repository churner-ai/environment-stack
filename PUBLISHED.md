# This repository is published, not authored

Every file here is copied verbatim from the churner monorepo, which is where
it is edited, reviewed and tested:

| here | monorepo |
| --- | --- |
| `host/bootstrap.sh` | `infrastructure/customer/environment-stack/host/bootstrap.sh` |
| `proxy/Caddyfile.tmpl` | `infrastructure/customer/environment-stack/proxy/Caddyfile.tmpl` |
| `README.md` | `infrastructure/customer/environment-stack/README.md` |
| `host/deploy-release.sh` | `github-actions/release-workflow/host/deploy-release.sh` |
| `scripts/copy-image.sh` | `github-actions/release-workflow/scripts/copy-image.sh` |

Do not patch them here: the next release overwrites the file, and the change
would never have run against the tests that EXECUTE these scripts against
shimmed `docker` / `aws` / `systemctl` / `curl`.

This repository is PUBLIC on purpose. An environment host fetches
`bootstrap.sh` at boot, and the release workflow fetches
`host/deploy-release.sh` and `scripts/copy-image.sh` per run, with a plain
unauthenticated `curl` — no GitHub credential of any kind. Every one of those
fetches is verified against a SHA-256 the customer can read in their own
rendered stack and workflow, so the repository being public is not what makes
the bytes trustworthy; the digests are.

Released from churner monorepo commit `0b87c5c`.
