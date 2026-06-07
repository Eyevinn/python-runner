#!/usr/bin/env bash
# tests/test-entrypoint-fragment-branch.sh
#
# Shell regression tests for the #<ref> URL fragment branch support added to
# clone_from_git() in scripts/docker-entrypoint.sh.
#
# Background:
#   The SOURCE_URL field accepts an optional fragment suffix to pin a specific
#   Git ref, e.g.:
#       https://github.com/org/repo.git#feature-branch
#       https://github.com/org/repo.git#v1.2.3
#
#   The fragment must be stripped from the URL before any further path
#   extraction occurs — otherwise the repo_path includes "#<ref>" as a literal
#   string and the git clone URL becomes malformed.
#
#   If both a fragment AND a /tree/ path are present, /tree/ wins (overwrites
#   branch) because the /tree/ block runs after the fragment-strip block.
#
# These tests combine grep-assertions on the entrypoint source (to verify the
# fix is structurally present) with behavioral sandbox tests that execute just
# the relevant logic in isolation.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: the fragment-extraction block is present in the entrypoint
# ---------------------------------------------------------------------------
if grep -qE '\[\[ "\$url" == \*"#"\* \]\]' "$ENTRYPOINT"; then
  pass "fragment-extraction guard '[[ \$url == *#* ]]' is present in entrypoint"
else
  fail "fragment-extraction block is missing from entrypoint"
fi

# ---------------------------------------------------------------------------
# Test 2: branch is set from the fragment using ##*# (strip up to last #)
# ---------------------------------------------------------------------------
if grep -qE 'branch="\$\{url##\*#\}"' "$ENTRYPOINT"; then
  pass "branch assignment uses parameter expansion \${url##*#}"
else
  fail "branch assignment from fragment is missing or uses wrong syntax"
fi

# ---------------------------------------------------------------------------
# Test 3: URL is stripped of the fragment using %#* before /tree/ parsing
# ---------------------------------------------------------------------------
if grep -qE 'url="\$\{url%#\*\}"' "$ENTRYPOINT"; then
  pass "URL fragment-strip uses parameter expansion \${url%#*}"
else
  fail "URL fragment-strip is missing or uses wrong syntax"
fi

# ---------------------------------------------------------------------------
# Test 4: fragment block appears BEFORE the /tree/ block in the file
# ---------------------------------------------------------------------------
line_fragment=$(grep -n '\[\[ "\$url" == \*"#"\* \]\]' "$ENTRYPOINT" | head -1 | cut -d: -f1)
line_tree=$(grep -n '"/tree/"' "$ENTRYPOINT" | head -1 | cut -d: -f1)
if [ -n "$line_fragment" ] && [ -n "$line_tree" ] && [ "$line_fragment" -lt "$line_tree" ]; then
  pass "fragment block (line $line_fragment) appears before /tree/ block (line $line_tree)"
else
  fail "fragment block (line ${line_fragment:-?}) does not precede /tree/ block (line ${line_tree:-?})"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral — simple fragment sets branch and strips URL
# ---------------------------------------------------------------------------
result5=$(bash -c '
  url="https://github.com/org/repo.git#feature-branch"
  branch=""
  if [[ "$url" == *"#"* ]]; then
    branch="${url##*#}"
    url="${url%#*}"
  fi
  echo "branch=$branch"
  echo "url=$url"
')
if echo "$result5" | grep -q '^branch=feature-branch$' && \
   echo "$result5" | grep -q '^url=https://github.com/org/repo.git$'; then
  pass "fragment extraction: branch=feature-branch, URL has fragment stripped"
else
  fail "fragment extraction produced unexpected output: $result5"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral — tag fragment works the same way
# ---------------------------------------------------------------------------
result6=$(bash -c '
  url="https://github.com/org/repo.git#v1.2.3"
  branch=""
  if [[ "$url" == *"#"* ]]; then
    branch="${url##*#}"
    url="${url%#*}"
  fi
  echo "branch=$branch"
  echo "url=$url"
')
if echo "$result6" | grep -q '^branch=v1.2.3$' && \
   echo "$result6" | grep -q '^url=https://github.com/org/repo.git$'; then
  pass "tag fragment extraction: branch=v1.2.3, URL fragment stripped"
else
  fail "tag fragment extraction produced unexpected output: $result6"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral — URL without a fragment is unaffected
# ---------------------------------------------------------------------------
result7=$(bash -c '
  url="https://github.com/org/repo.git"
  branch=""
  if [[ "$url" == *"#"* ]]; then
    branch="${url##*#}"
    url="${url%#*}"
  fi
  echo "branch=$branch"
  echo "url=$url"
')
if echo "$result7" | grep -q '^branch=$' && \
   echo "$result7" | grep -q '^url=https://github.com/org/repo.git$'; then
  pass "URL without fragment leaves branch empty and URL unchanged"
else
  fail "URL without fragment produced unexpected output: $result7"
fi

# ---------------------------------------------------------------------------
# Test 8: behavioral — /tree/ wins over fragment (fragment sets branch first,
#         then /tree/ block overwrites it, which is the documented behavior)
# ---------------------------------------------------------------------------
result8=$(bash -c '
  url="https://github.com/org/repo/tree/main-branch#fragment-ref"
  branch=""
  # Fragment extraction (runs first)
  if [[ "$url" == *"#"* ]]; then
    branch="${url##*#}"
    url="${url%#*}"
  fi
  # /tree/ block (overwrites branch)
  if [[ "$url" == *"/tree/"* ]]; then
    branch=$(echo "$url" | sed -E '"'"'s|.*/tree/||'"'"')
  fi
  echo "branch=$branch"
')
if echo "$result8" | grep -q '^branch=main-branch$'; then
  pass "/tree/ block overwrites fragment branch (precedence: /tree/ > fragment)"
else
  fail "/tree/ precedence test produced unexpected output: $result8"
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
