#!/usr/bin/env bash
# tests/test-entrypoint-subpath.sh
#
# Shell tests for the SUB_PATH monorepo subdirectory support added to
# scripts/docker-entrypoint.sh.
#
# Background:
#   In monorepo deployments, the Python application lives in a subdirectory
#   of the cloned repository (e.g., backend/service). Without SUB_PATH support,
#   the runner always starts from /usercontent, failing to find requirements.txt
#   or any entry-point file.
#
#   When SUB_PATH is set, the runner changes into /usercontent/$SUB_PATH before
#   pip install and detect_and_start(), so both operations see the correct CWD.
#   A missing directory produces a clear error message and exits 1.
#
# These tests combine grep-assertions (structural presence) with behavioral
# sandbox tests that simulate the SUB_PATH block in isolation using a temp dir.

ENTRYPOINT="scripts/docker-entrypoint.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: SUB_PATH guard is present in the entrypoint
# ---------------------------------------------------------------------------
if grep -qE '\[ -n "\$\{SUB_PATH:-\}" \]' "$ENTRYPOINT"; then
  pass "SUB_PATH guard '[ -n \"\${SUB_PATH:-}\" ]' is present in entrypoint"
else
  fail "SUB_PATH guard is missing from entrypoint"
fi

# ---------------------------------------------------------------------------
# Test 2: missing-directory error path exits 1
# ---------------------------------------------------------------------------
if grep -qE '! -d "\$WORK_DIR"' "$ENTRYPOINT" && grep -q 'exit 1' "$ENTRYPOINT"; then
  pass "missing-directory check '! -d \$WORK_DIR' and exit 1 are present"
else
  fail "missing-directory check or exit 1 is missing from SUB_PATH block"
fi

# ---------------------------------------------------------------------------
# Test 3: SUB_PATH block appears after 'cd /usercontent' and before
#         'Load environment variables from config service'
# ---------------------------------------------------------------------------
line_cd=$(grep -n '^cd /usercontent$' "$ENTRYPOINT" | head -1 | cut -d: -f1)
line_subpath=$(grep -n 'SUB_PATH support' "$ENTRYPOINT" | head -1 | cut -d: -f1)
line_config=$(grep -n 'Load environment variables from config service' "$ENTRYPOINT" | head -1 | cut -d: -f1)

if [ -n "$line_cd" ] && [ -n "$line_subpath" ] && [ -n "$line_config" ] && \
   [ "$line_cd" -lt "$line_subpath" ] && [ "$line_subpath" -lt "$line_config" ]; then
  pass "SUB_PATH block (line $line_subpath) is between cd /usercontent (line $line_cd) and config load (line $line_config)"
else
  fail "SUB_PATH block is not in the expected position: cd=$line_cd subpath=$line_subpath config=$line_config"
fi

# ---------------------------------------------------------------------------
# Test 4: behavioral — happy path: SUB_PATH set to an existing subdirectory
# ---------------------------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
mkdir -p "$TMPDIR_TEST/backend/service"

result4=$(bash -c "
  SUB_PATH='backend/service'
  USERCONTENT='$TMPDIR_TEST'
  if [ -n \"\${SUB_PATH:-}\" ]; then
    WORK_DIR=\"\$USERCONTENT/\$SUB_PATH\"
    if [ ! -d \"\$WORK_DIR\" ]; then
      echo 'Error: SUB_PATH directory does not exist'
      exit 1
    fi
    echo \"Using SUB_PATH: \$SUB_PATH (working directory: \$WORK_DIR)\"
    cd \"\$WORK_DIR\"
  fi
  echo \"cwd=\$(pwd)\"
" 2>&1)
exit4=$?

rm -rf "$TMPDIR_TEST"

if [ $exit4 -eq 0 ] && echo "$result4" | grep -q "Using SUB_PATH: backend/service" && \
   echo "$result4" | grep -q "cwd="; then
  pass "SUB_PATH happy path: cd into existing subdirectory succeeds"
else
  fail "SUB_PATH happy path failed (exit=$exit4): $result4"
fi

# ---------------------------------------------------------------------------
# Test 5: behavioral — error path: SUB_PATH set to a non-existent directory
# ---------------------------------------------------------------------------
TMPDIR_TEST2=$(mktemp -d)

result5=$(bash -c "
  SUB_PATH='nonexistent/path'
  USERCONTENT='$TMPDIR_TEST2'
  if [ -n \"\${SUB_PATH:-}\" ]; then
    WORK_DIR=\"\$USERCONTENT/\$SUB_PATH\"
    if [ ! -d \"\$WORK_DIR\" ]; then
      echo \"Error: SUB_PATH directory '\$WORK_DIR' does not exist\"
      exit 1
    fi
    cd \"\$WORK_DIR\"
  fi
  echo 'should not reach here'
" 2>&1)
exit5=$?

rm -rf "$TMPDIR_TEST2"

if [ $exit5 -eq 1 ] && echo "$result5" | grep -q "Error: SUB_PATH directory"; then
  pass "SUB_PATH error path: missing directory produces error message and exit 1"
else
  fail "SUB_PATH error path failed (exit=$exit5, expected 1): $result5"
fi

# ---------------------------------------------------------------------------
# Test 6: behavioral — SUB_PATH unset: no cd into subdirectory
# ---------------------------------------------------------------------------
TMPDIR_TEST3=$(mktemp -d)

result6=$(bash -c "
  unset SUB_PATH
  USERCONTENT='$TMPDIR_TEST3'
  cd \"\$USERCONTENT\"
  if [ -n \"\${SUB_PATH:-}\" ]; then
    WORK_DIR=\"\$USERCONTENT/\$SUB_PATH\"
    if [ ! -d \"\$WORK_DIR\" ]; then
      echo 'Error: SUB_PATH directory does not exist'
      exit 1
    fi
    cd \"\$WORK_DIR\"
    echo 'entered subpath'
  fi
  echo \"cwd=\$(pwd)\"
" 2>&1)
exit6=$?

rm -rf "$TMPDIR_TEST3"

if [ $exit6 -eq 0 ] && ! echo "$result6" | grep -q 'entered subpath'; then
  pass "SUB_PATH unset: block is skipped, working directory is unchanged"
else
  fail "SUB_PATH unset test produced unexpected output (exit=$exit6): $result6"
fi

# ---------------------------------------------------------------------------
# Test 7: behavioral — SUB_PATH set to empty string: block is skipped
# ---------------------------------------------------------------------------
TMPDIR_TEST4=$(mktemp -d)

result7=$(bash -c "
  SUB_PATH=''
  USERCONTENT='$TMPDIR_TEST4'
  cd \"\$USERCONTENT\"
  if [ -n \"\${SUB_PATH:-}\" ]; then
    WORK_DIR=\"\$USERCONTENT/\$SUB_PATH\"
    if [ ! -d \"\$WORK_DIR\" ]; then
      echo 'Error: SUB_PATH directory does not exist'
      exit 1
    fi
    cd \"\$WORK_DIR\"
    echo 'entered subpath'
  fi
  echo \"cwd=\$(pwd)\"
" 2>&1)
exit7=$?

rm -rf "$TMPDIR_TEST4"

if [ $exit7 -eq 0 ] && ! echo "$result7" | grep -q 'entered subpath'; then
  pass "SUB_PATH empty string: block is skipped, working directory is unchanged"
else
  fail "SUB_PATH empty string test produced unexpected output (exit=$exit7): $result7"
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
