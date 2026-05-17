import importlib
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient


REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_DIR = REPO_ROOT / "server"

SERVER_ENV_KEYS = (
    "ADMIN_API_KEY",
    "AUTH_DISABLED",
    "JWT_SECRET",
    "MEM0_VECTOR_STORE",
    "QDRANT_URL",
    "QDRANT_HOST",
    "QDRANT_PORT",
    "QDRANT_API_KEY",
    "QDRANT_COLLECTION_NAME",
    "QDRANT_EMBEDDING_MODEL_DIMS",
    "QDRANT_ON_DISK",
    "POSTGRES_HOST",
    "POSTGRES_PORT",
    "POSTGRES_DB",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_COLLECTION_NAME",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "OPENAI_BASE_URL",
    "MEM0_DEFAULT_LLM_MODEL",
    "MEM0_DEFAULT_EMBEDDER_MODEL",
    "MEM0_API_KEY",
)

SERVER_MODULES = (
    "auth",
    "db",
    "errors",
    "models",
    "rate_limit",
    "schemas",
    "server.main",
    "server_state",
    "telemetry",
)


def _purge_server_modules():
    for name in list(sys.modules):
        if name in SERVER_MODULES or name.startswith("routers"):
            del sys.modules[name]


def _load_server(monkeypatch, env):
    monkeypatch.syspath_prepend(str(SERVER_DIR))
    for key in SERVER_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    for key, value in env.items():
        monkeypatch.setenv(key, value)

    _purge_server_modules()
    memory = MagicMock()
    with patch("mem0.Memory.from_config", return_value=memory) as from_config:
        module = importlib.import_module("server.main")
    return module, from_config


def _option_b_env(**overrides):
    env = {
        "AUTH_DISABLED": "true",
        "MEM0_VECTOR_STORE": "qdrant",
        "QDRANT_URL": "http://qdrant:6333",
        "QDRANT_COLLECTION_NAME": "internal_coding_prod_mellions_memory_e3small_v1",
        "OPENROUTER_API_KEY": "test-openrouter-key",
        "OPENAI_BASE_URL": "https://openrouter.ai/api/v1",
        "MEM0_DEFAULT_LLM_MODEL": "openai/gpt-5-mini",
        "MEM0_DEFAULT_EMBEDDER_MODEL": "openai/text-embedding-3-small",
        "POSTGRES_HOST": "appdb",
        "POSTGRES_PORT": "5432",
        "POSTGRES_DB": "mem0_app",
        "POSTGRES_USER": "mem0",
        "POSTGRES_PASSWORD": "test-postgres-password",
    }
    env.update(overrides)
    return env


def _default_config(from_config):
    return from_config.call_args.args[0]


def test_qdrant_selector_builds_qdrant_vector_store_config(monkeypatch):
    _, from_config = _load_server(monkeypatch, _option_b_env())

    config = _default_config(from_config)
    assert config["vector_store"]["provider"] == "qdrant"
    assert config["vector_store"]["config"]["url"] == "http://qdrant:6333"
    assert config["vector_store"]["config"]["collection_name"].endswith("_e3small_v1")


def test_pgvector_config_is_not_used_when_qdrant_is_selected(monkeypatch):
    _, from_config = _load_server(
        monkeypatch,
        _option_b_env(
            POSTGRES_HOST="postgres-for-app-state-only",
            POSTGRES_COLLECTION_NAME="pgvector_should_not_be_used",
        ),
    )

    vector_store = _default_config(from_config)["vector_store"]
    assert vector_store["provider"] == "qdrant"
    assert "dbname" not in vector_store["config"]
    assert "pgvector_should_not_be_used" not in vector_store["config"].values()


def test_openrouter_base_url_is_propagated_to_llm_and_embedder(monkeypatch):
    _, from_config = _load_server(monkeypatch, _option_b_env())

    config = _default_config(from_config)
    assert config["llm"]["config"]["api_key"] == "test-openrouter-key"
    assert config["embedder"]["config"]["api_key"] == "test-openrouter-key"
    assert config["llm"]["config"]["openai_base_url"] == "https://openrouter.ai/api/v1"
    assert config["embedder"]["config"]["openai_base_url"] == "https://openrouter.ai/api/v1"
    assert config["llm"]["config"]["model"] == "openai/gpt-5-mini"
    assert config["embedder"]["config"]["model"] == "openai/text-embedding-3-small"


def test_healthz_returns_ok(monkeypatch):
    module, _ = _load_server(monkeypatch, _option_b_env())

    response = TestClient(module.app).get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_readyz_reports_ready_when_app_database_query_succeeds(monkeypatch):
    module, _ = _load_server(monkeypatch, _option_b_env())

    class ReadySession:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def execute(self, _statement):
            return None

    monkeypatch.setattr(module, "SessionLocal", lambda: ReadySession())

    response = TestClient(module.app).get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_readyz_reports_not_ready_when_app_database_query_fails(monkeypatch):
    module, _ = _load_server(monkeypatch, _option_b_env())

    class FailingSession:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def execute(self, _statement):
            raise RuntimeError("database unavailable")

    monkeypatch.setattr(module, "SessionLocal", lambda: FailingSession())

    response = TestClient(module.app).get("/readyz")
    assert response.status_code == 503
    assert response.json() == {"status": "not_ready"}


def test_mem0_cloud_api_key_is_not_part_of_canonical_server_config(monkeypatch):
    _, from_config = _load_server(monkeypatch, _option_b_env(MEM0_API_KEY="cloud-key"))

    config = _default_config(from_config)
    assert "cloud-key" not in repr(config)
    assert "MEM0_API_KEY" not in repr(config)
