#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRAFT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/watcher-render"
RENDERER="$CRAFT_ROOT/bin/render-watcher-status.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_PASSED=$((TESTS_PASSED + 1)); echo "  ✓ $1"; }
fail() { TESTS_FAILED=$((TESTS_FAILED + 1)); echo "  ✗ $1 — $2"; }

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -q -- "$needle"; then
        pass "$label"
    else
        fail "$label" "expected to contain '$needle' in:
$haystack"
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -q -- "$needle"; then
        fail "$label" "did NOT expect '$needle' in:
$haystack"
    else
        pass "$label"
    fi
}

echo "render-watcher-status scaffolding"
if [[ -x "$RENDERER" ]]; then
    pass "renderer exists and is executable"
    TESTS_RUN=$((TESTS_RUN + 1))
fi

echo ""
echo "render-watcher-status: open-draft-pending"
out=$("$RENDERER" "$FIXTURES_DIR/open-draft-pending.state" "$FIXTURES_DIR/open-draft-pending.json")
assert_contains "shows PR title" "feat: add widget" "$out"
assert_contains "shows PR number" "PR #42" "$out"
assert_contains "shows DRAFT badge" "DRAFT" "$out"
assert_contains "shows lint check name" "lint" "$out"
assert_contains "shows unit-tests check name" "unit-tests" "$out"
assert_contains "shows mergeable status" "MERGEABLE" "$out"

echo ""
echo "render-watcher-status: open-ready-ci-failed"
out=$("$RENDERER" "$FIXTURES_DIR/open-ready-ci-failed.state" "$FIXTURES_DIR/open-ready-ci-failed.json")
assert_contains "shows fix PR title" "fix: cache invalidation" "$out"
assert_contains "shows READY badge" "READY" "$out"
assert_contains "shows integration check failure" "integration" "$out"
assert_contains "shows alice approved" "alice" "$out"
assert_contains "shows bob changes requested" "bob" "$out"
assert_contains "shows last action" "ci_failed" "$out"
assert_not_contains "no DRAFT badge on ready PR" "DRAFT" "$out"

echo ""
echo "render-watcher-status: merged"
out=$("$RENDERER" "$FIXTURES_DIR/merged.state" "$FIXTURES_DIR/merged.json")
assert_contains "shows MERGED badge" "MERGED" "$out"
assert_contains "shows last action mark_done" "state_mark_done" "$out"

echo ""
echo "render-watcher-status: missing files"
TESTS_RUN=$((TESTS_RUN + 1))
if "$RENDERER" /nonexistent.state /nonexistent.json > /tmp/render-err.out 2>&1; then
    fail "missing files exit non-zero" "renderer succeeded on missing files"
else
    pass "missing files exit non-zero"
fi

echo ""
echo "────────────────────────────"
echo "$TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
