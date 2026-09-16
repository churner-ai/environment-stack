#!/usr/bin/env bash
#
# deploy-release.sh — bring one release up on a Churner environment host
# (design spec §7). Run BY SSM, as root, from `workflow.yml`.
#
# It is a FILE, fetched from a pinned tag and checksum-verified by the SSM
# command body, rather than a heredoc inside the workflow YAML: shell embedded
# in YAML can only be tested by re-parsing the YAML, and a test that re-derives
# the thing under test is testing its own parser. This file is EXECUTED by
# `shared/tests/release-workflow.test.ts` against shimmed `docker` / `aws` /
# `systemctl` / `curl`: a first deploy, a redeploy over a live container, a
# rollback to a host-local tag, and a candidate that never answers its health
# gate.
#
# ## Why the secrets are read HERE and not on the runner
#
# The database master password (when this environment has one) and the
# application's own secrets are read on this host, with the host's instance
# profile, and exported into this process's environment. They never cross the
# GitHub runner, so they cannot reach a step output, a workflow log, or an
# argv on a machine a pull request controls. The deployer role holds NO
# Secrets Manager grant at all — see
# `infrastructure/customer/environment-stack/README.md` → "The boundary".
#
# ## Why `docker run -e NAME` and not `-e NAME=value`
#
# `-e NAME` with no `=` tells docker to take the VALUE from this process's
# environment. `-e NAME=value` puts the value in docker's argv, where `ps`
# shows it to every other process on the host. Both forms reach the container
# identically; only one of them is readable from outside.
#
# ## Rollback points
#
# Before a container it is about to replace is removed, its image is tagged
# `<repository>:<environment>-prev-<unix-epoch-seconds>` — a cheap escape
# hatch the `rollback` action's `list` job reads back (via `docker images`,
# not a new AWS grant) and any `rollback` with that `target-tag` redeploys by
# name. It lives ON THIS HOST ONLY: it is never pushed, so a `docker pull` of
# it fails and the pull below falls back to the local image, and a REPLACED
# host has none of these at all. What survives a host is the release tags in
# ECR — `prod-<sha>` for everything ever promoted — and rolling back to one of
# those is the same `rollback` call with that tag.
#
# ## What the host needs from us
#
# The three `churner.release.*` labels are how `deploy-release.sh` and any
# future tooling answer "what is running" without a separate ledger — mirrors
# `infrastructure/customer/preview-stack/host/reaper.sh`'s five
# `churner.preview.*` labels for the same reason.
#
# Written for bash 3.2 (no associative arrays, no `mapfile`, no `${x^^}`) so
# `bash -n` on a developer's macOS is the same check CI runs.

set -euo pipefail

export LC_ALL=C

log() { echo "[churner-release-deploy] $*"; }
warn() { echo "[churner-release-deploy] $*" >&2; }
die() { echo "[churner-release-deploy] $*" >&2; exit 1; }

CONFIG_FILE="${CHURNER_ENVIRONMENT_CONFIG:-/etc/churner-environment/env}"

# Captured BEFORE the config file is sourced: sourcing ASSIGNS, so a value the
# workflow sent would be silently overwritten by the host's own copy. The
# workflow's value wins because it comes from the same `role-arn` /
# `codebuild-project` this run was invoked with; the file was written once at
# first boot.
#
# `CHURNER_HEALTH_PATH` is captured here for exactly the same reason, and used
# to be read AFTER the source — so the `health-path` input was inert on every
# run, the host's boot-time `/` silently winning over the path the caller
# configured. The rule is one line up from the bug: every value that can come
# from EITHER side is captured before the file can assign it.
SECRETS_PREFIX_INPUT="${CHURNER_SECRETS_PREFIX:-}"
HEALTH_PATH_INPUT="${CHURNER_HEALTH_PATH:-}"

if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# --- Inputs -----------------------------------------------------------------
#
# The first five come from the SSM command body the workflow builds; the rest
# from the host's own config file, written once by `bootstrap.sh`.

IMAGE_URI="${CHURNER_IMAGE_URI:-}"
TAG="${CHURNER_TAG:-}"
SHA="${CHURNER_SHA:-}"
SECRET_KEYS="${CHURNER_SECRET_KEYS:-}"
DB_SECRET_ARN="${CHURNER_DB_SECRET_ARN:-}"
HEALTH_PATH="${HEALTH_PATH_INPUT:-${CHURNER_HEALTH_PATH:-/}}"
APP_PORT="${CHURNER_APP_PORT:-8080}"

ENVIRONMENT="${CHURNER_ENVIRONMENT:-}"
SECRETS_PREFIX="${SECRETS_PREFIX_INPUT:-${CHURNER_SECRETS_PREFIX:-}}"
ROUTES_DIR="${CHURNER_ROUTES_DIR:-/etc/caddy/release-routes}"
AWS_REGION_NAME="${CHURNER_AWS_REGION:-}"

# --- Validation ---------------------------------------------------------------
#
# Every one of these reaches a shell word, a filesystem path, a Caddy config
# or a container name. It arrives from a GitHub Actions run this repository's
# own default-branch protections gate — trusted — and checked anyway, because
# "trusted" is a statement about intent and this is the input a mistake turns
# into an escaped shell word. All of it happens BEFORE the first side effect,
# so a refusal leaves the host untouched.

# Every pattern below is matched with `grep -Eqx` against a value first
# proved to be a SINGLE LINE (`one_line_matches`). `grep -Eq '^…$'` — which
# this used — succeeds when ANY LINE matches, so `good\nevil` passed every one
# of these checks (fix-round-1 review, N7). Every reachable path failed closed
# downstream, but these scripts are published artefacts documented as
# validating their own inputs, and they are the last line of defence.
one_line_matches() {
  # one_line_matches <value> <extended-regex>
  [ "$(printf '%s' "$1" | wc -l | tr -d '[:space:]')" = "0" ] || return 1
  printf '%s' "$1" | grep -Eqx "$2"
}

TAG_RE='[A-Za-z0-9][A-Za-z0-9._-]*'
SHA_RE='[0-9a-fA-F]{7,64}'
IMAGE_RE='[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*'
ENV_NAME_RE='[A-Za-z_][A-Za-z0-9_]*'
PORT_RE='[0-9]+'
# Rooted, and only characters a path in a URL can carry: this lands inside the
# health probe's own URL, and a value with a space or a `"` in it would make
# the poll ask for something nobody configured.
HEALTH_PATH_RE='/[A-Za-z0-9._~/-]*'
# `arn:aws:secretsmanager:<region>:<account>:secret:<name>` — checked because
# it reaches an `aws` argv, and because a mistyped ARN's failure should name
# the ARN rather than surface as a container with no DATABASE_URL. The `!` is
# not decoration: an RDS-MANAGED master secret — which is the only kind this
# script is ever handed — is named `rds!db-<id>`, so a charset without it
# refuses every real input.
DB_SECRET_ARN_RE='arn:[A-Za-z0-9-]+:secretsmanager:[A-Za-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@!-]+'

one_line_matches "$IMAGE_URI" "$IMAGE_RE" || die "CHURNER_IMAGE_URI is not a tagged image reference (got '${IMAGE_URI}')"
one_line_matches "$TAG" "$TAG_RE" || die "CHURNER_TAG is not a usable image tag (got '${TAG}')"
one_line_matches "$HEALTH_PATH" "$HEALTH_PATH_RE" || die "CHURNER_HEALTH_PATH must be a rooted path (got '${HEALTH_PATH}')"
if [ -n "$DB_SECRET_ARN" ]; then
  one_line_matches "$DB_SECRET_ARN" "$DB_SECRET_ARN_RE" \
    || die "CHURNER_DB_SECRET_ARN is not a Secrets Manager ARN (got '${DB_SECRET_ARN}')"
fi
# A rollback target (`<environment>-prev-<unix-ts>`) carries no git sha of
# its own — falls back to the tag itself for labeling rather than dying, so
# `rollback` need not fabricate a fake sha to satisfy this script.
one_line_matches "$SHA" "$SHA_RE" || SHA="$TAG"
one_line_matches "$APP_PORT" "$PORT_RE" || die "CHURNER_APP_PORT must be a port number (got '${APP_PORT}')"
[ -n "$ENVIRONMENT" ] || die "CHURNER_ENVIRONMENT is required (is ${CONFIG_FILE} present?)"
[ -n "$SECRETS_PREFIX" ] || die "CHURNER_SECRETS_PREFIX is required (is ${CONFIG_FILE} present?)"
one_line_matches "$SECRETS_PREFIX" '[A-Za-z0-9_/-]+' \
  || die "CHURNER_SECRETS_PREFIX is not a usable Secrets Manager prefix (got '${SECRETS_PREFIX}')"
[ -d "$ROUTES_DIR" ] || die "routes directory ${ROUTES_DIR} does not exist — was the host bootstrapped?"

# Every requested key, checked before the FIRST one is fetched: a partial
# apply that dies halfway would leave the container running on some of its
# configuration, which is worse than not running at all.
for key in $SECRET_KEYS; do
  one_line_matches "$key" "$ENV_NAME_RE" \
    || die "secret key '${key}' is not a usable environment-variable name"
done

CONTAINER="churner-release-${ENVIRONMENT}"
NEXT_CONTAINER="${CONTAINER}-next"

# --- The two host ports -------------------------------------------------------
#
# Blue-green needs TWO, because the candidate is started BEFORE the container
# it replaces is removed. A single derived port made the second deploy to a
# host impossible: the surviving container still held it, so `docker run`
# failed with "port is already allocated" and every release after the first
# died there.
#
# Which one is free is not guessed, it is READ — from what the live container
# actually published. A host whose deploy was interrupted between `docker run`
# and the swap can be left on either port, and the pair is picked so the
# candidate never lands on the one still in use.
PORT_A=$(( 20000 + (APP_PORT % 20000) ))
PORT_B=$(( PORT_A + 1 ))
CURRENT_PORT="$(docker port "$CONTAINER" "${APP_PORT}/tcp" 2>/dev/null | head -1 | sed 's/.*://' || true)"
case "$CURRENT_PORT" in
  "$PORT_A") NEXT_PORT="$PORT_B" ;;
  *)         NEXT_PORT="$PORT_A" ;;
esac

AWS_ARGS=""
if [ -n "$AWS_REGION_NAME" ]; then
  AWS_ARGS="--region $AWS_REGION_NAME"
fi

# --- Secrets ------------------------------------------------------------------

# Returns 0 with the SecretString on stdout, NON-ZERO if the call itself
# failed. The distinction is the point: an IAM denial, a wrong region and a
# secret that does not exist all make the call fail, and treating those as
# "the secret is empty" is how a deploy comes up silently misconfigured.
read_secret() {
  # shellcheck disable=SC2086
  if ! secret_response="$(aws secretsmanager get-secret-value \
      --secret-id "$1" $AWS_ARGS --output json 2>/dev/null)"; then
    return 1
  fi
  printf '%s' "$secret_response" | jq -r '.SecretString // empty'
}

# A real bash array (not word-splitting on a string) so a secret value
# containing whitespace can never become a second argument by accident. Plain
# indexed arrays are bash 2+; only associative arrays are off the table for
# bash 3.2.
ENV_ARGS=(-e PORT)
# The port the application binds INSIDE its container — never the host port
# docker publishes to. `--publish 127.0.0.1:<host>:<app>` forwards to
# `$APP_PORT` in the container's own network namespace, so an application that
# honours `PORT` (the convention this script relies on by passing `-e PORT` at
# all) and was told the host's number would listen where nothing is forwarded:
# the health gate would then fail for 120 seconds on every single deploy.
export PORT="$APP_PORT"

if [ -n "$DB_SECRET_ARN" ]; then
  if ! DB_SECRET_JSON="$(read_secret "$DB_SECRET_ARN")"; then
    die "reading ${DB_SECRET_ARN} failed — the host's role was denied, or the secret does not exist in this region"
  fi
  [ -n "$DB_SECRET_JSON" ] || die "${DB_SECRET_ARN} holds no SecretString; the application cannot reach its database"

  db_field() {
    printf '%s' "$DB_SECRET_JSON" | jq -r ".$1 // empty" 2>/dev/null
  }

  DB_HOST="$(db_field host || true)"
  DB_PORT="$(db_field port || true)"
  DB_USER="$(db_field username || true)"
  DB_PASS="$(db_field password || true)"
  DB_NAME="$(db_field dbname || true)"
  [ -n "$DB_HOST" ] || die "${DB_SECRET_ARN} carries no host"
  [ -n "$DB_USER" ] || die "${DB_SECRET_ARN} carries no username"
  [ -n "$DB_PASS" ] || die "${DB_SECRET_ARN} carries no password"
  [ -n "$DB_PORT" ] || DB_PORT=5432
  [ -n "$DB_NAME" ] || DB_NAME="$ENVIRONMENT"

  # Percent-encoded: a generated password containing `@`, `/` or `#` would
  # otherwise produce a URL whose authority is not the one we meant. Over
  # STDIN, not `--arg`: `--arg s "$password"` puts the master password in
  # jq's argv, which `ps` shows to every other process on the host.
  urlencode() { printf '%s' "$1" | jq -sRr '@uri'; }

  DATABASE_URL="postgresql://$(urlencode "$DB_USER"):$(urlencode "$DB_PASS")@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  export DATABASE_URL
  ENV_ARGS+=(-e DATABASE_URL)
fi

# `-e "$key"` reads each value from this process's own environment — never
# the NAME=value form, which would put the value in docker's argv where `ps`
# shows it to every other process on a shared host.
for key in $SECRET_KEYS; do
  case "$key" in
    PORT|DATABASE_URL)
      warn "secret key ${key} would shadow a value this script derives; skipping it"
      continue
      ;;
  esac
  if ! value="$(read_secret "${SECRETS_PREFIX}/${key}")"; then
    die "reading ${SECRETS_PREFIX}/${key} failed — the host's role was denied, or the secret does not exist"
  fi
  if [ -z "$value" ]; then
    warn "secret ${SECRETS_PREFIX}/${key} holds an empty value; ${key} will not be set"
    continue
  fi
  export "${key}=${value}"
  ENV_ARGS+=(-e "$key")
done
unset value

# --- Image ----------------------------------------------------------------

REGISTRY="${IMAGE_URI%%/*}"
log "logging in to ${REGISTRY}"
# shellcheck disable=SC2086
aws $AWS_ARGS ecr get-login-password \
  | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null \
  || die "could not authenticate to ${REGISTRY}"

log "pulling ${IMAGE_URI}"
if ! docker pull "$IMAGE_URI" >/dev/null; then
  # A rollback point (`<environment>-prev-<unix-ts>`) is a tag THIS SCRIPT
  # made on a previous deploy, on this host, and never pushed — so the pull
  # is expected to fail for exactly the images `rollback` is most often
  # pointed at. Falling back to the local image is what makes that action
  # work at all; a tag that is in neither place is still a hard failure,
  # because deploying "whatever was lying around" is not a rollback.
  if docker image inspect "$IMAGE_URI" >/dev/null 2>&1; then
    log "${IMAGE_URI} is not in the registry; using the copy already on this host"
  else
    die "could not pull ${IMAGE_URI}, and this host holds no image under that tag"
  fi
fi

# --- Start the candidate container -----------------------------------------
#
# Started under a "-next" name on a second port. The route still points at
# whatever container answered the last successful deploy until the health
# gate below passes, so a bad release never reaches a real request.
#
# The hardening flags mirror the preview host's, for the same reason: this is
# an image built from a branch, running on a host that also runs the
# platform's own proxy.

docker rm -f "$NEXT_CONTAINER" >/dev/null 2>&1 || true

log "starting ${NEXT_CONTAINER} on 127.0.0.1:${NEXT_PORT}"
docker run -d \
  --name "$NEXT_CONTAINER" \
  --restart unless-stopped \
  --publish "127.0.0.1:${NEXT_PORT}:${APP_PORT}" \
  --memory 1g \
  --memory-swap 1g \
  --pids-limit 512 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=256m \
  --label churner.release=true \
  --label "churner.release.tag=${TAG}" \
  --label "churner.release.sha=${SHA}" \
  "${ENV_ARGS[@]}" \
  "$IMAGE_URI" >/dev/null \
  || die "could not start ${NEXT_CONTAINER}"

# --- health gate --------------------------------------------------------------
#
# Polled directly on the candidate's own port, never through the proxy: the
# proxy is not pointed at it yet, and that is exactly the point.

HEALTH_OK=0
for _ in $(seq 1 60); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${NEXT_PORT}${HEALTH_PATH}" || printf '000')"
  case "$code" in
    2*|3*) HEALTH_OK=1; break ;;
  esac
  sleep 2
done

if [ "$HEALTH_OK" != "1" ]; then
  warn "${NEXT_CONTAINER} never answered ${HEALTH_PATH}; rolling back this attempt"
  docker rm -f "$NEXT_CONTAINER" >/dev/null 2>&1 || true
  die "release ${TAG} (${SHA}) failed its health gate; the previous release is still serving"
fi

# --- Swap --------------------------------------------------------------------
#
# The route is written only now, after the health gate — a failed release
# above is a no-op, never an outage. The previous container's IMAGE is tagged
# as a rollback point BEFORE it is removed, so a bad release that somehow
# passed its own health check can still be undone.
#
# ACTIVATING the route is the one step that can fail with the old container
# still serving and the new one already healthy, and it used to be a WARNING:
# the route file named the new port, Caddy went on serving the old one, and
# four lines later the container behind it was deleted — a 502 until somebody
# reloaded the proxy by hand. A reload that FAILS is therefore a FAILED
# DEPLOY: the route file goes back to what it said, Caddy is asked again, and
# nothing is removed. The previous release keeps serving, which is the same
# promise the health gate above makes.
#
# WHAT THAT CHECK PROVES, exactly: `systemctl reload caddy` runs
# `/bin/kill -USR1 $MAINPID`, which succeeds whenever the process is there. So
# a non-zero exit means the SIGNAL could not be delivered — caddy is down, the
# unit is not loaded — and that is the case this refuses. It is NOT proof the
# new configuration took: Caddy answers SIGUSR1 by re-reading its config and,
# on one it cannot load, KEEPS THE OLD ONE and logs. A route file of two
# generated lines is unlikely to be the thing it rejects (the realistic
# rejection is a Caddyfile already broken for other reasons), and checking
# properly would need the admin API this host deliberately turns off — so the
# gap is stated here rather than papered over.
#
# There is ONE swap, and every action shares it — `cut-rc`, `promote` and
# `rollback` all reach this block through the same script, so a rollback whose
# reload fails is refused exactly like a deploy whose reload fails.

ROUTE_FILE="${ROUTES_DIR}/release.caddy"
ROUTE_TMP="${ROUTE_FILE}.tmp"
# Neither name ends in `.caddy`, so the Caddyfile's `import <dir>/*.caddy`
# glob never picks either of them up.
ROUTE_BACKUP="${ROUTE_FILE}.previous"

HAD_ROUTE=0
if [ -f "$ROUTE_FILE" ]; then
  HAD_ROUTE=1
  cp "$ROUTE_FILE" "$ROUTE_BACKUP"
fi

{
  printf '# %s release %s (%s)\n' "$ENVIRONMENT" "$TAG" "$SHA"
  printf 'reverse_proxy 127.0.0.1:%s\n' "$NEXT_PORT"
} > "$ROUTE_TMP"
mv "$ROUTE_TMP" "$ROUTE_FILE"

# `systemctl reload caddy` sends SIGUSR1 (the unit `bootstrap.sh` installs).
# `caddy reload` would POST to the admin API, which the Caddyfile turns off,
# and would silently do nothing.
if ! systemctl reload caddy; then
  warn "caddy did not reload; restoring the route the previous release was serving on"
  if [ "$HAD_ROUTE" = "1" ]; then
    mv "$ROUTE_BACKUP" "$ROUTE_FILE"
  else
    # There was no release before this one: the correct previous state is no
    # route file at all, which is the placeholder-and-503 the host boots with.
    rm -f "$ROUTE_FILE"
  fi
  # Best effort, and consistent either way: a second failure leaves Caddy
  # running the configuration it last LOADED, which is the previous release's
  # — the same thing the restored file now says.
  systemctl reload caddy \
    || warn "the restoring reload failed too; caddy is still serving the configuration it last loaded"
  docker rm -f "$NEXT_CONTAINER" >/dev/null 2>&1 || true
  die "caddy did not reload, so release ${TAG} (${SHA}) was not activated; the previous release is still serving and nothing was removed"
fi
rm -f "$ROUTE_BACKUP"

PREVIOUS_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
if [ -n "$PREVIOUS_IMAGE" ]; then
  # `%:*` — strip at the LAST colon, not the first. `%%:*` is correct for an
  # ECR URI and wrong for any registry carrying a port (`host:5000/repo:tag`),
  # where it would cut the registry in half and tag something else entirely.
  PREV_TAG="${IMAGE_URI%:*}:${ENVIRONMENT}-prev-$(date -u +%s)"
  docker tag "$PREVIOUS_IMAGE" "$PREV_TAG" 2>/dev/null \
    || warn "could not tag ${PREVIOUS_IMAGE} as a rollback point; continuing"
fi

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker rename "$NEXT_CONTAINER" "$CONTAINER" \
  || warn "could not rename ${NEXT_CONTAINER} to ${CONTAINER}; the release is live under its -next name"

log "churner-release-deployed: ${TAG} ${SHA}"
