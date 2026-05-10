#!/bin/bash
set -e

# Check that we have a source URL
if [ -z "$SOURCE_URL" ] && [ -z "$GITHUB_URL" ]; then
  echo "Error: SOURCE_URL or GITHUB_URL environment variable is required"
  exit 1
fi

# Use SOURCE_URL if set, otherwise use GITHUB_URL
URL="${SOURCE_URL:-$GITHUB_URL}"

# Function to clone from a generic HTTPS git host (GitHub, GitLab, Gitea, etc.)
clone_from_git() {
  local url="$1"
  local branch=""
  local repo_path=""

  # Extract hostname dynamically from URL (may include user:pass@ for Gitea-style URLs)
  local git_host=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
  # Variant with any embedded credentials stripped — used for log lines and the
  # persisted remote URL so that PATs never leak into pod logs or .git/config.
  # When SOURCE_URL has no credentials, this is identical to git_host.
  local git_host_public=$(echo "$git_host" | sed -E 's|^[^@]+@||')

  # Check if URL contains a branch reference (e.g., /tree/branch_name)
  if [[ "$url" == *"/tree/"* ]]; then
    # Extract branch name (everything after /tree/)
    branch=$(echo "$url" | sed -E 's|.*/tree/||')
    # Extract repo path (everything between host/ and /tree/)
    repo_path=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed -E 's|/tree/.*||')
  else
    # No branch specified, extract the repository path
    # Supports: https://host/org/repo or https://host/org/repo/
    repo_path=$(echo "$url" | sed -E "s|https?://[^/]+/||" | sed 's|/$||')
  fi

  if [ -n "$branch" ]; then
    echo "Cloning repository: $repo_path (branch: $branch) from $git_host_public"
  else
    echo "Cloning repository: $repo_path from $git_host_public"
  fi

  # Clear the usercontent directory
  rm -rf /usercontent/* /usercontent/.[!.]*

  # Clone the repository (with optional branch)
  local clone_opts=""
  if [ -n "$branch" ]; then
    clone_opts="-b $branch"
  fi

  # Support GIT_TOKEN with GITHUB_TOKEN as fallback for backward compatibility
  local git_token="${GIT_TOKEN:-$GITHUB_TOKEN}"

  if [ -n "$git_token" ]; then
    echo "cloning https://***@${git_host_public}/${repo_path}.git"
    git clone $clone_opts "https://token:${git_token}@${git_host_public}/${repo_path}.git" /usercontent
  elif [ "$git_host" != "$git_host_public" ]; then
    # SOURCE_URL embeds credentials (e.g. Gitea: https://user:pass@host/...).
    # Clone with them in place but keep them out of the log line.
    echo "cloning https://***@${git_host_public}/${repo_path}.git"
    git clone $clone_opts "https://${git_host}/${repo_path}.git" /usercontent
  else
    echo "cloning https://${git_host_public}/${repo_path}.git"
    git clone $clone_opts "https://${git_host_public}/${repo_path}.git" /usercontent
  fi

  # Scrub PAT from origin remote — token must not persist to .git/config
  git -C /usercontent remote set-url origin "https://${git_host_public}/${repo_path}.git"
}

# Write commit metadata to a well-known file for platform visibility
write_commit_info() {
  local repo_dir="$1"
  if ! git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then return 0; fi
  local sha shortSha msg author date
  sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || return 0
  shortSha=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null) || return 0
  msg=$(git -C "$repo_dir" log -1 --format='%s' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g') || return 0
  author=$(git -C "$repo_dir" log -1 --format='%an' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g') || return 0
  date=$(git -C "$repo_dir" log -1 --format='%aI' 2>/dev/null) || return 0

  local recent="["
  local first=true
  while read -r c_sha; do
    [ -z "$c_sha" ] && continue
    local c_short c_msg c_author c_date
    c_short=$(git -C "$repo_dir" rev-parse --short "$c_sha" 2>/dev/null)
    c_msg=$(git -C "$repo_dir" log -1 --format='%s' "$c_sha" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
    c_author=$(git -C "$repo_dir" log -1 --format='%an' "$c_sha" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
    c_date=$(git -C "$repo_dir" log -1 --format='%aI' "$c_sha" 2>/dev/null)
    if [ "$first" = true ]; then first=false; else recent="$recent,"; fi
    recent="$recent{\"sha\":\"$c_sha\",\"shortSha\":\"$c_short\",\"message\":\"$c_msg\",\"author\":\"$c_author\",\"date\":\"$c_date\"}"
  done <<< "$(git -C "$repo_dir" log -5 --format='%H' 2>/dev/null)"
  recent="$recent]"

  printf '{"sha":"%s","shortSha":"%s","message":"%s","author":"%s","date":"%s","recentCommits":%s}\n' \
    "$sha" "$shortSha" "$msg" "$author" "$date" "$recent" \
    > "$repo_dir/.commit-info.json" 2>/dev/null || true
  echo "Commit info: $shortSha - $msg"
}

# Function to download from S3
download_from_s3() {
  local url="$1"

  echo "Downloading from S3: $url"

  # Clear the usercontent directory
  rm -rf /usercontent/*

  # Build aws s3 cp command
  local aws_cmd="aws s3 cp"
  if [ -n "$S3_ENDPOINT_URL" ]; then
    aws_cmd="$aws_cmd --endpoint-url $S3_ENDPOINT_URL"
  fi

  # Download the file
  $aws_cmd "$url" /tmp/source.zip

  # Extract the zip file
  unzip -o /tmp/source.zip -d /usercontent

  # Clean up
  rm /tmp/source.zip

  # Remove any existing venv or __pycache__ directories
  find /usercontent -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find /usercontent -type d -name ".venv" -exec rm -rf {} + 2>/dev/null || true
  find /usercontent -type d -name "venv" -exec rm -rf {} + 2>/dev/null || true
}

# Determine source type and fetch code
if [[ "$URL" == s3://* ]]; then
  download_from_s3 "$URL"
elif [[ "$URL" == https://* ]]; then
  clone_from_git "$URL"
  write_commit_info /usercontent
else
  echo "Error: Unsupported URL scheme. Use an HTTPS git URL or S3 URL (s3://...)"
  exit 1
fi

# Change to the usercontent directory
cd /usercontent

# Load environment variables from config service if configured
if [ -n "${OSC_ACCESS_TOKEN:-}" ] && [ -n "${CONFIG_SVC:-}" ]; then
  # Derive OSC environment from OSC_MCP_URL if OSC_ENV is not set explicitly
  if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
    _extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    OSC_ENV=${_extracted:-prod}
  fi
  # Token refresh block (matching birme/claude-runner#14)
  REFRESH_RESULT=$(curl -sf -X POST \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" \
    -H "x-pat-jwt: $OSC_ACCESS_TOKEN" 2>&1) && \
    OSC_ACCESS_TOKEN=$(echo "$REFRESH_RESULT" | jq -r '.token // empty') || true
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  config_env_output=$(npx -y @osaas/cli@latest web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" 2>&1)
  config_exit=$?
  if [ $config_exit -eq 0 ]; then
    valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=")
    if [ -n "$valid_exports" ]; then
      eval "$valid_exports"
      var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded $var_count environment variable(s)"
    fi
  else
    echo "[CONFIG] ERROR: Failed to load config (exit $config_exit): $config_env_output" >&2
  fi
fi

# Install Python dependencies
echo "Installing Python dependencies..."

if [ -f "pyproject.toml" ]; then
  echo "Found pyproject.toml, installing with pip..."
  pip install --no-cache-dir .
elif [ -f "requirements.txt" ]; then
  echo "Found requirements.txt, installing dependencies..."
  pip install --no-cache-dir -r requirements.txt
elif [ -f "setup.py" ]; then
  echo "Found setup.py, installing package..."
  pip install --no-cache-dir .
else
  echo "Warning: No requirements.txt, pyproject.toml, or setup.py found"
fi

# Install development dependencies if they exist
if [ -f "requirements-dev.txt" ]; then
  echo "Installing development dependencies..."
  pip install --no-cache-dir -r requirements-dev.txt
fi

# Run any setup scripts if present
if [ -f "setup.sh" ]; then
  echo "Running setup.sh..."
  chmod +x setup.sh
  ./setup.sh
fi

# Function to check if a package is in requirements
has_package() {
  local package="$1"
  if [ -f "requirements.txt" ] && grep -qi "^${package}[=<>!\[]" requirements.txt 2>/dev/null; then
    return 0
  fi
  if [ -f "requirements.txt" ] && grep -qi "^${package}$" requirements.txt 2>/dev/null; then
    return 0
  fi
  if [ -f "pyproject.toml" ] && grep -qi "\"${package}[=<>!\[\"]\|'${package}[=<>!\[']" pyproject.toml 2>/dev/null; then
    return 0
  fi
  if [ -f "pyproject.toml" ] && grep -qi "\"${package}\"\|'${package}'" pyproject.toml 2>/dev/null; then
    return 0
  fi
  return 1
}

# Function to find the ASGI/WSGI app location
find_app_module() {
  local app_type="$1"  # "asgi" or "wsgi"

  # Check for explicit asgi.py or wsgi.py
  if [ "$app_type" = "asgi" ] && [ -f "asgi.py" ]; then
    echo "asgi:app"
    return 0
  fi
  if [ "$app_type" = "wsgi" ] && [ -f "wsgi.py" ]; then
    echo "wsgi:app"
    return 0
  fi

  # Common entry point files to check
  local files=("main.py" "app.py" "application.py" "server.py" "api.py")

  for file in "${files[@]}"; do
    if [ -f "$file" ]; then
      # Try to find the app variable name
      local module="${file%.py}"

      # Look for common app variable patterns
      if grep -qE "^app\s*=" "$file" 2>/dev/null; then
        echo "${module}:app"
        return 0
      fi
      if grep -qE "^application\s*=" "$file" 2>/dev/null; then
        echo "${module}:application"
        return 0
      fi
      # For Flask, also check create_app pattern
      if grep -qE "def create_app\(" "$file" 2>/dev/null; then
        echo "${module}:create_app()"
        return 0
      fi
    fi
  done

  # Default fallback
  echo "main:app"
  return 0
}

# Function to detect and start the appropriate server
detect_and_start() {
  local port="${PORT:-8080}"

  echo "Auto-detecting application type..."

  # Check for FastAPI or Starlette (ASGI)
  if has_package "fastapi" || has_package "starlette"; then
    local app_module=$(find_app_module "asgi")
    echo "Detected FastAPI/Starlette application"
    echo "Starting with: uvicorn ${app_module} --host 0.0.0.0 --port ${port}"
    exec python -m uvicorn "${app_module}" --host 0.0.0.0 --port "${port}"
  fi

  # Check for Flask (WSGI)
  if has_package "flask"; then
    local app_module=$(find_app_module "wsgi")
    local module="${app_module%%:*}"
    local app_var="${app_module##*:}"

    echo "Detected Flask application"

    # Prefer gunicorn if available, otherwise use Flask's built-in server
    if has_package "gunicorn"; then
      echo "Starting with: gunicorn ${app_module} --bind 0.0.0.0:${port}"
      exec python -m gunicorn "${app_module}" --bind "0.0.0.0:${port}"
    else
      echo "Starting with: flask run --host 0.0.0.0 --port ${port}"
      export FLASK_APP="${module}:${app_var}"
      exec python -m flask run --host 0.0.0.0 --port "${port}"
    fi
  fi

  # Check for standalone gunicorn with config
  if has_package "gunicorn"; then
    if [ -f "gunicorn.conf.py" ] || [ -f "gunicorn_config.py" ]; then
      local config_file="gunicorn.conf.py"
      [ -f "gunicorn_config.py" ] && config_file="gunicorn_config.py"
      local app_module=$(find_app_module "wsgi")
      echo "Detected Gunicorn with config"
      echo "Starting with: gunicorn -c ${config_file} ${app_module}"
      exec python -m gunicorn -c "${config_file}" "${app_module}"
    fi
  fi

  # Check for plain Python script
  if [ -f "main.py" ]; then
    echo "Detected plain Python script (main.py)"
    echo "Starting with: python main.py"
    exec python main.py
  fi

  if [ -f "app.py" ]; then
    echo "Detected plain Python script (app.py)"
    echo "Starting with: python app.py"
    exec python app.py
  fi

  # Check for package with __main__.py
  for dir in */; do
    if [ -f "${dir}__main__.py" ]; then
      local package="${dir%/}"
      echo "Detected Python package with __main__.py"
      echo "Starting with: python -m ${package}"
      exec python -m "${package}"
    fi
  done

  echo "Error: Could not detect application type. Please specify a command."
  echo "Supported frameworks: FastAPI, Starlette, Flask, Gunicorn"
  echo "Or provide a main.py or app.py script."
  exit 1
}

echo "Starting application..."

# If no arguments or "auto" is passed, detect and start automatically
if [ $# -eq 0 ] || [ "$1" = "auto" ]; then
  detect_and_start
fi

# Execute the CMD
exec "$@"
