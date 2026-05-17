#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION="${VERSION:-}"
TAG="v${VERSION}"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

require_version() {
  [ -n "$VERSION" ] || fail "VERSION is required, for example VERSION=1.2.3"
  echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || fail "VERSION must be bare semver X.Y.Z without a leading v"
}

require_main() {
  local branch
  branch="$(git -C "$REPO_ROOT" branch --show-current)"
  [ "$branch" = "main" ] || fail "release-all must run from main"
}

require_clean_tree() {
  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    fail "working tree must be clean before release-all"
  fi

  if [ -n "$(git -C "$REPO_ROOT" status --short)" ]; then
    fail "working tree has untracked files before release-all"
  fi
}

require_synced_origin_main() {
  git -C "$REPO_ROOT" fetch origin main --tags >/dev/null 2>&1

  local head_sha origin_sha
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  origin_sha="$(git -C "$REPO_ROOT" rev-parse origin/main)"
  [ "$head_sha" = "$origin_sha" ] || fail "HEAD must equal origin/main before release-all"
}

require_new_tag() {
  if git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    fail "local tag ${TAG} already exists"
  fi

  if git -C "$REPO_ROOT" ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
    fail "remote tag ${TAG} already exists on origin"
  fi
}

run_deploy_check() {
  make -C "$REPO_ROOT" deploy-check
}

publish_release_tag() {
  git -C "$REPO_ROOT" push origin main
  git -C "$REPO_ROOT" tag -a "$TAG" -m "Release ${TAG}"
  git -C "$REPO_ROOT" push origin "$TAG"
}

require_version
require_main
require_clean_tree
require_synced_origin_main
run_deploy_check
require_new_tag
publish_release_tag

echo "Release ${TAG} published."
echo "CI will build and push the immutable mem0-server-qdrant image to DOCR."
echo "No deployment was performed."
