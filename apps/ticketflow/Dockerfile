# syntax=docker/dockerfile:1
#
# Multi-stage, non-root. The base image is pinned by digest in hack/versions.env
# and passed in as a build argument, so the digest is spelled once in the repo.

ARG PYTHON_IMAGE=python:3.13-slim

# --- build ----------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS build

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Dependencies resolve from pyproject alone, so they cache independently of the
# source tree: editing a handler does not reinstall SQLAlchemy.
COPY pyproject.toml ./
COPY src ./src
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir .

# --- runtime --------------------------------------------------------------
FROM ${PYTHON_IMAGE} AS runtime

ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY --from=build /opt/venv /opt/venv

WORKDIR /app
COPY alembic.ini ./
COPY migrations ./migrations
COPY src ./src

# 65532 is the conventional "nonroot" uid. Declared numerically so the chart can
# assert runAsUser without depending on /etc/passwd inside the image.
USER 65532:65532

EXPOSE 8000

CMD ["uvicorn", "ticketflow.main:app", "--host", "0.0.0.0", "--port", "8000"]
