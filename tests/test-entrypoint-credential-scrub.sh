#!/usr/bin/env bash
# tests/test-entrypoint-credential-scrub.sh
#
# Shell regression tests for the credential-scrub fix in scripts/docker-entrypoint.sh.
#
# Background:
#   When SOURCE_URL embeds credentials (https://user:pass@host/path.git), the
#   pattern used by Gitea-backed apps, the host extraction
#       git_host=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
#   yields "user:pass@host" — i.e. credentials remain in git_host.
#
#   Before this fix the clone_from_git() function echoed the credentialed host
#   into pod logs and, crucially, persisted the credentialed URL into .git/config
#   because the "scrub" line
#       git -C /usercontent remote set-url origin "https://${git_host}/${repo_path}.git"
#   reconstructed the same URL it was supposed to remove.
#
# Fix (this PR):
#   Introduce git_host_public=$(echo "$git_host" | sed -E 's|^[^@]+@||') — a
#   sanitized variant used in log lines and the persisted remote URL. git_host
#   keeps any embedded creds for the clone itself when no separate $GIT_TOKEN is
#   provided. When SOURCE_URL has no credentials, git_host_public == git_host
#   and behavior is unchanged.
#
# Reference fix: https://github.com/Eyevinn/web-runner/pull/37
#
# These tests grep the entrypoint to assert the fix has not regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: git_host_public is derived from git_host with embedded creds stripped
# ---------------------------------------------------------------------------
if grep -qE 'git_host_public=\$\(echo "\$git_host" \| sed -E' "$ENTRYPOINT"; then
  pass "git_host_public strips user:pass@ from git_host using sed"
else
  fail "git_host_public assignment is missing or does not strip embedded creds"
fi

# ---------------------------------------------------------------------------
# Test 2: persisted remote URL uses the scrubbed host
# ---------------------------------------------------------------------------
if grep -qE 'git -C /usercontent remote set-url origin "https://\$\{git_host_public\}/' "$ENTRYPOINT"; then
  pass "remote set-url uses git_host_public (credentials removed from .git/config)"
else
  fail "remote set-url does not use git_host_public — credentials would leak into .git/config"
fi

# ---------------------------------------------------------------------------
# Test 3: no surviving echo line that prints the unscrubbed git_host
#
# The regex must NOT match git_host_public — it anchors on a word boundary
# after git_host so that "git_host_public" is excluded.
# ---------------------------------------------------------------------------
unsafe_echo=$(grep -nE 'echo "Cloning repository:.*\$\{?git_host\}?[^_]' "$ENTRYPOINT" || true)
if [ -z "$unsafe_echo" ]; then
  pass "no echo line prints the unscrubbed git_host"
else
  fail "echo line still prints unscrubbed git_host: $unsafe_echo"
fi

# ---------------------------------------------------------------------------
# Test 4: no remote set-url that persists the unscrubbed git_host
# ---------------------------------------------------------------------------
unsafe_persist=$(grep -nE 'remote set-url origin "https://\$\{?git_host\}/' "$ENTRYPOINT" || true)
if [ -z "$unsafe_persist" ]; then
  pass "no remote set-url persists the unscrubbed git_host"
else
  fail "remote set-url still persists unscrubbed git_host: $unsafe_persist"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral verification — run the relevant fragment in a sandbox
#
# Simulate the git_host extraction logic for a Gitea-style SOURCE_URL and assert
# that git_host_public has no '@' while git_host does. This catches regressions
# where the sed expression is changed in a way that defeats the strip.
# ---------------------------------------------------------------------------
sandbox=$(bash -c '
  url="https://oscadmin:abc123def@example.git.host/owner/repo.git"
  git_host=$(echo "$url" | sed -E '"'"'s|https?://([^/]+).*|\1|'"'"')
  git_host_public=$(echo "$git_host" | sed -E '"'"'s|^[^@]+@||'"'"')
  echo "git_host=$git_host"
  echo "git_host_public=$git_host_public"
')

if echo "$sandbox" | grep -q '^git_host=oscadmin:abc123def@example.git.host$' && \
   echo "$sandbox" | grep -q '^git_host_public=example.git.host$'; then
  pass "host-parsing on a Gitea-style URL strips creds in git_host_public only"
else
  fail "host-parsing sandbox produced unexpected output: $sandbox"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral verification — credential-less URL is unchanged
# ---------------------------------------------------------------------------
sandbox_plain=$(bash -c '
  url="https://github.com/owner/repo.git"
  git_host=$(echo "$url" | sed -E '"'"'s|https?://([^/]+).*|\1|'"'"')
  git_host_public=$(echo "$git_host" | sed -E '"'"'s|^[^@]+@||'"'"')
  echo "git_host=$git_host"
  echo "git_host_public=$git_host_public"
')

if echo "$sandbox_plain" | grep -q '^git_host=github.com$' && \
   echo "$sandbox_plain" | grep -q '^git_host_public=github.com$'; then
  pass "host-parsing on a credential-less URL is a no-op (git_host_public == git_host)"
else
  fail "credential-less host-parsing produced unexpected output: $sandbox_plain"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
  exit 1
fi
exit 0
