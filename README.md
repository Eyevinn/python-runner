# Python Runner

Docker container that clones a GitHub repository containing a Python web application, installs dependencies, and runs the application.

## Usage

### From GitHub

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -e GITHUB_TOKEN=<token> \
  -p 8080:8080 \
  eyevinn/python-runner
```

### From S3 / MinIO

First, zip your project directory:

```bash
cd my-python-app && zip -r ../my-app.zip .
```

Upload the zip file to your S3 bucket, then run:

```bash
docker run --rm \
  -e SOURCE_URL=s3://bucket/my-app.zip \
  -e S3_ENDPOINT_URL=http://minio:9000 \
  -e AWS_ACCESS_KEY_ID=<access-key> \
  -e AWS_SECRET_ACCESS_KEY=<secret-key> \
  -p 8080:8080 \
  eyevinn/python-runner
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GITHUB_URL` | GitHub repository URL (e.g., `https://github.com/org/repo/`) |
| `GITHUB_TOKEN` | GitHub personal access token for private repositories |
| `SOURCE_URL` | S3 URL to a zipped application (e.g., `s3://bucket/app.zip`) |
| `S3_ENDPOINT_URL` | Custom S3 endpoint URL (for MinIO or other S3-compatible services) |
| `AWS_ACCESS_KEY_ID` | AWS/S3 access key ID |
| `AWS_SECRET_ACCESS_KEY` | AWS/S3 secret access key |
| `OSC_ACCESS_TOKEN` | Access token for Eyevinn Open Source Cloud config service |
| `CONFIG_SVC` | URL to config service endpoint |
| `PORT` | Port to run the application on (default: `8080`) |

## Supported Project Structures

The runner automatically detects and installs dependencies from:

- `pyproject.toml` - Modern Python packaging (PEP 517/518)
- `requirements.txt` - Traditional pip requirements file
- `setup.py` - Legacy setuptools configuration

If a `setup.sh` script is present in the repository root, it will be executed after dependency installation.

## Default Command

By default, the container runs:

```bash
python -m uvicorn main:app --host 0.0.0.0 --port 8080
```

This expects a FastAPI/Starlette application with an `app` object in `main.py`. You can override this by passing a custom command:

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -p 8080:8080 \
  eyevinn/python-runner \
  python app.py
```

Or for Flask applications:

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -p 8080:8080 \
  eyevinn/python-runner \
  flask run --host=0.0.0.0 --port=8080
```

Or for Gunicorn:

```bash
docker run --rm \
  -e GITHUB_URL=https://github.com/<org>/<repo>/ \
  -p 8080:8080 \
  eyevinn/python-runner \
  gunicorn -w 4 -b 0.0.0.0:8080 main:app
```

## Building

```bash
docker build -t eyevinn/python-runner .
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## About Eyevinn Technology

[Eyevinn Technology](https://www.eyevinntechnology.se) is an independent consultant firm specialized in video and streaming. We assist companies with their streaming and cloud strategies, including architecture design and implementation.

In addition to consulting services, we offer cloud-based products like the [Eyevinn Open Source Cloud](https://www.osaas.io) platform - a fully managed solution to launch open-source products in AWS infrastructure.

### Contact

- **Web**: https://www.eyevinntechnology.se
- **Community**: Join our Slack community [here](https://slack.osaas.io)
