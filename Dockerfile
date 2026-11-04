ARG PYTHON_IMAGE=python:3.12-slim

FROM ${PYTHON_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    awscli \
    unzip \
    build-essential \
    pkg-config \
    python3-dev \
    libfreetype6-dev \
    libpng-dev \
    curl \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js (required for OSC CLI). Pinned to the 24.x line (not setup_lts.x)
# for CVE-2026-111497; the build fails below the fixed release 24.22.1.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && node -e 'const [M,m,p]=process.versions.node.split(".").map(Number); if (M!==24||m<22||(m===22&&p<1)) { console.error("Node "+process.versions.node+" is below 24.22.1 (CVE-2026-111497)"); process.exit(1) }' \
    && node --version \
    && rm -rf /var/lib/apt/lists/*

# Run as a non-root user. Python packages go into a virtualenv owned by that
# user (/opt/venv, first on PATH), so the entrypoint's `pip install` calls and
# any `pip install` in a tenant setup.sh keep working without root.
RUN useradd --create-home --uid 1000 --shell /bin/bash runner \
    && python -m venv /opt/venv \
    && mkdir -p /usercontent \
    && chown -R runner:runner /opt/venv /usercontent
ENV VIRTUAL_ENV=/opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install --no-cache-dir gradio && chown -R runner:runner /opt/venv

# Version of @osaas/cli that docker-entrypoint.sh runs via npx. This is the
# single place the version is pinned; bump it here.
ENV OSAAS_CLI_VERSION=4.35.0
WORKDIR /runner
COPY ./scripts ./
RUN chmod +x ./*.sh
USER runner
ENV HOME=/home/runner
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "auto" ]
