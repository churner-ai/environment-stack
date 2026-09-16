# Churner environment stack (customer-side)

The opt-in module of the Churner access stack (design spec §7) that provisions
**one application environment — production, rc, or any other named
environment — in your AWS account, under your identity.** Applying it once
per environment creates a Docker host, a database (optional), an object
storage bucket (optional), a CloudWatch log group, an ECR registry, a
CodeBuild project, and a GitHub OIDC deployer role, scoped to that one
environment and nothing else.

The rendering lives in `shared/access/environment-stack.ts`; these files are
what the host itself runs.

```
environment-stack/
  host/bootstrap.sh      first-boot setup, fetched and verified by UserData
  proxy/Caddyfile.tmpl   reverse-proxy config, rendered by bootstrap.sh
```

## The boundary

**This module grants Churner nothing. Every resource it creates carries the
environment tag your capability table already governs, so what Churner may
read of it is exactly what you already allowed. The deployer role is a
GitHub Actions identity: it cannot assume anything in Churner's account, and
it reads no secrets — your application's secrets are read on the host, under
the host's own instance profile.**

The deployer's own permissions are **exactly what the release workflow
calls**, and nothing beyond it:

| It may | It may not |
|---|---|
| start the module's CodeBuild project and read its status | push a NEW image — the build does that, under the build project's own service role |
| read/write image tags in this environment's own ECR repository (`ecr:BatchGetImage`/`ecr:PutImage`) | reach any other repository, or any other account's registry |
| **on a `production` environment created alongside an `rc`:** READ the candidate's repository (manifest + layers) and WRITE layers into its own, so a promote can move the exact artefact rc was serving | write anything at all to the candidate's repository, or read any THIRD environment's |
| run `AWS-RunShellScript` on an instance tagged `churner-environment-host=<this environment's name>` | run a command anywhere else, or run any other document |
| find that instance (`ssm:DescribeInstanceInformation`) and read its command's result by id | list the account's commands, or read any other principal's |
| — | **read any secret**, or ask RDS anything |

The promote row is the only grant in this module that names a resource
belonging to another environment, and it is read-only in that direction. It
is rendered **only** onto a `production` environment's role, and **only**
when the same stack creates an `rc` beside it — an environment applied on its
own gets a role byte-for-byte identical to one from before promotion
existed.

**The deployer reads no secrets.** The database master password and your
application's secrets are read *on the host*, inside the script SSM runs,
under the host's own instance profile. That matters because this role is
assumable by a workflow on the repository's default branch, and a step that
prints what it can read is one commit away.

## Applying the stack

Apply the module once **per environment** — once for `production`, again for
`rc`, and so on. Each application creates its own fully independent host,
repository, database and role: nothing is shared between environments except
the account they live in, (when you configure `reach`) the ability for a
reach instance to reach a created database, and the one read-only
cross-repository grant a promote needs (see **The boundary** above).

**A release pipeline wants two of them.** The wizard's default — `production`
plus an optional `rc` — is what the release workflow is built around: the
candidate lands on rc's host, is looked at there, and is then promoted to
production as the same image, never a rebuild. Create only `production` and
`cut-rc` has nowhere to put a candidate but production itself.

### 1. Subnets must be public

The spec wants **at least two public subnets in different availability
zones**. The module provisions no NAT gateway, and the host has to reach the
SSM endpoints, ECR, GitHub and Churner: in a private subnet with no egress
path it bootstraps into nothing and never registers with SSM. The host is
protected by its security group (inbound only on the ports the environment's
domain configuration needs) rather than by the absence of a route, and the
database by its own group plus `PubliclyAccessible: false`.

### 2. If the account already has a GitHub OIDC provider

This module does not create a GitHub Actions OIDC provider of its own — its
deployer role's trust policy references the provider AWS derives
deterministically from your account id and the fixed issuer host
(`token.actions.githubusercontent.com`), which an AWS account may hold only
**one** of, per issuer. If you have already applied the Churner preview
stack (or any other stack that created one) in this account, nothing further
is needed. If this is the first Churner module you are applying here, create
the provider once, out of band:

```
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Skip it if the provider already exists — a second `create-open-id-connect-provider`
call for the same issuer fails with `EntityAlreadyExists`.

### 3. A private repository needs a CodeBuild source credential

The module's CodeBuild project builds from your GitHub repository. For a
**private** repository, CodeBuild needs a source credential in that account,
once, out of band — neither CloudFormation nor Terraform can create one,
because the stack holds no GitHub token:

```
aws codebuild import-source-credentials \
  --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN --token <pat>
```

Skip it for a public repository. Without it, builds fail with an
authentication error rather than a missing-prerequisite one.

## Script integrity

The host fetches `bootstrap.sh` at boot and runs it as root. That fetch is
pinned and verified:

- `ENVIRONMENT_SCRIPTS_BASE_URL` (baked into the rendered UserData — unlike
  the preview stack, this module exposes no customer-facing stack parameter
  for it) points at a **tag** (`refs/tags/v1`) on the public
  [`churner-ai/environment-stack`](https://github.com/churner-ai/environment-stack)
  repository, never a branch. Tags there are IMMUTABLE once published — `v1`
  goes on serving exactly the bytes this module's renderer pins, forever; a
  script change cuts a NEW tag rather than re-pointing an old one, so the
  pinned digest and the tag it names can never disagree. The host fetches
  with a plain unauthenticated `curl`, holding no GitHub credential of any
  kind, so the repository it reads from has to be public — the digests
  below, not the repository's visibility, are what make the bytes
  trustworthy.
- `ENVIRONMENT_BOOTSTRAP_SHA256` (`shared/access/environment-stack.ts`) is
  the SHA-256 of `bootstrap.sh`. UserData verifies the download against it
  **before** executing anything.
- `bootstrap.sh` carries a pinned digest for everything it goes on to fetch:
  `Caddyfile.tmpl`, and the Caddy release tarball (SHA-512, as published by
  the Caddy project).

So the chain has one root of trust — a digest compiled into this module's
own renderer — and no unverified hop. Regenerate the digests with
`scripts/environment-stack-digests.sh`; a test asserts them against the
files.

`CADDY_VERSION` is a single literal in `bootstrap.sh` with no environment
override, and it moves together with the two `SHA512_CADDY_*` digests. It
must stay at **2.11.0 or later**: reload-on-SIGUSR1, which is how a route
change reaches the running proxy, does not exist before that.

### Maintaining the tag

These files are AUTHORED in the private churner monorepo and PUBLISHED to TWO
public repositories, each under its own immutable tag, by one script each:

```
scripts/release-environment-stack.sh <checkout> <tag> [--push]   # cut FIRST
scripts/release-release-workflow.sh  <checkout> <tag> [--push]
```

**`churner-ai/environment-stack`** carries everything a HOST or a release RUN
fetches, laid out so one base URL serves every fetch:

```
infrastructure/customer/environment-stack/host/bootstrap.sh    -> host/bootstrap.sh
infrastructure/customer/environment-stack/proxy/Caddyfile.tmpl -> proxy/Caddyfile.tmpl
infrastructure/customer/environment-stack/README.md            -> README.md
github-actions/release-workflow/host/deploy-release.sh         -> host/deploy-release.sh
github-actions/release-workflow/scripts/copy-image.sh          -> scripts/copy-image.sh
```

**`churner-ai/release-workflow`** carries the reusable workflow itself —
`uses:` resolves one only under `.github/workflows/` — and is published by
`scripts/release-release-workflow.sh`:

```
github-actions/release-workflow/workflow.yml -> .github/workflows/release.yml
github-actions/release-workflow/README.md    -> README.md
```

Both tags are cut for a release to be complete, under the SAME tag name, and
the `environment-stack` one is cut **FIRST**: the workflow's
`CHURNER_RELEASE_SCRIPT_SHA256` and `CHURNER_COPY_SCRIPT_SHA256` name bytes
the environment-stack tag serves, so a workflow tagged ahead of them is a
workflow whose every run fails at `sha256sum -c`.

Each script refuses a tag that already exists — locally AND on the remote,
because a checkout that has not fetched someone else's tag must not re-cut it
out from under them — requires both trees clean, verifies every pin against
the bytes it is about to publish (all three pin sets, for the stack script:
the renderer's `ENVIRONMENT_BOOTSTRAP_SHA256`, the table inside
`bootstrap.sh`, and the workflow's two), and pushes nothing without `--push`.
A release that tags bytes those literals do not name would brick every
environment host at once, with the failure pointing at the host rather than
at the release, so it is refused here instead.

**Every row is load-bearing.** The release workflow fetches
`host/deploy-release.sh` and `scripts/copy-image.sh` from this same
repository and tag — one base URL serves every artefact an environment pulls,
which is why the two workflow scripts are published here rather than beside
the workflow itself. A tag cut without them 404s on every `cut-rc`,
`promote` and `rollback`, and the failure points at the customer's host
rather than at the release.

**The tag currently in effect, `refs/tags/v1` on `churner-ai/environment-stack`,
must be cut from a release whose `bootstrap.sh` hashes to the
`ENVIRONMENT_BOOTSTRAP_SHA256` the renderer ships.** Tags on this repository
are IMMUTABLE — never re-cut, never moved — so a script change cuts the
NEXT tag (`v2`, then `v3`, ...) instead. Skip the release entirely and the
failure is silent in the worst way — a host fetches the tag its module
names, its digest does not match, and every new environment host refuses to
bootstrap until someone cuts a release.

The digest inside `bootstrap.sh` has the same property in reverse: it is
checked against the working tree by CI, so an edit to `proxy/Caddyfile.tmpl`
without `scripts/environment-stack-digests.sh --write` fails the build
rather than the host.

## The workflow contract

The release workflow (`github-actions/release-workflow/`) assumes the
deployer role via OIDC. Two things have to be true or the assume fails:

```yaml
permissions:
  id-token: write          # required to mint the OIDC token
  contents: read
```

- **The workflow runs from a ref this repository controls**, never a fork's
  pull request: GitHub does not issue an id-token with write permissions to a
  workflow triggered that way, and the trust policy would not accept one
  anyway.
- **The subject the token carries is one the trust policy names.** The role
  admits both shapes GitHub mints for this repository:

  ```
  repo:<owner>/<repo>:ref:refs/*          an ordinary job
  repo:<owner>/<repo>:environment:*       a job bound to a GitHub environment
  ```

  The second is not optional. `promote` and `rollback` are held for approval
  by a job-level `environment:`, and an environment REPLACES the ref segment
  of the `sub` claim — the claim is a property of the JOB, not of the step
  that assumes the role, so putting the gate on the job does not keep it out
  of the token. A policy admitting only the ref shape denies every gated
  deploy at `configure-aws-credentials`, before it has done anything.

### Container labels

The `deploy-release.sh` host script (part of `github-actions/release-workflow/`)
labels every release container so the host can answer "what is running"
without a separate ledger:

```
docker run -d \
  --label churner.release=true \
  --label churner.release.tag=<image tag, e.g. rc-abc1234> \
  --label churner.release.sha=<full commit sha> \
  ...
```

### Routes

The release script writes one file into `$CHURNER_ROUTES_DIR` (from the
host's `/etc/churner-environment/env`, written once by `bootstrap.sh`) naming
the currently-live release, then reloads Caddy:

```
# $CHURNER_ROUTES_DIR/release.caddy
http://example.com {
	reverse_proxy 127.0.0.1:8081
}
```

then `systemctl reload caddy`. The unit's `ExecReload` sends **SIGUSR1** —
`caddy reload` would POST to the admin API, which the Caddyfile turns off,
and would silently do nothing.

## Tearing it down

The database (when created) has no deletion protection and no
`skip_final_snapshot`/backups guarantee beyond what you configure — check
your renderer's defaults before relying on either. Two things do not
disappear cleanly:

- **The database secret.** Terraform sets `recovery_window_in_days = 0`, so
  it is deleted immediately. **CloudFormation does not** — the secret enters
  a 30-day recovery window still holding its name, and a re-apply within
  that window fails with "a secret with this name is scheduled for
  deletion". Force it first:

  ```
  aws secretsmanager delete-secret \
    --secret-id <secretsPrefix>/environment-db --force-delete-without-recovery
  ```

- **The ECR repository** refuses to delete while it holds images. Empty it,
  or delete it with `--force`.
