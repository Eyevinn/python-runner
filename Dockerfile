ARG PYTHON_IMAGE=python:3.12-alpine

FROM ${PYTHON_IMAGE}
RUN apk add --no-cache bash git aws-cli unzip
WORKDIR /runner
COPY ./scripts ./
RUN chmod +x ./*.sh
VOLUME /usercontent
ENV PORT=8080
ENTRYPOINT [ "/runner/docker-entrypoint.sh" ]
CMD [ "python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080" ]
