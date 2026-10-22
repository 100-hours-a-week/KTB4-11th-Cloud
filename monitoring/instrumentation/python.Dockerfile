# syntax=docker/dockerfile:1
ARG APPLICATION_IMAGE
FROM ghcr.io/astral-sh/uv:0.13.5 AS installer
FROM ${APPLICATION_IMAGE}
USER root
COPY --from=installer /uv /usr/local/bin/uv
COPY python-requirements.txt /tmp/otel-requirements.txt
# Refuse changes to installed application dependencies. Install only the agent
# and its missing dependencies into the application's existing virtualenv.
RUN uv pip freeze --python /app/.venv/bin/python > /tmp/application-constraints.txt \
    && uv pip install --python /app/.venv/bin/python \
         --constraint /tmp/application-constraints.txt \
         --require-hashes --requirement /tmp/otel-requirements.txt \
    && uv pip check --python /app/.venv/bin/python \
    && rm /tmp/application-constraints.txt /tmp/otel-requirements.txt
USER app
ENTRYPOINT ["/app/.venv/bin/opentelemetry-instrument"]
CMD ["market-http"]
