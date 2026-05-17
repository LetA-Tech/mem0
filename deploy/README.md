# LetA Mem0 — `/deploy/` (Developer Dev Loop Only)

**Scope:** Developer-only dev loop for the LetA Mem0 fork.
**Not for production.** Production deploys live in
`mcfo-finsys/agent-memory-server/` per platform deployment doctrine.

---

## Two deploy surfaces, one source

```text
LetA Mem0 fork (this repo)
├── server/                # upstream Mem0 server (lightly patched, see LETA_PATCH.md)
├── deploy/                # <- THIS DIR: solo dev loop for the fork itself
│   ├── docker-compose.yml # Mem0 + Qdrant locally on the developer box
│   ├── .env.example       # dev env (AUTH_DISABLED=true acceptable here)
│   ├── deploy.sh          # pull + up + smoke-test, against local images
│   └── README.md          # this file
└── .github/workflows/
    └── leta-mem0-build-and-push.yml   # CI: tag leta-v* -> DOCR

mcfo-finsys/agent-memory-server/        # production deploy artifact, pulls from DOCR
├── compose/docker-compose.yml          # Mem0 + Qdrant on Server B
├── scripts/{setup-host,deploy,
│   health-check,backup,restore}.sh
└── ...
```

The fork builds **the image**. The platform repo deploys **the stack**.

---

## What `/deploy/` here is for

1. **Smoke-test a patch** before tagging.
2. **Reproduce a bug** on a developer machine with the same Mem0 + Qdrant pair
   that production runs.
3. **Validate `LETA_PATCH.md` claims** end-to-end (Qdrant vector store wiring,
   `OPENAI_BASE_URL` routing, `/healthz`, `/readyz`).

It is intentionally minimal. It does not implement UFW, backups, registry
auth, snapshot restore, or any of the production guardrails — those belong in
`mcfo-finsys/agent-memory-server/`.

---

## Dev loop

```bash
cd deploy/
cp .env.example .env
# Edit .env: at minimum set OPENAI_API_KEY (or OPENROUTER_API_KEY + OPENAI_BASE_URL)
docker compose build         # builds Mem0 image locally from server/Dockerfile
docker compose up -d
bash deploy.sh               # waits for /healthz then runs a smoke add+search
```

Tear down:

```bash
docker compose down -v
```

---

## Tagging a production image

Local dev loop satisfied → cut a LetA tag → CI publishes to DOCR:

```bash
# Branch leta/v2.0.2-qdrant holds the patch
git tag leta-v2.0.2-q1   # see LETA_PATCH.md for tag naming
git push origin leta-v2.0.2-q1
# GH Actions builds and pushes:
#   registry.digitalocean.com/leta-container-registry/mcfo-mem0:leta-v2.0.2-q1
```

Then in `mcfo-finsys/agent-memory-server/.env`:

```env
AGENT_MEMORY_MEM0_IMAGE=registry.digitalocean.com/leta-container-registry/mcfo-mem0:leta-v2.0.2-q1
```

…and run `mcfo-finsys/agent-memory-server/scripts/deploy.sh` on `LETA-SER-MEM0`.

---

## What `/deploy/` here MUST NOT do

- Run in production
- Open public ports (it intentionally publishes only on `127.0.0.1`)
- Share volumes or networks with the production deploy
- Hold real customer data
- Use `AUTH_DISABLED=true` outside the developer's local machine
