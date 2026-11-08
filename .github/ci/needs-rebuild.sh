#!/bin/bash
# Which upstream release does this build use, and does the scheduled run have anything to publish?
#
#   .github/ci/needs-rebuild.sh <image> <upstream github repo>
#
# Writes to $GITHUB_OUTPUT: `version` (the upstream release tag without its leading v, which is
# the tag the base image carries: 1.4.1) and `build` (true or false).
#
# A push or a manual run always builds. A SCHEDULED run builds only when there is something to
# apply, because every image published as :latest restarts every server running it (FluxOS compares
# each app's tag digest every six hours and soft-redeploys onto a new one, players kicked), and a
# rebuild of unchanged inputs still gets a new digest. Two things make a scheduled run build:
#   1. upstream cut a new release: it differs from the com.runonflux.base-tag label of the
#      published :latest, or
#   2. main has a commit the published image does not have that touches an image INPUT (the
#      Dockerfile and what it COPYs). README, tests and .github changes do not count. A published
#      image with no revision label counts as pending. Needs the full git history.
set -euo pipefail

image="${1:?image}"
repo="${2:?upstream repo}"
out="${GITHUB_OUTPUT:-/dev/stdout}"

version="${FORCE_VERSION:-}"
if [ -z "${version}" ]; then
  version="$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" | jq -r .tag_name)"
fi
version="${version#v}"
[ -n "${version}" ] && [ "${version}" != null ] || { echo "::error::could not resolve a release of ${repo}"; exit 1; }
echo "version=${version}" >>"${out}"
echo "newest upstream release: ${version}"

if [ "${GITHUB_EVENT_NAME:-}" != "schedule" ]; then
  echo "build=true" >>"${out}"
  echo "a ${GITHUB_EVENT_NAME:-manual} run: building"
  exit 0
fi

labels="$(docker buildx imagetools inspect "${image}:latest" --format '{{json .Image}}' 2>/dev/null \
  | jq -r '.["linux/amd64"].config.Labels // .config.Labels // {}' 2>/dev/null || echo '{}')"
published_base="$(echo "${labels}" | jq -r '.["com.runonflux.base-tag"] // empty' 2>/dev/null || true)"
published_rev="$(echo "${labels}" | jq -r '.["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)"

if [ "${published_base}" != "${version}" ]; then
  echo "build=true" >>"${out}"
  echo "upstream moved (${published_base:-none} -> ${version}): building"
  exit 0
fi

if [ -z "${published_rev}" ] || ! git cat-file -e "${published_rev}^{commit}" 2>/dev/null; then
  echo "build=true" >>"${out}"
  echo "published image has no usable revision label: building once to label it"
  exit 0
fi

if git diff --quiet "${published_rev}" HEAD -- Dockerfile scripts; then
  echo "build=false" >>"${out}"
  echo "nothing new since ${published_rev}: not publishing"
else
  echo "build=true" >>"${out}"
  echo "image inputs changed since ${published_rev}: building"
fi
