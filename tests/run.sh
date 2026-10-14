#!/bin/bash
set -euo pipefail
TEST_REPO=$(cd "$(dirname "$0")/.." && pwd -P)
export TEST_REPO
# The absolute checkout path is resolved at runtime.
# shellcheck disable=SC1091
source "$TEST_REPO/tests/helpers.sh"

runner_self_test() {
    local status=0
    TEST_RUNNER_INNER=1 /bin/bash "$TEST_REPO/tests/run.sh" --inner-failure > "$TEST_ROOT/inner.out" 2>&1 || status=$?
    assert_equal 1 "$status"
    grep -Fx 'FAIL: intentional inner failure' "$TEST_ROOT/inner.out" >/dev/null
    grep -Fx 'not ok - intentional_failure' "$TEST_ROOT/inner.out" >/dev/null
}

no_test_selector_rejected() {
    local selector status
    for selector in unknown-test --inner-empty; do
        status=0
        TEST_RUNNER_INNER=1 /bin/bash "$TEST_REPO/tests/run.sh" "$selector" > "$TEST_ROOT/selector.out" 2>&1 || status=$?
        assert_equal 2 "$status"
        case "$selector" in
            unknown-test) grep -Fx 'unknown selector: unknown-test' "$TEST_ROOT/selector.out" >/dev/null ;;
            --inner-empty) grep -Fx 'no tests for selector: --inner-empty' "$TEST_ROOT/selector.out" >/dev/null ;;
        esac
    done
}

shell_files() {
    local file
    for file in tests/run.sh tests/lint.sh tests/helpers.sh tests/fake-bin/herdr .githooks/pre-commit; do
        [ -x "$TEST_REPO/$file" ] || fail "not executable: $file"
        /bin/bash -n "$TEST_REPO/$file"
    done
    if [ -d "$TEST_REPO/bin" ]; then
        while IFS= read -r -d '' file; do
            [ -x "$file" ] || fail "not executable: $file"
            /bin/bash -n "$file"
        done < <(find "$TEST_REPO/bin" -type f -print0)
    fi
}

fake_cli() {
    local response status=0
    assert_equal "$TEST_REPO/tests/fake-bin/herdr" "$(command -v herdr)"
    response=$(fixture agent_list)
    scenario "$(jq -cn --argjson response "$response" '[{argv:["agent","list"],status:0,stdout:$response,stderr:null}]')"
    herdr agent list > "$TEST_ROOT/list.json"
    assert_json "$TEST_ROOT/list.json" '.result.type == "agent_list" and (.result.agents[0] | has("name") | not)'
    assert_json "$FAKE_HERDR_LOG" '.cli == "fake-herdr" and .argv == ["agent","list"]'
    response=$(fixture agent_blocked)
    scenario "$(jq -cn --argjson response "$response" '[{argv:["agent","prompt","wTest:p1","test"],status:1,stdout:null,stderr:$response}]')"
    herdr agent prompt wTest:p1 test > "$TEST_ROOT/prompt.out" 2> "$TEST_ROOT/prompt.err" || status=$?
    assert_equal 1 "$status"
    [ ! -s "$TEST_ROOT/prompt.out" ] || fail 'server error on stdout'
    assert_json "$TEST_ROOT/prompt.err" '.error.code == "agent_blocked"'
    assert_equal 'wTest:p1' "$(jq -r 'select(.argv[1] == "prompt") | .target' "$FAKE_HERDR_LOG")"
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 0'
    status=0
    herdr agent list > "$TEST_ROOT/unscripted.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    jq -se 'all(.[]; .cli == "fake-herdr") and length == 3' "$FAKE_HERDR_LOG" >/dev/null
}

fake_safety() {
    local status=0
    (cd /; herdr agent list) > "$TEST_ROOT/outside.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    HOME=/ herdr agent list > "$TEST_ROOT/home.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    TEST_ROOT='' herdr agent list > "$TEST_ROOT/root.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    herdr workspace create --cwd / > "$TEST_ROOT/cwd.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    herdr agent list --remote example > "$TEST_ROOT/remote.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    [ ! -s "$FAKE_HERDR_LOG" ] || fail 'unsafe call was logged'
}

fixture_shapes() {
    local fixtures="$TEST_REPO/tests/fixtures/herdr.json"
    assert_json "$fixtures" '.process_info.result.process_info | .foreground_process_group_id > 0 and (.foreground_processes | length > 0)'
    assert_json "$fixtures" '.pane_current.result.pane.agent_session == .agent_list.result.agents[0].agent_session'
    assert_json "$fixtures" '.workspace_create.result | .workspace.workspace_id == .root_pane.workspace_id and .tab.tab_id == .root_pane.tab_id'
    assert_json "$fixtures" '.tab_create.result | .tab.tab_id == .root_pane.tab_id'
    printf '%s\n' '{"schema_version":1,"ok":true,"outcome":"ok","result":{},"error":null}' > "$TEST_ROOT/envelope.json"
    assert_envelope "$TEST_ROOT/envelope.json"
    advance_time '2026-10-14T14:15:00Z'
    assert_equal '2026-10-14T14:15:00Z' "$TEST_NOW"
}

names=(runner_self_test no_test_selector_rejected shell_files fake_cli fake_safety fixture_shapes)
groups=(runner runner shell fake fake fake)
group_names=(runner shell fake)
if [ "${TEST_RUNNER_INNER:-0}" = 1 ]; then group_names+=(--inner-empty); fi
selectors=("$@")
if [ "$#" -eq 0 ]; then selectors=(all); fi
selected=' '
for selector in "${selectors[@]}"; do
    known=0
    matched=0
    for group in "${group_names[@]}"; do
        if [ "$selector" = "$group" ]; then known=1; fi
    done
    for ((i=0; i<${#names[@]}; i++)); do
        if [ "$selector" = all ] || [ "$selector" = "${names[$i]}" ] || [ "$selector" = "${groups[$i]}" ]; then
            known=1
            matched=1
            case "$selected" in *" ${names[$i]} "*) ;; *) selected="$selected${names[$i]} " ;; esac
        fi
    done
    if [ "${TEST_RUNNER_INNER:-0}" = 1 ] && [ "$selector" = --inner-failure ]; then
        known=1
        matched=1
        selected=' intentional_failure '
    fi
    if [ "$known" -eq 0 ]; then
        printf 'unknown selector: %s\n' "$selector" >&2
        exit 2
    fi
    if [ "$matched" -eq 0 ]; then
        printf 'no tests for selector: %s\n' "$selector" >&2
        exit 2
    fi
done
intentional_failure() { fail 'intentional inner failure'; }
passed=0
failed=0
for name in $selected; do
    # Do not put the case in an if-condition: Bash would disable errexit inside it.
    set +e
    (set -e; sandbox; "$name")
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        printf 'ok - %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'not ok - %s\n' "$name"
        failed=$((failed + 1))
    fi
done
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
