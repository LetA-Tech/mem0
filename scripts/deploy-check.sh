#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_ENV="${REPO_ROOT}/deploy/.env.example"
DEPLOY_COMPOSE="${REPO_ROOT}/deploy/docker-compose.yml"
RELEASE_WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"

fail() {
  echo "ERROR: $1" >&2
  exit 1
}

warn() {
  echo "WARN: $1" >&2
}

require_file() {
  local path="$1"
  [ -f "$path" ] || fail "required file not found: ${path}"
}

require_executable() {
  local path="$1"
  [ -x "$path" ] || fail "required executable not found: ${path}"
}

env_value() {
  local key="$1"
  awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*#" { next }
    $1 == key {
      value = $0
      sub("^[^=]*=", "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
    }
  ' "$DEPLOY_ENV" | tail -1
}

require_make_target() {
  local target="$1"
  grep -Eq "^${target}:" "${REPO_ROOT}/Makefile" || fail "Makefile missing target: ${target}"
}

require_env_key() {
  local key="$1"
  grep -Eq "^${key}=" "$DEPLOY_ENV" || fail "deploy/.env.example missing ${key}"
}

require_no_workflow_deploy_steps() {
  if grep -R -n -E 'appleboy/(ssh|scp)|ssh-action|scp-action|rsync|^[[:space:]]+(ssh|scp|rsync)[[:space:]]' \
      "${REPO_ROOT}/.github/workflows" 2>/dev/null | grep -vE '^\s*#' >/dev/null; then
    fail "GitHub Actions workflows must not contain SSH, SCP, rsync, or server-deploy steps"
  fi
}

require_no_canonical_mem0_cloud() {
  if grep -R -n 'MEM0_API_KEY' \
      "${REPO_ROOT}/Dockerfile" \
      "${REPO_ROOT}/Makefile" \
      "${REPO_ROOT}/scripts/release-all.sh" \
      "${REPO_ROOT}/deploy" \
      "$RELEASE_WORKFLOW" \
      "${REPO_ROOT}/LETA_PATCH.md" >/dev/null 2>&1; then
    fail "canonical LetA release/deploy artifacts must not use MEM0_API_KEY"
  fi
}

require_no_public_compose_binds() {
  if grep -nE '(^|[^0-9])0\.0\.0\.0:' "$DEPLOY_COMPOSE" >/dev/null; then
    fail "deploy compose must not publish host ports on 0.0.0.0"
  fi

  if grep -nE 'host_ip:[[:space:]]*"?0\.0\.0\.0"?' "$DEPLOY_COMPOSE" >/dev/null; then
    fail "deploy compose must not use host_ip 0.0.0.0"
  fi

  if grep -nE 'published:[[:space:]]*"?6333"?|published:[[:space:]]*"?6334"?|published:[[:space:]]*"?5432"?|published:[[:space:]]*"?6379"?' \
      "$DEPLOY_COMPOSE" >/dev/null; then
    fail "deploy compose must not publish Qdrant, Postgres, or Redis ports"
  fi
}

require_no_latest_release_images() {
  if grep -R -n -E '(:latest|TAG:-latest)' \
      "${REPO_ROOT}/Dockerfile" "$RELEASE_WORKFLOW" "$DEPLOY_COMPOSE" >/dev/null; then
    fail "production release artifacts must not use latest image tags"
  fi
}

require_collection_suffix_matches_model() {
  local model collection
  model="$(env_value "MEM0_DEFAULT_EMBEDDER_MODEL" | tr '[:upper:]' '[:lower:]')"
  collection="$(env_value "QDRANT_COLLECTION_NAME" | tr '[:upper:]' '[:lower:]')"

  [ -n "$model" ] || fail "MEM0_DEFAULT_EMBEDDER_MODEL is missing in deploy/.env.example"
  [ -n "$collection" ] || fail "QDRANT_COLLECTION_NAME is missing in deploy/.env.example"

  case "$model" in
    openai/text-embedding-3-small|text-embedding-3-small)
      [[ "$collection" =~ _e3small_v1$ ]] \
        || fail "openai/text-embedding-3-small requires QDRANT_COLLECTION_NAME suffix _e3small_v1"
      ;;
    nvidia/llama-nemotron-embed-vl-1b-v2:free|*llama-nemotron-embed-vl-1b-v2*|*nemotron*)
      [[ "$collection" =~ _nemotronvl_v1$ ]] \
        || fail "nvidia/llama-nemotron-embed-vl-1b-v2:free requires QDRANT_COLLECTION_NAME suffix _nemotronvl_v1"
      ;;
    *)
      fail "unknown embedding model '${model}'; add an explicit collection suffix guard"
      ;;
  esac
}

require_release_workflow_shape() {
  require_file "$RELEASE_WORKFLOW"
  grep -q 'mem0-server-qdrant' "$RELEASE_WORKFLOW" || fail "release workflow must publish mem0-server-qdrant"
  grep -q 'registry.digitalocean.com' "$RELEASE_WORKFLOW" || fail "release workflow must target DOCR"
  grep -q 'docker/build-push-action' "$RELEASE_WORKFLOW" || fail "release workflow must build Docker image"
  grep -q 'push: true' "$RELEASE_WORKFLOW" || fail "release workflow must push image"
  grep -q 'github.sha' "$RELEASE_WORKFLOW" || fail "release workflow must tag image with git SHA"
  grep -Eq 'v\*?\.\*?\.\*?|v\[0-9\]' "$RELEASE_WORKFLOW" || fail "release workflow must be tag-driven"
}

require_no_tracked_env_secrets() {
  local tracked_env
  tracked_env="$(git -C "$REPO_ROOT" ls-files | grep -E '(^|/)\.env$' || true)"
  [ -z "$tracked_env" ] || fail "tracked .env file is forbidden: ${tracked_env}"
}

require_file "${REPO_ROOT}/Dockerfile"
require_file "${REPO_ROOT}/.dockerignore"
require_file "${REPO_ROOT}/Makefile"
require_file "${REPO_ROOT}/LETA_PATCH.md"
require_file "$DEPLOY_ENV"
require_file "$DEPLOY_COMPOSE"
require_executable "${REPO_ROOT}/scripts/release-all.sh"
require_file "${REPO_ROOT}/tests/server/test_leta_qdrant_config.py"

require_make_target help
require_make_target test
require_make_target lint
require_make_target docker-build
require_make_target deploy-check
require_make_target release-all

bash -n "${REPO_ROOT}/scripts/release-all.sh"
bash -n "${REPO_ROOT}/scripts/deploy-check.sh"

require_env_key MEM0_VECTOR_STORE
require_env_key QDRANT_URL
require_env_key QDRANT_COLLECTION_NAME
require_env_key ADMIN_API_KEY
require_env_key JWT_SECRET
require_env_key POSTGRES_PASSWORD
require_env_key OPENROUTER_API_KEY
require_env_key OPENAI_API_KEY

[ "$(env_value MEM0_VECTOR_STORE)" = "qdrant" ] || fail "MEM0_VECTOR_STORE must be qdrant in canonical deploy env"
[[ "$(env_value QDRANT_URL)" == http://qdrant:* ]] || fail "QDRANT_URL must point to the private qdrant service"

require_collection_suffix_matches_model
require_no_canonical_mem0_cloud
require_no_public_compose_binds
require_no_latest_release_images
require_release_workflow_shape
require_no_workflow_deploy_steps
require_no_tracked_env_secrets

if command -v docker >/dev/null 2>&1; then
  docker compose --env-file "$DEPLOY_ENV" -f "$DEPLOY_COMPOSE" config >/dev/null
else
  warn "docker not found; skipped docker compose config validation"
fi

echo "deploy-check: ok"
