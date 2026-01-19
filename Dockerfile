ARG PYTHON_IMAGE=python:3.12-alpine

FROM ${PYTHON_IMAGE}
RUN apk add --no-cache bash git aws-cli unzip
RUN apk add --no-cache \
    build-base \
    pkgconfig \
    python3-dev \
    freetype-dev \
    libpng-dev
WORKDIR /runner
COPY ./scripts ./
RUN chmod +x ./*.sh
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "auto" ]
