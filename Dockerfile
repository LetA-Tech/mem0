FROM python:3.12.12-slim-bookworm

ARG IMAGE_SOURCE="https://github.com/letainc/mem0"
ARG IMAGE_REVISION="unknown"
ARG IMAGE_VERSION="dev"

LABEL org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.title="LetA Mem0 Server Qdrant"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN groupadd --system --gid 10001 mem0 \
    && useradd --system --uid 10001 --gid mem0 --create-home --home-dir /home/mem0 mem0

WORKDIR /build

COPY pyproject.toml poetry.lock README.md LICENSE ./
COPY mem0 ./mem0
COPY server/requirements.txt ./server-requirements.txt

RUN python -m pip install --no-cache-dir --upgrade pip \
    && grep -vE '^mem0ai([<>= ].*)?$' server-requirements.txt > server-runtime-requirements.txt \
    && python -m pip install --no-cache-dir -r server-runtime-requirements.txt \
    && python -m pip install --no-cache-dir . \
    && rm -f server-requirements.txt server-runtime-requirements.txt

WORKDIR /app
COPY server ./server

RUN mkdir -p /app/history \
    && chown -R mem0:mem0 /app /home/mem0

USER mem0
WORKDIR /app/server

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3).read()" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
