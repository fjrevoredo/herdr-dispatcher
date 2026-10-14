#!/bin/bash
# Sourced by run.sh. Each case runs in its own private subshell.
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
assert_equal() { [ "$1" = "$2" ] || fail "expected [$1], got [$2]"; }
assert_json() { jq -e "$2" "$1" >/dev/null || fail "JSON assertion: $2"; }
# Dispatcher envelopes are not herdr's {id,result}/{id,error} responses.
assert_envelope() {
    jq -se 'length == 1' "$1" >/dev/null || fail 'expected one helper envelope'
    assert_json "$1" '
        keys == ["error","ok","outcome","result","schema_version"] and
        .schema_version == 1 and (.ok | type == "boolean") and
        (.result | type == "object") and
        if .ok then
            .error == null and (.outcome == "ok" or .outcome == "input-accepted")
        else
            (.outcome == "error" or .outcome == "not-submitted" or .outcome == "uncertain") and
            (.error | type == "object" and keys == ["code","message","retryable"] and
                (.code | type == "string" and test("^[a-z][a-z0-9_]*$")) and
                (.message | type == "string") and (.retryable | type == "boolean"))
        end'
}

sandbox() {
    TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/herdr-dispatcher-test.XXXXXX")
    TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
    export TEST_ROOT
    : > "$TEST_ROOT/.offline-test-root"
    trap 'cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/repo/runs" "$TEST_ROOT/work"
    export HOME="$TEST_ROOT/home"
    export HERDR_DISPATCHER_CONFIG="$TEST_ROOT/config.json"
    export FAKE_HERDR_LOG="$TEST_ROOT/calls.jsonl"
    export FAKE_HERDR_SCENARIO="$TEST_ROOT/scenario.json"
    export TEST_NOW='2026-10-14T14:00:00Z'
    export HERDR_ENV=1 HERDR_PANE_ID='wTest:p1'
    export PATH="$TEST_REPO/tests/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin"
    jq -n --arg repo "$TEST_ROOT/repo" --arg cwd "$TEST_ROOT/work" \
        '{schema_version:1,repo_path:$repo,dispatcher_kind:"pi",worker_kinds:{review:"pi",explore:"pi"},idle_ttl_seconds:900,ring_timeout_ms:30000,startup_timeout_ms:30000,trust_roots:[$cwd]}' \
        > "$HERDR_DISPATCHER_CONFIG"
    printf '[]\n' > "$FAKE_HERDR_SCENARIO"
    : > "$FAKE_HERDR_LOG"
    cd "$TEST_ROOT/work"
}

cleanup() {
    # Only remove the exact private directory created by sandbox.
    case "${TEST_ROOT:-}" in
        */herdr-dispatcher-test.*)
            if [ -f "$TEST_ROOT/.offline-test-root" ] && [ ! -L "$TEST_ROOT" ]; then
                rm -rf -- "$TEST_ROOT"
            fi ;;
    esac
}

# Queue entries: argv (exact array), status (0..255), stdout/stderr (JSON or
# text), optional delay_seconds. Entries are consumed once, in order.
# Later tests can rewrite this file to model changes between CLI calls.
scenario() { printf '%s\n' "$1" > "$FAKE_HERDR_SCENARIO"; }
fixture() { jq -c --arg key "$1" '.[$key]' "$TEST_REPO/tests/fixtures/herdr.json"; }
# TTL tests advance this value without sleeping. It is not a production clock override.
advance_time() { export TEST_NOW="$1"; }
