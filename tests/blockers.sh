#!/bin/bash
# Regression tests for the Task 2.3 ownership and registration blockers.
closed_worker_workspace_replacement() {
    spawn_reuse_setup
    jq '.lifecycle="closed"' "$RUN_ROOT/.workers/review-1" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/review-1"
    jq '.phase="closed"' "$RUN_ROOT/.launches/22222222222222222222222222222222.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    cp "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-before"
    cp "$RUN_ROOT/.launches/22222222222222222222222222222222.json" "$TEST_ROOT/launch-before"
    spawn_rules
    spawn_patch 'walk(if type == "string" then gsub("review-1";"review-2") | gsub("wDispatch";"wReplacement") | gsub("term_worker";"term_replacement") else . end)'
    spawn_worker
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.name == "review-2" and .result.workspace_id == "wReplacement" and .result.reused == false'
    cmp "$TEST_ROOT/worker-before" "$RUN_ROOT/.workers/review-1"
    cmp "$TEST_ROOT/launch-before" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    helper registry
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.issues == [] and any(.result.workers[]; .name == "review-1" and .classification == "closed")'
    spawn_launch_only
}
registration_journal_gap_setup() {
    spawn_setup; live_rules requester
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].cwd=(env.TEST_ROOT+"/repo") | .stdout.result.agents[0].foreground_cwd=(env.TEST_ROOT+"/repo") elif .argv == ["pane","current","--current"] then .stdout.result.pane.cwd=(env.TEST_ROOT+"/repo") | .stdout.result.pane.foreground_cwd=(env.TEST_ROOT+"/repo") elif .argv[0:2] == ["pane","process-info"] then .stdout.result.process_info.foreground_processes[0].cwd=(env.TEST_ROOT+"/repo") else . end)'
    jq --arg cwd "$TEST_ROOT/repo" '.workspace_launch | .ownership_mode="registered" | .phase="starting" | .mutation="agent_rename" | .identity=input.requester | .pane_id=.identity.pane_id | .workspace_id="wTest" | .tab_id="tTest" | .cwd=$cwd' "$TEST_ROOT/records.json" "$TEST_ROOT/records.json" > "$RUN_ROOT/.launches/11111111111111111111111111111111.json"
}
registration_journal_gap_uncertain() {
    registration_journal_gap_setup
    helper run-state register-dispatcher --expect-revision absent --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms 15000
    expect_status 5
    assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain" and .result.dispatcher.ownership.token == "11111111111111111111111111111111" and .result.committed == true'
    assert_json "$RUN_ROOT/.dispatcher.json" '.lifecycle == "starting" and .ownership.mode == "registered"'
    assert_no_mutations
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].name="dispatcher" elif .argv == ["pane","current","--current"] then .stdout.result.pane.name="dispatcher" else . end)'
    helper run-state register-dispatcher --expect-revision 0 --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms 15000
    expect_status 0
    assert_json "$RUN_ROOT/.dispatcher.json" '.lifecycle == "ready" and .ownership.token == "11111111111111111111111111111111"'
    assert_no_mutations
}
registration_journal_gap_mismatch_refused() {
    local field
    for field in config_path cwd kind workspace_id tab_id identity; do
        registration_journal_gap_setup
        jq --arg field "$field" 'if $field == "identity" then .identity.agent_session.value += ".other" elif $field == "kind" then .kind="claude" else .[$field] += "-other" end' "$RUN_ROOT/.launches/11111111111111111111111111111111.json" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/11111111111111111111111111111111.json"
        helper run-state register-dispatcher --expect-revision absent --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms 15000
        expect_status 3
        [ ! -e "$RUN_ROOT/.dispatcher.json" ] || fail "recovered mismatched $field"
        assert_no_mutations
    done
}
retired_worker_historical_launch_required() {
    spawn_reuse_setup
    jq '.lifecycle="gone"' "$RUN_ROOT/.workers/review-1" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/review-1"
    mv "$RUN_ROOT/.workspace.json" "$TEST_ROOT/workspace-before"
    helper registry
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" 'any(.result.workers[]; .name == "review-1" and .classification == "quarantined")'
    jq '.phase="closed"' "$RUN_ROOT/.launches/22222222222222222222222222222222.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    helper registry
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.issues == [] and any(.result.workers[]; .name == "review-1" and .classification == "closed")'
    jq '.ownership_token="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$RUN_ROOT/.launches/22222222222222222222222222222222.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    helper registry
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" 'any(.result.workers[]; .name == "review-1" and .classification == "quarantined")'
    assert_no_mutations
}
nonterminal_worker_workspace_proof_required() {
    spawn_reuse_setup
    jq '.lifecycle="gone"' "$RUN_ROOT/.workspace.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workspace.json"
    helper registry
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" 'any(.result.workers[]; .name == "review-1" and .classification == "quarantined")'
    assert_no_mutations
}
registration_journal_gap_observed() {
    registration_journal_gap_setup
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].name="dispatcher" elif .argv == ["pane","current","--current"] then .stdout.result.pane.name="dispatcher" else . end)'
    helper run-state register-dispatcher --expect-revision absent --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms 15000
    expect_status 0
    assert_json "$RUN_ROOT/.dispatcher.json" '.lifecycle == "ready" and .ownership.token == "11111111111111111111111111111111"'
    assert_no_mutations
}
ring_worker_created_workspace_dispatcher() {
    ring_setup
    jq --arg cwd "$TEST_ROOT/repo" '.worker | del(.role,.active_run_id,.idle_since) | .name="dispatcher" | .cwd=$cwd | .lifecycle="ready"' "$TEST_ROOT/records.json" > "$RUN_ROOT/.dispatcher.json"
    mv "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/retained-worker"
    jq --arg cwd "$TEST_ROOT/repo" '.target="dispatcher" | .name="dispatcher" | .role=null | .cwd=$cwd' "$RUN_ROOT/.launches/22222222222222222222222222222222.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    jq '.target="worker" | .name="review-9" | .role="review"' "$RUN_ROOT/.launches/11111111111111111111111111111111.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/11111111111111111111111111111111.json"
    ring_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[1].name="dispatcher" | .stdout.result.agents[1].cwd=(env.TEST_ROOT+"/repo") elif .argv[0:2] == ["agent","prompt"] then .stdout.result.agent.name="dispatcher" | .stdout.result.agent.cwd=(env.TEST_ROOT+"/repo") else . end)'
    helper ring dispatcher "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 10000
    expect_status 0
    assert_equal 1 "$(ring_prompt_count)"
}
