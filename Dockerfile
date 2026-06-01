# =============================================================================
# TaskFlow demo web app — container image
# Mirrors the hrDemoWebApp setup: FastAPI on port 8000, SQLite under /data.
# =============================================================================
FROM python:3.12-slim

# curl is needed for the ECS/Docker health check (GET /health)
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

# Non-root user matching the EFS access point (uid/gid 1000) used by deploy.sh
RUN useradd -u 1000 -m appuser \
 && mkdir -p /data \
 && chown -R appuser:appuser /data /app
USER appuser

EXPOSE 8000

# Defaults can be overridden by the ECS task definition (TASKAPP_* env vars)
ENV TASKAPP_BIND_HOST=0.0.0.0 \
    TASKAPP_BIND_PORT=8000 \
    TASKAPP_DB_PATH=/data/taskflow.db \
    TASKAPP_LOG_LEVEL=INFO

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1

CMD ["python", "-m", "app.main"]
