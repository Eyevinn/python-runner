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
    && rm -rf /var/lib/apt/lists/*
RUN pip install gradio

WORKDIR /runner
COPY ./scripts ./
RUN chmod +x ./*.sh
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "auto" ]
