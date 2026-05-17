# LetA Patch — Mem0 Server v2.0.2

LetA-owned, minimal patch on top of upstream `mem0ai/mem0` at tag `v2.0.2`
(`9043fbf61e60c9e2f2e60ddddc849adebc273608`). Release artifacts are cut from
`main` with LetA semver tags (`vX.Y.Z`).

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

### 4. `/search` top-level scope → `filters` wrapper

Upstream Mem0 SDK v2 made `Memory.search()` reject top-level entity kwargs
(`user_id`, `agent_id`, `run_id`) and require `filters={"user_id": "..."}`.
The server's `SearchRequest` schema still exposes those fields at the top
level for ergonomic clients (curl, httpx, plain REST consumers). Without
a wrapper, every `/search` call returns 502 with `ValueError: Top-level
entity parameters ... are not supported`.

The patch in `server/main.py search_memories()`:

- Accepts both shapes from the client: top-level `user_id` etc. AND
  explicit `filters` object.
- Merges top-level scope fields into `filters` before calling the SDK.
- Existing client-supplied `filters` wins on key collision.

Identical client payloads work both before and after this patch:

```json
{"query": "x", "user_id": "service:mellions"}                              // legacy
{"query": "x", "filters": {"user_id": "service:mellions"}}                 // current
{"query": "x", "user_id": "service:mellions", "agent_id": "mellions"}      // mixed
```

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
- No upstream dependencies removed from source. The LetA production image does
  not install floating `mem0ai>=...` from PyPI; it installs the local patched
  package in this repo.
- Focused LetA regression tests live under `tests/server/test_leta_qdrant_config.py`.

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
# After review, release with the normal LetA artifact flow:
make release-all VERSION=X.Y.Z
```

Release tag naming: `vX.Y.Z`, created only by `make release-all VERSION=X.Y.Z`.
The Makefile validates branch, clean tree, `origin/main` sync, deploy checks,
and tag uniqueness before pushing `main` and the annotated release tag.

---

## Container build

Builds from the root `Dockerfile`, which installs the local patched Mem0 source
and the server runtime without installing floating `mem0ai>=...` from PyPI.
CI workflow `.github/workflows/release.yml` builds on semantic `vX.Y.Z` tags and
pushes to LetA's DigitalOcean Container Registry:

```text
registry.digitalocean.com/leta-container-registry/mem0-server-qdrant:vX.Y.Z
registry.digitalocean.com/leta-container-registry/mem0-server-qdrant:<git-sha>
```

The `mcfo-finsys/agent-memory-server` deploy artifact references this image
via `AGENT_MEMORY_MEM0_IMAGE`.

---

## Verification before deploy

Run before pushing a new release tag:

```bash
make lint
make test
make deploy-check
make docker-build VERSION=0.0.0-audit
```

`make release-all VERSION=X.Y.Z` runs `make deploy-check` again, creates an
annotated `vX.Y.Z` tag, pushes `main` and the tag, and stops. GitHub Actions
builds and pushes the immutable image only. It does not deploy to servers.

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
