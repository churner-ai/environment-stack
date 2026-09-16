#!/usr/bin/env bash
#
# copy-image.sh — copy ONE image, byte for byte, from the candidate
# environment's ECR repository into production's (design spec §7.2/§7.4).
# Run ON THE RUNNER by `workflow.yml`'s `promote` job, under production's
# deployer role.
#
# ## Why a copy and not a retag
#
# `rc` and `production` are two separate created environments, each with its
# own host, database and REGISTRY. `ecr:PutImage` validates that every layer
# a manifest names already exists IN THE TARGET repository, so a
# manifest-only retag works within one repository and cannot cross two.
# Promoting the exact artefact the operator looked at therefore means moving
# its bytes: read the manifest, pull each blob it names out of the source, put
# any the target does not already hold, then put the manifest under the new
# tag. Rebuilding from the same commit would be simpler and would promote a
# DIFFERENT artefact — a different base-image layer, a different dependency
# resolution — which is the one thing a promote must never do.
#
# ## Why a file, not a heredoc in the workflow
#
# Same rule `deploy-release.sh` states: shell embedded in YAML can only be
# tested by re-parsing the YAML. This file is fetched from the same pinned tag
# as the host scripts, checksum-verified before it runs, and EXECUTED by
# `shared/tests/release-workflow.test.ts` against a shimmed `aws` / `curl`.
#
# ## Why a re-promote is safe to run
#
# Every step is idempotent, because the step most likely to be re-run is this
# one: the copy happens BEFORE the production deploy, so "copy succeeded,
# deploy failed" is the ordinary partial failure, and re-running `promote` is
# the ordinary response. A target that already holds the manifest DIGEST is
# not copied into again; a blob the target already holds is skipped; and a
# `PutImage` that reports the manifest and tag are unchanged is success, not
# failure.
#
# ## The grants this needs, and nothing else
#
#   ecr:BatchGetImage                on the SOURCE  read the manifest
#                                    on the TARGET  has it already been copied?
#   ecr:GetDownloadUrlForLayer       on the SOURCE  read each blob
#   ecr:BatchCheckLayerAvailability  on the TARGET  skip what is already there
#   ecr:InitiateLayerUpload / UploadLayerPart / CompleteLayerUpload
#                                    on the TARGET  write each missing blob
#   ecr:PutImage                     on the TARGET  write the manifest
#
# Production's deployer role carries exactly these (the source half is its
# `EnvPromoteReadSource` statement, rendered only when the stack created an
# `rc` alongside it). A copy that finds itself without them fails with an
# AccessDenied naming the repository — which is the legible outcome, not a
# wider role.
#
# Written for bash 3.2 (no associative arrays, no `mapfile`, no `${x^^}`) so
# `bash -n` on a developer's macOS is the same check CI runs.

set -euo pipefail

export LC_ALL=C

log() { echo "[churner-image-copy] $*"; }
die() { echo "[churner-image-copy] $*" >&2; exit 1; }

# GNU coreutils on a runner, `shasum` on a developer's macOS — the same
# fallback `scripts/environment-stack-digests.sh` carries, for the same
# reason: this script is executed by a test on both.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

SOURCE_REPO="${CHURNER_SOURCE_REPOSITORY:-}"
SOURCE_TAG="${CHURNER_SOURCE_TAG:-}"
TARGET_REPO="${CHURNER_TARGET_REPOSITORY:-}"
TARGET_TAG="${CHURNER_TARGET_TAG:-}"

# The size this script splits a blob at, and the ONLY reason it splits at all.
#
# `UploadLayerPart`'s `layerPartBlob` caps at 20,971,520 bytes AFTER base64
# encoding, and base64 costs a third — so the raw ceiling is ≈15 MiB, not 20,
# and an operator who "raised it to the documented cap" would break every
# promote of an image with a large layer. 10 MiB raw is ≈13.4 MiB encoded,
# comfortably inside it; the floor stops a value that would turn one layer
# into thousands of round trips.
PART_SIZE_MIN=1048576
PART_SIZE_MAX=15728640
PART_SIZE="${CHURNER_LAYER_PART_BYTES:-10485760}"

# --- Validation ---------------------------------------------------------------
#
# Every one of these lands in an `aws` argv. They come from the workflow,
# which derived them from its own inputs — checked anyway, before the first
# call, so a refusal copies nothing.
#
# `grep -Eqx`, not `grep -Eq '^…$'`: `grep` succeeds when ANY LINE matches, so
# an anchored pattern alone accepts `good\nevil` (fix-round-1 review, N7). The
# line-count check is the other half — `-x` still matches per line, so a value
# whose FIRST line is clean would otherwise pass.

REPO_RE='[a-z0-9][a-z0-9._/-]*'
TAG_RE='[A-Za-z0-9][A-Za-z0-9._-]*'
DIGEST_RE='sha256:[0-9a-f]{64}'

# one_line_matches <value> <extended-regex> — true only when the value is a
# single line AND that whole line matches.
one_line_matches() {
  [ "$(printf '%s' "$1" | wc -l | tr -d '[:space:]')" = "0" ] || return 1
  printf '%s' "$1" | grep -Eqx "$2"
}

one_line_matches "$SOURCE_REPO" "$REPO_RE" || die "CHURNER_SOURCE_REPOSITORY is not an ECR repository name (got '${SOURCE_REPO}')"
one_line_matches "$TARGET_REPO" "$REPO_RE" || die "CHURNER_TARGET_REPOSITORY is not an ECR repository name (got '${TARGET_REPO}')"
one_line_matches "$SOURCE_TAG" "$TAG_RE" || die "CHURNER_SOURCE_TAG is not a usable image tag (got '${SOURCE_TAG}')"
one_line_matches "$TARGET_TAG" "$TAG_RE" || die "CHURNER_TARGET_TAG is not a usable image tag (got '${TARGET_TAG}')"
one_line_matches "$PART_SIZE" '[0-9]+' || die "CHURNER_LAYER_PART_BYTES must be a number of bytes (got '${PART_SIZE}')"
[ "$PART_SIZE" -ge "$PART_SIZE_MIN" ] && [ "$PART_SIZE" -le "$PART_SIZE_MAX" ] \
  || die "CHURNER_LAYER_PART_BYTES must be between ${PART_SIZE_MIN} and ${PART_SIZE_MAX} bytes (got '${PART_SIZE}'); ECR's own cap is 20971520 bytes AFTER base64, which base64 reaches from ${PART_SIZE_MAX} raw"
[ "$SOURCE_REPO" != "$TARGET_REPO" ] || die "source and target repository are the same (${SOURCE_REPO}); a promote moves an image BETWEEN two created environments"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Every media type ECR can hand back for an image built by this platform's own
# CodeBuild project (a single-architecture Docker manifest) plus the index
# forms, so a customer whose build emits a multi-architecture image is copied
# rather than refused.
ACCEPTED_MEDIA_TYPES="application/vnd.docker.distribution.manifest.v2+json
application/vnd.oci.image.manifest.v1+json
application/vnd.docker.distribution.manifest.list.v2+json
application/vnd.oci.image.index.v1+json"

# `read_manifest <image-id>` — `imageTag=x` or `imageDigest=sha256:...`.
# Leaves the manifest in MANIFEST, its media type in MEDIA_TYPE and its own
# digest in SOURCE_DIGEST, because bash 3.2 has no way to return three
# strings. The digest comes from ECR's own answer rather than being hashed
# here: it is the identity the TARGET is then asked about.
MANIFEST=""
MEDIA_TYPE=""
SOURCE_DIGEST=""
read_manifest() {
  # shellcheck disable=SC2086
  response="$(aws ecr batch-get-image \
    --repository-name "$SOURCE_REPO" \
    --image-ids "$1" \
    --accepted-media-types $ACCEPTED_MEDIA_TYPES \
    --output json)" || die "could not read ${SOURCE_REPO} ${1}"

  failure="$(printf '%s' "$response" | jq -r '.failures[0].failureReason // empty')"
  [ -z "$failure" ] || die "${SOURCE_REPO} ${1}: ${failure}"

  MANIFEST="$(printf '%s' "$response" | jq -r '.images[0].imageManifest // empty')"
  [ -n "$MANIFEST" ] || die "${SOURCE_REPO} ${1} has no manifest — is the tag right?"
  MEDIA_TYPE="$(printf '%s' "$response" | jq -r '.images[0].imageManifestMediaType // empty')"
  # Older responses omit the field; the manifest names its own type.
  [ -n "$MEDIA_TYPE" ] || MEDIA_TYPE="$(printf '%s' "$MANIFEST" | jq -r '.mediaType // empty')"
  [ -n "$MEDIA_TYPE" ] || die "${SOURCE_REPO} ${1} carries no media type"
  SOURCE_DIGEST="$(printf '%s' "$response" | jq -r '.images[0].imageId.imageDigest // empty')"
  if [ -n "$SOURCE_DIGEST" ]; then
    one_line_matches "$SOURCE_DIGEST" "$DIGEST_RE" \
      || die "${SOURCE_REPO} ${1} reports an unusable manifest digest ('${SOURCE_DIGEST}')"
  fi
}

# `copy_blob <digest>` — the config blob or one layer. Skipped when the target
# already holds it, which is what makes re-promoting the same image (or one
# sharing a base layer with it) nearly free.
copy_blob() {
  digest="$1"
  one_line_matches "$digest" "$DIGEST_RE" || die "the source manifest names an unusable digest ('${digest}')"

  available="$(aws ecr batch-check-layer-availability \
    --repository-name "$TARGET_REPO" \
    --layer-digests "$digest" \
    --query 'layers[0].layerAvailability' --output text 2>/dev/null || printf 'UNAVAILABLE')"
  if [ "$available" = "AVAILABLE" ]; then
    log "${digest} is already in ${TARGET_REPO}"
    return 0
  fi

  url="$(aws ecr get-download-url-for-layer \
    --repository-name "$SOURCE_REPO" \
    --layer-digest "$digest" \
    --query 'downloadUrl' --output text)" || die "could not get a download URL for ${digest}"
  [ -n "$url" ] && [ "$url" != "None" ] || die "ECR returned no download URL for ${digest}"

  blob="${WORK}/blob"
  rm -f "$blob"
  curl -fsSL "$url" -o "$blob" || die "could not download ${digest}"

  size="$(wc -c < "$blob" | tr -d '[:space:]')"
  [ "$size" -gt 0 ] || die "${digest} downloaded as zero bytes"

  # The bytes are checked against the digest that NAMED them, here, before
  # they are uploaded. ECR validates at `complete-layer-upload` and would
  # reject a mismatch — but as an opaque `InvalidLayerException` after the
  # whole layer has been paid for, and after `set -e` has already carried
  # several successful calls. A local refusal names both digests and the
  # repository the bytes came from.
  actual="sha256:$(sha256_of "$blob")"
  [ "$actual" = "$digest" ] \
    || die "${SOURCE_REPO} served bytes that are not ${digest} (they hash to ${actual}) — refusing to upload them"

  upload_id="$(aws ecr initiate-layer-upload \
    --repository-name "$TARGET_REPO" \
    --query 'uploadId' --output text)" || die "could not start a layer upload in ${TARGET_REPO}"
  [ -n "$upload_id" ] && [ "$upload_id" != "None" ] || die "ECR returned no upload id for ${TARGET_REPO}"

  if [ "$size" -le "$PART_SIZE" ]; then
    aws ecr upload-layer-part \
      --repository-name "$TARGET_REPO" \
      --upload-id "$upload_id" \
      --part-first-byte 0 \
      --part-last-byte "$(( size - 1 ))" \
      --layer-part-blob "fileb://${blob}" >/dev/null \
      || die "could not upload ${digest}"
  else
    parts="${WORK}/parts"
    rm -rf "$parts"
    mkdir -p "$parts"
    # `split` with a plain byte count is the one form GNU and BSD spell the
    # same way; this script is executed by a test on macOS.
    split -b "$PART_SIZE" "$blob" "${parts}/part-"
    offset=0
    for part in "${parts}"/part-*; do
      part_size="$(wc -c < "$part" | tr -d '[:space:]')"
      last=$(( offset + part_size - 1 ))
      aws ecr upload-layer-part \
        --repository-name "$TARGET_REPO" \
        --upload-id "$upload_id" \
        --part-first-byte "$offset" \
        --part-last-byte "$last" \
        --layer-part-blob "fileb://${part}" >/dev/null \
        || die "could not upload part ${offset}-${last} of ${digest}"
      offset=$(( last + 1 ))
    done
    rm -rf "$parts"
  fi

  aws ecr complete-layer-upload \
    --repository-name "$TARGET_REPO" \
    --upload-id "$upload_id" \
    --layer-digests "$digest" >/dev/null \
    || die "could not complete the upload of ${digest}"
  rm -f "$blob"
  log "copied ${digest} (${size} bytes)"
}

# Every blob ONE manifest names: its config, then its layers. An index names
# neither — it names other manifests, handled below.
copy_blobs_of() {
  for digest in $(printf '%s' "$1" | jq -r '[(.config.digest // empty)] + [(.layers // [])[].digest] | .[]'); do
    copy_blob "$digest"
  done
}

# `put_manifest <manifest> <media-type> <--image-tag|--image-digest> <value>`
#
# `PutImage` raises `ImageAlreadyExistsException` when the manifest AND the
# tag are both unchanged since the last push — which is exactly the state a
# SECOND promote of the same sha finds, `TARGET_TAG` being the deterministic
# `prod-<sha>`. That second promote is not exotic: the copy runs BEFORE the
# production deploy, so "copy succeeded, deploy failed" is the most likely
# partial failure there is, and re-running `promote` with the same
# `confirm-short-sha` is the obvious response to it. Treated as success, by
# name — every other error still dies, carrying what ECR said.
put_manifest() {
  if ! err="$(aws ecr put-image \
      --repository-name "$TARGET_REPO" \
      --image-manifest "$1" \
      --image-manifest-media-type "$2" \
      "$3" "$4" 2>&1 >/dev/null)"; then
    case "$err" in
      *ImageAlreadyExistsException*)
        log "${TARGET_REPO} already holds this manifest under ${4}"
        ;;
      *)
        die "could not write the manifest into ${TARGET_REPO} (${4}): ${err}"
        ;;
    esac
  fi
}

log "copying ${SOURCE_REPO}:${SOURCE_TAG} to ${TARGET_REPO}:${TARGET_TAG}"

read_manifest "imageTag=${SOURCE_TAG}"
TOP_MANIFEST="$MANIFEST"
TOP_MEDIA_TYPE="$MEDIA_TYPE"
TOP_DIGEST="$SOURCE_DIGEST"

# Already there? Then a promote is a re-tag and a redeploy, and the bytes do
# not move twice. Asked of the TARGET by DIGEST — by tag would answer a
# different question ("is something called prod-<sha> here?"), and the two
# differ precisely when a tag was moved, which is the case where re-copying is
# the right thing to do.
COPY_NEEDED=1
if [ -n "$TOP_DIGEST" ]; then
  if aws ecr batch-get-image \
      --repository-name "$TARGET_REPO" \
      --image-ids "imageDigest=${TOP_DIGEST}" \
      --query 'images[0].imageId.imageDigest' --output text 2>/dev/null \
      | grep -Fqx "$TOP_DIGEST"; then
    COPY_NEEDED=0
    log "${TARGET_REPO} already holds ${TOP_DIGEST}; re-tagging it as ${TARGET_TAG}"
  fi
fi

if [ "$COPY_NEEDED" = "1" ]; then
  case "$TOP_MEDIA_TYPE" in
    *manifest.list*|*image.index*)
      # A multi-architecture image: the index names one manifest per platform,
      # and each of those has to exist in the target BEFORE the index that
      # points at it — `ecr:PutImage` validates an index the same way it
      # validates a manifest. Each child goes in by DIGEST and carries no tag
      # of its own; the tag belongs to the index.
      log "${SOURCE_TAG} is a multi-architecture index"
      for child in $(printf '%s' "$TOP_MANIFEST" | jq -r '(.manifests // [])[].digest'); do
        one_line_matches "$child" "$DIGEST_RE" || die "the index names an unusable digest ('${child}')"
        read_manifest "imageDigest=${child}"
        copy_blobs_of "$MANIFEST"
        put_manifest "$MANIFEST" "$MEDIA_TYPE" --image-digest "$child"
        log "copied the ${child} manifest"
      done
      ;;
    *)
      copy_blobs_of "$TOP_MANIFEST"
      ;;
  esac
fi

# Last, and only now: the tag a deploy will name. Everything it points at is
# already in the target, so a `promote` that dies halfway leaves no tag
# claiming to be a release that cannot be pulled.
put_manifest "$TOP_MANIFEST" "$TOP_MEDIA_TYPE" --image-tag "$TARGET_TAG"

log "churner-image-copied: ${TARGET_REPO}:${TARGET_TAG}"
