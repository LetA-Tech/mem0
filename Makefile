.PHONY: help install install_all format sort lint docs build publish clean test docker-build deploy-check release-all compose-config

# Variables
ISORT_OPTIONS = --profile black
PROJECT_NAME := mem0ai
IMAGE_NAME ?= mem0-server-qdrant
REGISTRY ?= registry.digitalocean.com
REGISTRY_NAMESPACE ?= leta-container-registry
IMAGE_REPO ?= $(REGISTRY)/$(REGISTRY_NAMESPACE)/$(IMAGE_NAME)
VERSION ?=
IMAGE_VERSION = $(if $(VERSION),$(if $(filter v%,$(VERSION)),$(VERSION),v$(VERSION)),dev)
IMAGE_REVISION ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
LINT_PATHS ?= server/main.py tests/server/test_leta_qdrant_config.py
TEST_ARGS ?= tests/server/test_leta_qdrant_config.py
PYTHON ?= python3

# Default target
all: lint test

help:
	@echo "LetA Mem0 release-artifact commands"
	@echo ""
	@echo "Usage:"
	@echo "  make <target> [VERSION=X.Y.Z]"
	@echo ""
	@echo "Targets:"
	@echo "  make help                         Show this help"
	@echo "  make lint                         Run focused lint for LetA server/release tests"
	@echo "  make test                         Run focused LetA Option B server tests"
	@echo "  make docker-build VERSION=X.Y.Z   Build the LetA Mem0 server image locally"
	@echo "  make deploy-check                 Run static release/deploy artifact checks"
	@echo "  make release-all VERSION=X.Y.Z    Push main + vX.Y.Z tag; CI builds image and halts"
	@echo "  make compose-config               Render local dev compose config"
	@echo ""
	@echo "Release doctrine: CI builds immutable images only. It does not deploy."

install:
	hatch env create

install_all:
	pip install ruff==0.6.9 groq together boto3 litellm ollama chromadb weaviate weaviate-client sentence_transformers vertexai \
	            google-generativeai elasticsearch opensearch-py vecs "pinecone<7.0.0" pinecone-text faiss-cpu langchain-community \
							upstash-vector azure-search-documents langchain-memgraph langchain-neo4j langchain-aws rank-bm25 pymochow pymongo psycopg kuzu databricks-sdk valkey

# Format code with ruff
format:
	hatch run format

# Sort imports with isort
sort:
	hatch run isort mem0/

# Lint code with ruff
lint:
	@if command -v hatch >/dev/null 2>&1; then \
		hatch run ruff check $(LINT_PATHS); \
	elif $(PYTHON) -m ruff --version >/dev/null 2>&1; then \
		$(PYTHON) -m ruff check $(LINT_PATHS); \
	else \
		echo "ERROR: hatch or python ruff is required for make lint" >&2; \
		exit 127; \
	fi

docs:
	cd docs && mintlify dev

build:
	hatch build

publish:
	hatch publish

clean:
	rm -rf dist

test:
	@if command -v hatch >/dev/null 2>&1; then \
		hatch run pytest $(TEST_ARGS); \
	elif $(PYTHON) -m pytest --version >/dev/null 2>&1; then \
		$(PYTHON) -m pytest $(TEST_ARGS); \
	else \
		echo "ERROR: hatch or python pytest is required for make test" >&2; \
		exit 127; \
	fi

docker-build:
	@test -n "$(VERSION)" || (echo "VERSION is required. Usage: make docker-build VERSION=0.0.0-audit" >&2; exit 1)
	docker build \
		--build-arg IMAGE_SOURCE="https://github.com/letainc/mem0" \
		--build-arg IMAGE_REVISION="$(IMAGE_REVISION)" \
		--build-arg IMAGE_VERSION="$(IMAGE_VERSION)" \
		-t "$(IMAGE_NAME):$(VERSION)" \
		-t "$(IMAGE_REPO):$(VERSION)" \
		-f Dockerfile .

deploy-check:
	@./scripts/deploy-check.sh

release-all:
	@VERSION="$(VERSION)" ./scripts/release-all.sh

compose-config:
	docker compose --env-file deploy/.env.example -f deploy/docker-compose.yml config

test-py-3.10:
	hatch run dev_py_3_10:test

test-py-3.11:
	hatch run dev_py_3_11:test

test-py-3.12:
	hatch run dev_py_3_12:test
