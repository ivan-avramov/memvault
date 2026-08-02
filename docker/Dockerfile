FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git openssh-client fswatch ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p -m 0700 /root/.ssh \
    && ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

RUN uv tool install basic-memory \
    && uv tool install mcpo --with "mcp<2"
ENV PATH="/root/.local/bin:$PATH"

COPY scripts/watch-commit.sh scripts/push-timer.sh /opt/memvault/scripts/
COPY docker/entrypoint.sh /opt/memvault/entrypoint.sh
RUN chmod +x /opt/memvault/scripts/*.sh /opt/memvault/entrypoint.sh

ENV BASIC_MEMORY_CONFIG_DIR=/data
ENV VAULT_DIR=/vault
ENV MCPO_PORT=8000
EXPOSE 8000

ENTRYPOINT ["/opt/memvault/entrypoint.sh"]
