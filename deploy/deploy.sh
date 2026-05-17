#!/usr/bin/env bash
# ============================================================================
# LetA Mem0 — Developer Dev Loop deploy.sh (LOCAL ONLY)
# ============================================================================
# Pull/build, up, smoke-test the local dev stack. Not for production.
# Production deploy is mcfo-finsys/agent-memory-server/scripts/deploy.sh.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log()  { printf '[%s] %s\n' "$TS" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

[[ -r "$ENV_FILE" ]]     || fail ".env missing. Copy .env.example to .env first."
[[ -r "$COMPOSE_FILE" ]] || fail "docker-compose.yml missing in deploy/"

# Refuse to run if AUTH_DISABLED is not true and JWT_SECRET is missing — that
# combination means Mem0 will refuse to start. Surface the fix early.
auth_disabled="$(grep -E '^AUTH_DISABLED=' "$ENV_FILE" | tail -1 | cut -d= -f2- | tr '[:upper:]' '[:lower:]' | tr -d ' "')"
jwt_secret="$(grep -E '^JWT_SECRET=' "$ENV_FILE" | tail -1 | cut -d= -f2-)"
if [[ "$auth_disabled" != "true" && -z "$jwt_secret" ]]; then
    fail "JWT_SECRET unset and AUTH_DISABLED is not true. Mem0 server will refuse to boot."
fi

log "validating compose config"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config >/dev/null

log "building + pulling images"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" build
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull --ignore-buildable 2>/dev/null || true

log "starting stack"
docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d --remove-orphans

log "waiting for /healthz"
ATTEMPTS=24
for i in $(seq 1 "$ATTEMPTS"); do
    if curl -fsS -m 3 http://127.0.0.1:8000/healthz >/dev/null 2>&1; then
        log "mem0 /healthz ok"
        break
    fi
    [[ "$i" -eq "$ATTEMPTS" ]] && fail "mem0 /healthz never came up; check 'docker compose logs mem0'"
    sleep 5
done

log "waiting for /readyz"
for i in $(seq 1 12); do
    if curl -fsS -m 3 http://127.0.0.1:8000/readyz >/dev/null 2>&1; then
        log "mem0 /readyz ok"
        break
    fi
    [[ "$i" -eq 12 ]] && log "WARN: /readyz did not return 200; appdb may still be initializing"
    sleep 5
done

log "stack up. dev API: http://127.0.0.1:8000/docs"
log "tail: docker compose -f $COMPOSE_FILE logs -f mem0"
