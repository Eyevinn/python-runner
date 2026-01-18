#!/bin/bash
set -e

# Check that we have a source URL
if [ -z "$SOURCE_URL" ] && [ -z "$GITHUB_URL" ]; then
  echo "Error: SOURCE_URL or GITHUB_URL environment variable is required"
  exit 1
fi

# Use SOURCE_URL if set, otherwise use GITHUB_URL
URL="${SOURCE_URL:-$GITHUB_URL}"

# Function to clone from GitHub
clone_from_github() {
  local url="$1"

  # Extract the repository path from the URL
  # Supports: https://github.com/org/repo or https://github.com/org/repo/
  local repo_path=$(echo "$url" | sed -E 's|https://github.com/||' | sed 's|/$||')

  echo "Cloning repository: $repo_path"

  # Clear the usercontent directory
  rm -rf /usercontent/*

  # Clone the repository
  if [ -n "$GITHUB_TOKEN" ]; then
    git clone "https://${GITHUB_TOKEN}@github.com/${repo_path}.git" /usercontent
  else
    git clone "https://github.com/${repo_path}.git" /usercontent
  fi
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
elif [[ "$URL" == *"github.com"* ]]; then
  clone_from_github "$URL"
else
  echo "Error: Unsupported URL scheme. Use GitHub URL or S3 URL (s3://...)"
  exit 1
fi

# Change to the usercontent directory
cd /usercontent

# Load environment variables from config service if configured
if [ -n "$OSC_ACCESS_TOKEN" ] && [ -n "$CONFIG_SVC" ]; then
  echo "Loading configuration from config service..."
  CONFIG_RESPONSE=$(curl -s -H "Authorization: Bearer $OSC_ACCESS_TOKEN" "$CONFIG_SVC")
  if [ $? -eq 0 ] && [ -n "$CONFIG_RESPONSE" ]; then
    # Export each key-value pair from the JSON response
    for key in $(echo "$CONFIG_RESPONSE" | python3 -c "import sys, json; print(' '.join(json.load(sys.stdin).keys()))" 2>/dev/null); do
      value=$(echo "$CONFIG_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('$key', ''))" 2>/dev/null)
      export "$key=$value"
    done
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

echo "Starting application..."

# Execute the CMD
exec "$@"
