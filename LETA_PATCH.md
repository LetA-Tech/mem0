# LetA Patch — Mem0 Server v2.0.2

LetA-owned, minimal patch on top of upstream `mem0ai/mem0` at tag `v2.0.2`.
Branch: `leta/v2.0.2-qdrant`.

This document is the source of truth for what LetA changed and why.
Anyone reviewing this fork starts here before reading code.

---

## Why a fork

Upstream Mem0 OSS REST server hardcodes pgvector as the vector store and ships
no `/health` endpoint. LetA's Agent Memory doctrine
(`mcfo-finsys/documents/00-doctrine/agent-memory-doctrine.md`) specifies
**Qdrant** as the canonical vector store and standard Docker liveness probes.

Two paths considered:

1. Pivot doctrine to pgvector — fast, but loses Qdrant Go SDK story and ties
   memory storage to the Postgres operational surface.
2. Maintain a small fork that adds Qdrant support via env vars — chosen.

Patch surface is intentionally tiny. The fork stays on a feature branch off the
upstream `v2.0.2` tag and is rebased forward only when LetA opts into a new
upstream release.

---

## Patch summary

Three additions to `server/main.py`. No deletions, no rewrites.

### 1. Vector store selector via `MEM0_VECTOR_STORE`

Adds env-var switch between pgvector (upstream default) and Qdrant.

```text
MEM0_VECTOR_STORE=pgvector    # upstream behaviour, no other changes
MEM0_VECTOR_STORE=qdrant      # LetA Agent Memory deploy
```

Qdrant config is built from:

| Env var | Required | Purpose |
|---|---|---|
| `QDRANT_URL` | preferred | e.g. `http://qdrant:6333` |
| `QDRANT_HOST` + `QDRANT_PORT` | fallback | if URL not set |
| `QDRANT_COLLECTION_NAME` | yes | follows LetA collection naming convention |
| `QDRANT_API_KEY` | optional | defense in depth on internal docker network |
| `QDRANT_EMBEDDING_MODEL_DIMS` | optional | sets dim explicitly; otherwise inferred from embedder |
| `QDRANT_ON_DISK` | optional, default `false` | sets `on_disk` flag on the Qdrant collection |

Pgvector path is preserved unchanged. Existing upstream users see no behaviour
change unless they explicitly set `MEM0_VECTOR_STORE=qdrant`.

### 2. `OPENAI_BASE_URL` pass-through

LLM and embedder use the OpenAI provider (upstream default). LetA routes calls
through OpenRouter via the OpenAI-compatible endpoint. The patch forwards
`OPENAI_BASE_URL` into both the LLM config and the embedder config when set.
Without `OPENAI_BASE_URL`, behaviour is identical to upstream.

### 3. `/healthz` and `/readyz` endpoints

Upstream's FastAPI app exposes no `/health` route. The Makefile probes
`/auth/setup-status`, which requires the dashboard / app DB to be initialized.
Docker compose health checks need a narrower contract.

Added:

- `GET /healthz` — unauthenticated. Returns `{"status":"ok"}` if the process is
  alive. No backend checks. Suitable for Docker liveness.
- `GET /readyz` — unauthenticated. Returns `{"status":"ready"}` if the app
  Postgres DB is reachable. Returns 503 + `{"status":"not_ready"}` otherwise.
  Vector store readiness is intentionally not probed (would burn vector ops on
  every healthcheck cycle); the LetA deploy artifact runs a separate smoke
  test post-`up`.

Both paths are added to `SKIPPED_REQUEST_LOG_PATHS` so they do not spam
`request_logs`.

---

## What did NOT change

- Upstream auth flow (`ADMIN_API_KEY`, `JWT_SECRET`, `AUTH_DISABLED`) is
  untouched.
- All upstream routes (`/configure`, `/memories`, `/search`, `/reset`, etc.)
  retained, with their existing `verify_auth` dependencies.
- Pgvector default path retained. Patch is purely additive.
- No upstream dependencies removed. The fork installs the same packages.
- No upstream test changes. New endpoints have new tests added under
  `server/tests/leta/` (TBD before first production deploy).

---

## Rebasing forward

Workflow when upstream cuts a new release:

```bash
git fetch upstream --tags
git checkout -b leta/<NEW-TAG>-qdrant <NEW-TAG>
git cherry-pick <patch-commit-on-leta/v2.0.2-qdrant>
# Resolve any conflicts on server/main.py
python -c "import ast; ast.parse(open('server/main.py').read())"
git push origin leta/<NEW-TAG>-qdrant
# Tag a LetA-owned release for the deploy pipeline:
git tag leta-v<NEW-TAG>-q1
git push origin leta-v<NEW-TAG>-q1
```

Tag naming: `leta-v<upstream-version>-q<patch-revision>`. Example:
`leta-v2.0.2-q1` = upstream 2.0.2 + LetA patch revision 1.

---

## Container build

Builds from upstream `server/Dockerfile` unchanged. CI workflow (see
`.github/workflows/build-and-push.yml`, added in this same patch branch) builds
on `leta-v*` tags and pushes to LetA's DigitalOcean Container Registry:

```text
registry.digitalocean.com/leta-container-registry/mcfo-mem0:leta-v2.0.2-q1
```

The `mcfo-finsys/agent-memory-server` deploy artifact references this image
via `AGENT_MEMORY_MEM0_IMAGE`.

---

## Verification before deploy

Run before pushing a new `leta-v*` tag:

```bash
# Syntax + config dry run
python -c "import ast; ast.parse(open('server/main.py').read())"

# Local boot with Qdrant
docker compose -f server/docker-compose.yaml up -d   # upstream compose still
                                                      # builds pgvector path
# OR use mcfo-finsys/agent-memory-server compose with this image tag set in
# AGENT_MEMORY_MEM0_IMAGE for the Qdrant path.
```

---

## Cross-references

- LetA Agent Memory doctrine:
  `mcfo-finsys/documents/00-doctrine/agent-memory-doctrine.md`
- Agent Memory ADR:
  `mcfo-finsys/documents/01-architecture/ADR-agent-memory-platform.md`
- Deploy artifact:
  `mcfo-finsys/agent-memory-server/`
- Platform deployment doctrine:
  `mcfo-finsys/documents/00-doctrine/deployment-doctrine.md`
