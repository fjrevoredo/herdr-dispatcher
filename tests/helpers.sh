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
    umask 077
    mkdir -p "$TEST_ROOT/home" "$TEST_ROOT/repo/runs" "$TEST_ROOT/work" "$TEST_ROOT/tmp"
    export TMPDIR="$TEST_ROOT/tmp"
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

# Queue entries use exact argv and are consumed once, in order.
# Explicit persistent read rules are matched by argv, not consumed.
# Rewrite scenarios only when no fake CLI call is active.
scenario() { printf '%s\n' "$1" > "$FAKE_HERDR_SCENARIO"; }
fixture() { jq -c --arg key "$1" '.[$key]' "$TEST_REPO/tests/fixtures/herdr.json"; }
# TTL tests advance this value without sleeping. It is not a production clock override.
advance_time() { export TEST_NOW="$1"; }

# Run the actual executable and retain both the envelope and exit code.
helper() {
    HELPER_STATUS=0
    "$TEST_REPO/bin/$1" "${@:2}" > "$TEST_ROOT/helper.json" 2> "$TEST_ROOT/helper.err" || HELPER_STATUS=$?
    assert_envelope "$TEST_ROOT/helper.json"
}
expect_status() {
    if [ "$1" != "$HELPER_STATUS" ]; then
        printf 'Helper response: ' >&2
        jq -c . "$TEST_ROOT/helper.json" >&2
        fail "expected exit $1, got $HELPER_STATUS"
    fi
}
state_fixture() {
    jq -n --arg root "$TEST_ROOT" --arg config "$HERDR_DISPATCHER_CONFIG" --arg at "$TEST_NOW" \
        --arg id "${1:-20261014T140000Z-0123456789abcdef}" -f "$TEST_REPO/tests/fixtures/state.jq"
}
markdown() { printf '%s\n%s\n%s\n%s\n' '---' "$2" '---' "$3" > "$1"; }
state_setup() {
    RUN_ID=20261014T140000Z-0123456789abcdef
    # Shared with state.sh, which is sourced by the runner.
    # shellcheck disable=SC2034
    RUN_TWO=20261014T140000Z-fedcba9876543210
    RUN_ROOT="$TEST_ROOT/repo/runs"
    mkdir -p "$RUN_ROOT/.locks" "$RUN_ROOT/.staging" "$RUN_ROOT/.workers" "$RUN_ROOT/.launches" "$TEST_ROOT/repo/roles"
    state_fixture > "$TEST_ROOT/records.json"
    markdown "$TEST_ROOT/repo/roles/review.md" '{"schema_version":1,"name":"review","kind":"pi","capabilities":["review"],"max_instances":1}' 'Review only.'
    printf '## Task\nInspect synthetic data.\n## Expected output\nA report.\n' > "$TEST_ROOT/body.md"
    live_rules requester
}
owned_worker() {
    jq '.workspace' "$TEST_ROOT/records.json" > "$RUN_ROOT/.workspace.json"
    jq '.workspace_launch' "$TEST_ROOT/records.json" > "$RUN_ROOT/.launches/11111111111111111111111111111111.json"
    jq '.worker_launch' "$TEST_ROOT/records.json" > "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    jq '.worker' "$TEST_ROOT/records.json" > "$RUN_ROOT/.workers/review-1"
}
published_run() {
    local id=${1:-$RUN_ID} records
    records=$(state_fixture "$id")
    mkdir "$RUN_ROOT/$id"
    markdown "$RUN_ROOT/$id/request.md" "$(printf '%s\n' "$records" | jq -c .request)" "$(< "$TEST_ROOT/body.md")"
    printf '%s\n' "$records" | jq .status > "$RUN_ROOT/$id/status"
}
assigned_run() {
    local id=${1:-$RUN_ID}
    published_run "$id"
    jq --slurpfile r "$TEST_ROOT/records.json" --arg at "$TEST_NOW" '
        .state="dispatched" | .revision=1 | .assignment=$r[0].assignment |
        .worker_release.phase="held" | .delivery={phase:"sending",attempt_id:"44444444444444444444444444444444",started_at:$at,acknowledged_at:null,error:null}
        ' "$RUN_ROOT/$id/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$id/status"
}
valid_report() {
    local id=${1:-$RUN_ID}
    markdown "$RUN_ROOT/$id/result.md" "$(state_fixture "$id" | jq -c .report)" \
        $'## Summary\nSynthetic summary.\n## Findings\nNone.\n## Evidence\nSynthetic records.\n## Checks\nOffline checks only.\n## Limits\nNo live check.'
}
live_rules() {
    # Explicit persistent reads remain stable under concurrent helper calls.
    local who=$1
    jq -n --slurpfile r "$TEST_ROOT/records.json" --arg who "$who" --arg cwd "$TEST_ROOT/work" '
        (if $who == "worker" then $r[0].worker_identity elif $who == "none" then null else $r[0].requester end) as $i |
        (if $i == null then [] else [{pane_id:$i.pane_id,terminal_id:$i.terminal_id,workspace_id:(if $who == "worker" then "wDispatch" else "wTest" end),tab_id:(if $who == "worker" then "tWorker" else "tTest" end),agent:$i.kind,agent_session:$i.agent_session,agent_status:"idle",cwd:$cwd,foreground_cwd:$cwd,state_change_seq:1} + (if $who == "worker" or $who == "named" then {name:"review-1"} else {} end)] end) as $agents |
        [{persistent:true,argv:["agent","list"],status:0,stdout:{id:"synthetic",result:{type:"agent_list",agents:$agents}},stderr:null}] +
        (if $i == null then [] else [
         {persistent:true,argv:["pane","current","--current"],status:0,stdout:{id:"synthetic",result:{type:"pane_current",pane:$agents[0]}},stderr:null},
         {persistent:true,argv:["pane","process-info","--pane",$i.pane_id],status:0,stdout:{id:"synthetic",result:{type:"pane_process_info",process_info:{pane_id:$i.pane_id,shell_pid:4000,foreground_process_group_id:$i.foreground_process_group_id,foreground_processes:[{pid:9999,name:"pi",argv0:"pi",cwd:$cwd}]}}},stderr:null}] end)
        ' > "$FAKE_HERDR_SCENARIO"
}
registry_ok() { helper registry; expect_status 0; }
assert_no_mutations() {
    jq -se 'all(.[]; (.argv[0:2] == ["agent","list"] or .argv[0:2] == ["pane","current"] or .argv[0:2] == ["pane","process-info"]))' "$FAKE_HERDR_LOG" >/dev/null || fail 'unexpected CLI mutation'
}
