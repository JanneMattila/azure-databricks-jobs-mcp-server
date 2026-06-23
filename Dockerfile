# --- Build stage: install dependencies with uv ---
FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

# Install dependencies first (cached layer) using only the lock/manifest.
COPY pyproject.toml uv.lock /app/
RUN uv sync --frozen --no-install-project --no-dev

# Copy the source and install the project itself.
COPY src/ /app/src/

RUN uv sync --frozen --no-dev

# --- Runtime stage: minimal image with the prepared virtualenv ---
FROM python:3.12-slim-bookworm AS runtime

# Run as a non-root user.
RUN useradd --create-home --uid 10001 appuser

WORKDIR /app
COPY --from=builder --chown=appuser:appuser /app /app

# Put the virtualenv on PATH.
ENV PATH="/app/.venv/bin:$PATH"

# Bind to all interfaces inside the container; Container Apps maps ingress to this port.
ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8000

USER appuser
EXPOSE 8000

CMD ["databricks-jobs-mcp"]
