#!/bin/bash
# Offline requester helper/file contracts, not skill loading or model behavior.
# Sourced by run.sh. All helpers are real; Herdr is the PATH-selected fake CLI.

missing_context() {
    state_setup
    unset HERDR_ENV
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "requester_context"'
    export HERDR_ENV=1
    unset HERDR_PANE_ID
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "requester_context"'
    [ ! -s "$FAKE_HERDR_LOG" ] || fail 'missing context queried Herdr'
    [ "$(find "$RUN_ROOT" -name request.md | wc -l | tr -d ' ')" = 0 ] || fail 'published without context'
}

missing_config() {
    state_setup
    export HERDR_DISPATCHER_CONFIG="$TEST_ROOT/missing-config.json"
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 2
    assert_json "$TEST_ROOT/helper.json" '.error.code == "invalid_config"'
    [ ! -s "$FAKE_HERDR_LOG" ] || fail 'missing config queried Herdr'
    [ ! -e "$HERDR_DISPATCHER_CONFIG" ] || fail 'runtime created config'
}

moved_caller_resolved() {
    state_setup
    export HERDR_PANE_ID='wOld:p99'
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md" --role explore
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.requester.pane_id == "wTest:p1" and .result.requester.terminal_id == "term_test"'
    local id
    id=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
    helper run-state get run "$id"
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.document.state == "new"'
    jq -se 'any(.[]; .argv == ["pane","current","--current"]) and any(.[]; .argv == ["pane","process-info","--pane","wTest:p1"]) and all(.[]; (.argv | index("wOld:p99")) == null)' "$FAKE_HERDR_LOG" >/dev/null
    assert_no_mutations
}

managed_requester_rejected() {
    state_setup; owned_worker; live_rules worker
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "managed_requester"'
    # Dispatcher records reject the same live occupant too, independently of worker records.
    mv "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-saved"
    mv "$RUN_ROOT/.launches" "$TEST_ROOT/launches-saved"
    jq --arg cwd "$TEST_ROOT/repo" '.worker | del(.role,.active_run_id,.idle_since) | .name="dispatcher" | .cwd=$cwd | .ownership={mode:"registered",token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",launch_id:null} | .lifecycle="ready"' "$TEST_ROOT/records.json" > "$RUN_ROOT/.dispatcher.json"
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "managed_requester"'
    [ "$(find "$RUN_ROOT" -name request.md | wc -l | tr -d ' ')" = 0 ] || fail 'managed requester published'
    assert_no_mutations
}

client_completed_run() {
    state_setup; owned_worker; assigned_run; valid_report
    completion_candidate
    helper run-state cas run "$RUN_ID" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
    expect_status 0
}

foreign_result_path_rejected() {
    client_completed_run
    helper run-state check-notice "$RUN_ID" RESULT "$RUN_ROOT/$RUN_ID/result.md"
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.type == "RESULT" and .result.requester.pane_id == "wTest:p1"'
    cp "$RUN_ROOT/$RUN_ID/result.md" "$TEST_ROOT/foreign-result.md"
    helper run-state check-notice "$RUN_ID" RESULT "$TEST_ROOT/foreign-result.md"
    expect_status 2
    helper run-state check-notice "$RUN_TWO" RESULT "$RUN_ROOT/$RUN_ID/result.md"
    expect_status 2
    # Even an exact path cannot be consumed by a different live requester.
    live_rules worker
    helper run-state check-notice "$RUN_ID" RESULT "$RUN_ROOT/$RUN_ID/result.md"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "identity_mismatch"'
    assert_no_mutations
}

failure_path_validated() {
    state_setup; published_run
    jq --arg at "$TEST_NOW" '.state="failed" | .error={code:"invalid_role",message:"Synthetic invalid role",at:$at} | .notice.type="FAILED" | .notice.phase="pending"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision 0 --document "$TEST_ROOT/candidate.json"
    expect_status 0
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before"
    helper run-state check-notice "$RUN_ID" FAILED "$RUN_ROOT/$RUN_ID/status"
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.type == "FAILED" and .result.status_revision == 1'
    assert_equal "$RUN_ROOT/$RUN_ID/status" "$(jq -r .result.path "$TEST_ROOT/helper.json")"
    assert_json "$RUN_ROOT/$RUN_ID/status" '.error.code == "invalid_role" and .error.message == "Synthetic invalid role"'
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/foreign-status"
    helper run-state check-notice "$RUN_ID" FAILED "$TEST_ROOT/foreign-status"
    expect_status 2
    helper run-state check-notice "$RUN_ID" RESULT "$RUN_ROOT/$RUN_ID/result.md"
    expect_status 3
    cmp "$TEST_ROOT/status-before" "$RUN_ROOT/$RUN_ID/status"
    assert_no_mutations
}

preserved_run_after_ring_timeout() {
    spawn_setup
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 0
    local id path target identity
    id=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
    path=$(jq -r .result.run_path "$TEST_ROOT/helper.json")
    cp "$path/request.md" "$TEST_ROOT/request-before"
    cp "$path/status" "$TEST_ROOT/status-before"
    spawn_rules success dispatcher
    helper spawn dispatcher --timeout-ms 15000
    expect_status 0
    target=$(jq -r .result.target "$TEST_ROOT/helper.json")
    identity=$(jq -c .result.identity "$TEST_ROOT/helper.json")
    # Build the requester + newly started dispatcher live view from saved records.
    jq -n --slurpfile r "$TEST_ROOT/records.json" --argjson d "$identity" --arg cwd "$TEST_ROOT/repo" --arg id "$id" '
      def agent($i; $name): {pane_id:$i.pane_id,terminal_id:$i.terminal_id,workspace_id:"wDispatch",tab_id:"tWorker",agent:$i.kind,agent_session:$i.agent_session,agent_status:"idle",cwd:$cwd,state_change_seq:1} + (if $name == null then {} else {name:$name} end);
      agent($r[0].requester;null) as $c | agent($d;"dispatcher") as $a |
      [{persistent:true,argv:["agent","list"],status:0,stdout:{id:"test",result:{type:"agent_list",agents:[$c,$a]}},stderr:null},
       {persistent:true,argv:["pane","current","--current"],status:0,stdout:{id:"test",result:{type:"pane_current",pane:$c}},stderr:null},
       {persistent:true,argv:["pane","process-info","--pane",$d.pane_id],status:0,stdout:{id:"test",result:{type:"pane_process_info",process_info:{pane_id:$d.pane_id,foreground_process_group_id:$d.foreground_process_group_id,foreground_processes:[{pid:5201}]}}},stderr:null},
       {argv:["agent","prompt",$d.pane_id,("NEW "+$id),"--wait","--until","working","--timeout",{timeout_ms:true}],status:1,stdout:null,stderr:{error:{code:"timeout",message:"Synthetic post-submit timeout"}}}]
    ' > "$FAKE_HERDR_SCENARIO"
    helper ring "$target" "NEW $id" --expected-session "$identity" --timeout-ms 10000
    expect_status 5
    assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain"'
    cmp "$TEST_ROOT/request-before" "$path/request.md"
    cmp "$TEST_ROOT/status-before" "$path/status"
    helper run-state get run "$id"
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.document.state == "new" and .result.document.assignment == null'
    assert_equal 1 "$(find "$RUN_ROOT" -name request.md | wc -l | tr -d ' ')"
    assert_equal 1 "$(jq -s '[.[] | select(.argv[0:2] == ["agent","prompt"])] | length' "$FAKE_HERDR_LOG")"
}

client_role_fixtures() {
    state_setup
    local role id metadata
    for role in review explore; do
        helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_REPO/tests/fixtures/requests/$role.md" --role "$role"
        expect_status 0
        id=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
        # Validate example report sections and metadata through the real notice checker.
        metadata=$(state_fixture "$id" | jq -c --arg role "$role" '.report | .worker_name=($role+"-1")')
        markdown "$RUN_ROOT/$id/result.md" "$metadata" "$(< "$TEST_REPO/tests/fixtures/reports/$role.md")"
        jq --slurpfile r "$TEST_ROOT/records.json" --arg role "$role" --arg at "$TEST_NOW" '.state="dispatched" | .revision=1 | .assignment=($r[0].assignment | .role=$role | .worker_name=($role+"-1")) | .worker_release.phase="held" | .delivery={phase:"sending",attempt_id:"44444444444444444444444444444444",started_at:$at,acknowledged_at:null,error:null}' "$RUN_ROOT/$id/status" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$RUN_ROOT/$id/status"
        jq '.state="done" | .notice.type="RESULT" | .notice.phase="pending"' "$RUN_ROOT/$id/status" > "$TEST_ROOT/candidate.json"
        helper run-state cas run "$id" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
        expect_status 0
        helper run-state check-notice "$id" RESULT "$RUN_ROOT/$id/result.md"
        expect_status 0
    done
    assert_no_mutations
}
