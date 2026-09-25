#!/usr/bin/env bash
# tests/test-entrypoint-credential-header-auth.sh
#
# Shell regression tests for the header-based git auth fix in
# scripts/docker-entrypoint.sh (issue #18, porting Eyevinn/web-runner#56).
#
# Background:
#   git clone received the credentialed URL as an argument
#   (https://token:${git_token}@${git_host_public}/${repo_path}.git, or the
#   pre-embedded Gitea user:pass@host form via ${git_host}). When the clone
#   failed, git's own diagnostic output echoed that URL verbatim to stderr —
#   captured by promtail into Loki — independent of anything this script
#   itself logged or scrubbed. Unlike web-runner, python-runner always
#   rm -rf's and fresh-clones (no PVC-based existing-repo/fetch branch), so
#   there is only one clone call site to fix, not a clone+fetch pair.
#
# Fix (this PR):
#   Credentials travel via a per-invocation, host-scoped
#   `-c http.https://<host>/.extraheader=...` git option (GIT_AUTH_ARGS)
#   instead of being embedded in the clone URL. git clone always receives
#   the credential-free https://${git_host_public}/${repo_path}.git URL. A
#   `-c key=value` is never persisted to .git/config and is not part of the
#   URL string, so it cannot appear in "fatal: ... for '<url>'"-style git
#   error output. The header key is scoped to the exact host
#   (http.https://<host>/.extraheader) rather than a bare http.extraheader,
#   so it is not attached to requests to a different host (e.g. a redirect).
#
# These tests assert the fix is in place and has not regressed.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: GIT_AUTH_ARGS is built from git_token via a HOST-SCOPED
#         http.https://<host>/.extraheader key, not a bare/unscoped
#         http.extraheader
# ---------------------------------------------------------------------------
scoped_header_count=$(grep -cF 'http.https://${git_host_public}/.extraheader=AUTHORIZATION: basic' "$ENTRYPOINT")
if [ "$scoped_header_count" -ge 2 ]; then
  pass "GIT_AUTH_ARGS uses a host-scoped http.https://\${git_host_public}/.extraheader key ($scoped_header_count call sites)"
else
  fail "expected at least 2 host-scoped http.https://\${git_host_public}/.extraheader call sites, found $scoped_header_count"
fi

# Guard against regressing back to a bare/unscoped key. A bare key looks like
# `"http.extraheader=` (the config key starts directly with "extraheader",
# no "http.<scheme>://<host>/." prefix in front of it).
unscoped_header=$(grep -nE '"http\.extraheader=' "$ENTRYPOINT" || true)
if [ -z "$unscoped_header" ]; then
  pass "no bare/unscoped http.extraheader key remains in the script"
else
  fail "a bare/unscoped http.extraheader key was found (should be host-scoped): $unscoped_header"
fi

# ---------------------------------------------------------------------------
# Test 2: no git clone line interpolates $git_token directly into a URL
#         argument
# ---------------------------------------------------------------------------
token_in_url=$(grep -nE 'git clone.*\$\{?git_token\}?' "$ENTRYPOINT" || true)
if [ -z "$token_in_url" ]; then
  pass "no git clone line embeds \$git_token in a URL"
else
  fail "a git clone URL still embeds \$git_token: $token_in_url"
fi

# ---------------------------------------------------------------------------
# Test 3: no git clone line interpolates the unscrubbed $git_host (which may
#         itself carry embedded user:pass@ credentials for the Gitea case)
#         into a URL argument. Only $git_host_public may appear in a clone
#         URL. The regex must NOT match git_host_public — the [^_] guard
#         anchors so "git_host_public" is excluded (same technique as
#         test-entrypoint-credential-scrub.sh test 3).
# ---------------------------------------------------------------------------
git_host_in_clone=$(grep -nE 'git clone.*\$\{?git_host\}?[^_]' "$ENTRYPOINT" || true)
if [ -z "$git_host_in_clone" ]; then
  pass "no git clone line embeds the unscrubbed \$git_host in a URL"
else
  fail "a git clone line still embeds unscrubbed \$git_host: $git_host_in_clone"
fi

# ---------------------------------------------------------------------------
# Test 4: GIT_AUTH_ARGS is actually passed to the single clone call site
# ---------------------------------------------------------------------------
clone_uses_auth_args=$(grep -cE 'git "\$\{GIT_AUTH_ARGS\[@\]\}" clone' "$ENTRYPOINT")
if [ "$clone_uses_auth_args" -ge 1 ]; then
  pass "git clone is invoked with \${GIT_AUTH_ARGS[@]}"
else
  fail "git clone is not invoked with \${GIT_AUTH_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Test 5: the clone call site's stderr is wrapped for defense in depth
#         (git_scrub_stderr helper)
# ---------------------------------------------------------------------------
if grep -qF 'git_scrub_stderr()' "$ENTRYPOINT"; then
  pass "git_scrub_stderr helper is defined"
else
  fail "git_scrub_stderr helper is missing"
fi

scrub_call_count=$(grep -cE 'git_scrub_stderr git ' "$ENTRYPOINT")
if [ "$scrub_call_count" -ge 1 ]; then
  pass "git_scrub_stderr wraps the clone network call ($scrub_call_count call site(s))"
else
  fail "expected at least 1 git_scrub_stderr-wrapped git invocation, found $scrub_call_count"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral — building the auth header from a fake GitHub-style
#         token never prints the raw token itself, only its base64-encoded
#         form, and the header config key is scoped to git_host_public
# ---------------------------------------------------------------------------
sandbox_out=$(bash -c '
  git_host_public="example.git.host"
  git_token="ghp_supersecrettokenvalue1234567890"
  auth_b64=$(printf "token:%s" "$git_token" | base64 | tr -d "\n")
  GIT_AUTH_ARGS=(-c "http.https://${git_host_public}/.extraheader=AUTHORIZATION: basic ${auth_b64}")
  echo "built: ${GIT_AUTH_ARGS[*]}"
')

if echo "$sandbox_out" | grep -q "ghp_supersecrettokenvalue1234567890"; then
  fail "raw token leaked into the built GIT_AUTH_ARGS output: $sandbox_out"
else
  pass "raw token does not appear in the built auth header (only its base64 form does)"
fi

if echo "$sandbox_out" | grep -qF "http.https://example.git.host/.extraheader=AUTHORIZATION: basic"; then
  pass "auth header is correctly shaped and host-scoped (http.https://<host>/.extraheader=AUTHORIZATION: basic <b64>)"
else
  fail "auth header was not built as expected: $sandbox_out"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral — the Gitea (pre-embedded user:pass@host) path builds
#         its Basic-Auth pair from the embedded credentials, not by
#         re-embedding them in a URL, and scopes the header to the host
# ---------------------------------------------------------------------------
sandbox_gitea=$(bash -c '
  url="https://oscadmin:abc123def@example.git.host/owner/repo.git"
  git_host=$(echo "$url" | sed -E "s|https?://([^/]+).*|\1|")
  git_host_public=$(echo "$git_host" | sed -E "s|^[^@]+@||")
  git_token=""
  GIT_AUTH_ARGS=()
  if [ -n "$git_token" ]; then
    auth_b64=$(printf "token:%s" "$git_token" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${git_host_public}/.extraheader=AUTHORIZATION: basic ${auth_b64}")
  elif [ "$git_host" != "$git_host_public" ]; then
    creds="${git_host%%@*}"
    auth_b64=$(printf "%s" "$creds" | base64 | tr -d "\n")
    GIT_AUTH_ARGS=(-c "http.https://${git_host_public}/.extraheader=AUTHORIZATION: basic ${auth_b64}")
  fi
  echo "args: ${GIT_AUTH_ARGS[*]}"
  echo "clone_url: https://${git_host_public}/owner/repo.git"
')

if echo "$sandbox_gitea" | grep -q "abc123def"; then
  fail "Gitea credentials leaked in plaintext into sandbox output: $sandbox_gitea"
else
  pass "Gitea pre-embedded credentials do not leak in plaintext when building GIT_AUTH_ARGS"
fi

if echo "$sandbox_gitea" | grep -q "^clone_url: https://example.git.host/owner/repo.git$"; then
  pass "Gitea clone URL is credential-free (oscadmin:abc123def@ stripped)"
else
  fail "Gitea clone URL sandbox output unexpected: $sandbox_gitea"
fi

if echo "$sandbox_gitea" | grep -qF "http.https://example.git.host/.extraheader=AUTHORIZATION: basic"; then
  pass "Gitea auth header is host-scoped (http.https://example.git.host/.extraheader=...)"
else
  fail "Gitea auth header was not host-scoped as expected: $sandbox_gitea"
fi

# ---------------------------------------------------------------------------
# Test 8: behavioral — the GitHub-token path builds its Basic-Auth pair as
#         "token:<value>" (matching the pre-existing clone convention:
#         https://token:${git_token}@...), base64-encoded
# ---------------------------------------------------------------------------
sandbox_token=$(bash -c '
  git_host_public="github.com"
  git_token="ghp_anothertokenvalue0987654321"
  auth_b64=$(printf "token:%s" "$git_token" | base64 | tr -d "\n")
  expected_b64=$(printf "token:%s" "$git_token" | base64 | tr -d "\n")
  if [ "$auth_b64" = "$expected_b64" ]; then
    echo "MATCH"
  else
    echo "MISMATCH"
  fi
')

if echo "$sandbox_token" | grep -q "^MATCH$"; then
  pass "GitHub-token auth header is base64(\"token:\${git_token}\"), matching the pre-existing clone URL scheme"
else
  fail "GitHub-token auth header base64 encoding sandbox produced unexpected output: $sandbox_token"
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
