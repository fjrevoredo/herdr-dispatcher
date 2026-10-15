#!/bin/bash
# Task 2.1 contract tests. Sourced by run.sh; never use live CLI state.

gone_worker_sync_recovers_crash_gaps() {
    local gap
    for gap in release journal; do
        state_setup; owned_worker; assigned_run; valid_report; live_rules none
        jq '. + [{persistent:true,argv:["agent","get","wDispatch:p2"],status:1,stdout:null,stderr:{error:{code:"pane_not_found",message:"Synthetic missing pane"}}}]' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
        jq --arg at "$TEST_NOW" '.state="done" | .notice.type="RESULT" | .notice.phase="pending" | .worker_release={phase:"retired",observed_at:$at,reason:"worker_gone"}' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
        if [ "$gap" = journal ]; then
            jq '.phase="closed"' "$RUN_ROOT/.launches/22222222222222222222222222222222.json" > "$TEST_ROOT/next.json"
            mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
            # Historical proof must survive workspace removal before cache repair.
            mv "$RUN_ROOT/.workspace.json" "$TEST_ROOT/old-workspace"
        fi
        cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before"
        advance_time '2026-10-14T14:15:00Z'
        helper run-state worker-sync review-1 --expect-revision 0
        expect_status 0
        cmp "$TEST_ROOT/status-before" "$RUN_ROOT/$RUN_ID/status"
        assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "gone" and .active_run_id == null'
        assert_json "$RUN_ROOT/.launches/22222222222222222222222222222222.json" '.phase == "closed"'
        registry_ok
        assert_json "$TEST_ROOT/helper.json" '.result.issues == [] and .result.workers[0].classification == "closed" and .result.runs[0].result_valid'
        mv "$RUN_ROOT/$RUN_ID" "$TEST_ROOT/crashed-$gap"
    done
}

gone_worker_sync_closes_journal() {
    local state
    for state in 'done' failed; do
        state_setup; owned_worker; assigned_run; valid_report; live_rules none
        jq '. + [{persistent:true,argv:["agent","get","wDispatch:p2"],status:1,stdout:null,stderr:{error:{code:"pane_not_found",message:"Synthetic missing pane"}}}]' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
        jq --arg state "$state" --arg at "$TEST_NOW" '.state=$state | .notice.phase="pending" | .notice.type=(if $state == "done" then "RESULT" else "FAILED" end) | .error=(if $state == "failed" then {code:"worker_gone",message:"Synthetic",at:$at} else null end)' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
        helper run-state worker-sync review-1 --expect-revision 0
        expect_status 0
        assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase == "retired" and .assignment != null'
        assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "gone" and .active_run_id == null'
        assert_json "$RUN_ROOT/.launches/22222222222222222222222222222222.json" '.phase == "closed" and .identity != null and .ownership_token != null'
        registry_ok
        assert_json "$TEST_ROOT/helper.json" '.result.workers[0].classification == "closed" and .result.issues == [] and .result.runs[0].result_valid'
        # A repeated sync must retain the first release observation and ownership.
        cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before"
        advance_time '2026-10-14T14:15:00Z'
        helper run-state worker-sync review-1 --expect-revision 1
        expect_status 0
        cmp "$TEST_ROOT/status-before" "$RUN_ROOT/$RUN_ID/status"
        # The second iteration creates the same synthetic run afresh.
        mv "$RUN_ROOT/$RUN_ID" "$TEST_ROOT/finished-$state"
    done
}

live_identity_gaps_retained() {
    state_setup; owned_worker; assigned_run; live_rules worker
    jq 'map(if .argv == ["agent","list"] then .stdout.result.agents += [(.stdout.result.agents[0] | .pane_id="wOther:p9" | .terminal_id="term_other" | .agent_session=null | .name="other")] else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].classification == "assigned" and .result.workers[0].classification == "occupied" and any(.result.unrelated_agents[]; .identity == null and .name == "other") and any(.result.issues[]; .code == "live_identity_unavailable")'
    # A real process-info query failure must still fail the whole command.
    cp "$FAKE_HERDR_SCENARIO" "$TEST_ROOT/live-saved.json"
    jq 'map(if .argv[0:2] == ["pane","process-info"] then .status=1 | .stdout=null | .stderr={error:{code:"unavailable"}} else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    helper registry
    expect_status 6
    assert_json "$TEST_ROOT/helper.json" '.error.code == "live_query_failed"'
    cp "$TEST_ROOT/live-saved.json" "$FAKE_HERDR_SCENARIO"
    jq 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].agent_session=null else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers[0].classification == "quarantined" and (.result.unrelated_agents | length == 2)'
    helper run-state worker-sync review-1 --expect-revision 0
    expect_status 3
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase == "held"'
    jq 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].agent="unsupported" else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers[0].classification == "quarantined"'
    scenario '[{"persistent":true,"argv":["agent","list"],"status":1,"stdout":null,"stderr":{"error":{"code":"unavailable"}}}]'
    helper registry
    expect_status 6
    assert_json "$TEST_ROOT/helper.json" '.error.code == "live_query_failed"'
}

stale_nonempty_idle_recovered() {
    state_setup; owned_worker; live_rules worker; assigned_run
    jq --arg at "$TEST_NOW" '.state="done" | .notice.type="RESULT" | .notice.phase="pending" | .worker_release={phase:"released",observed_at:$at,reason:"valid_result_settled"}' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
    advance_time '2026-10-14T14:15:00Z'
    assigned_run "$RUN_TWO"
    jq --arg at "$TEST_NOW" '.assignment.assigned_at=$at' "$RUN_ROOT/$RUN_TWO/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_TWO/status"
    # The assignment committed, but the cache still has the previous idle time.
    helper run-state worker-sync review-1 --expect-revision 0
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "occupied" and .idle_since == null'
    # Restore the cache from before both writes to cover two consecutive crash gaps.
    jq '.worker' "$TEST_ROOT/records.json" > "$RUN_ROOT/.workers/review-1"
    jq --arg at "$TEST_NOW" '.state="done" | .notice.type="RESULT" | .notice.phase="pending" | .worker_release={phase:"released",observed_at:$at,reason:"valid_result_settled"}' "$RUN_ROOT/$RUN_TWO/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_TWO/status"
    helper run-state worker-sync review-1 --expect-revision 0
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.idle_since == "2026-10-14T14:15:00Z" and .active_run_id == null'
    helper run-state worker-sync review-1 --expect-revision 1
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.idle_since == "2026-10-14T14:15:00Z"'
}

malformed_release_blocks_assignment() {
    state_setup; owned_worker; live_rules worker; assigned_run; published_run "$RUN_TWO"
    jq '.worker_release.phase="none"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" 'any(.result.runs[]; .classification == "quarantined") and any(.result.issues[]; .code == "malformed_run")'
    helper run-state assign "$RUN_TWO" --worker review-1 --expect-revision 0 --expect-worker-revision 0
    expect_status 3
    assert_json "$RUN_ROOT/$RUN_TWO/status" '.assignment == null and .state == "new"'
}

status_cross_fields_validated() {
    state_setup; owned_worker; assigned_run
    local patch
    for patch in '.assignment=null' '.worker_release.phase="none"' '.delivery.phase="none"' '.notice.type="RESULT"' '.state="new"' '.state="done"' '.state="failed"' '.delivery.acknowledged_at=.created_at' '.nudge.settled_observed_at=.created_at' '.delivery.error={code:"bad",message:"Bad",at:.created_at}' '.worker_release.observed_at=.created_at' '.worker_release.phase="released" | .worker_release.reason="valid_result_settled" | .worker_release.observed_at=.created_at' '.notice.phase="pending"'; do
        jq "$patch" "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
        if /bin/bash -c 'source "$1/bin/lib.sh"; hd_json_validate status "$2"' _ "$TEST_REPO" "$TEST_ROOT/candidate.json"; then fail "accepted inconsistent status: $patch"; fi
    done
    for patch in '.worker_release.phase="held"' '.delivery.phase="sending"' '.notice.type="FAILED"' '.human.late_result=true' '.error={code:"bad",message:"Bad",at:.created_at}'; do
        jq ".status | $patch" "$TEST_ROOT/records.json" > "$TEST_ROOT/candidate.json"
        if /bin/bash -c 'source "$1/bin/lib.sh"; hd_json_validate status "$2"' _ "$TEST_REPO" "$TEST_ROOT/candidate.json"; then fail "accepted inconsistent new status: $patch"; fi
    done
    valid_report
    jq --arg at "$TEST_NOW" '.state="failed" | .error={code:"worker_gone",message:"Synthetic",at:$at} | .notice.type="FAILED" | .notice.phase="pending"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
    jq '.human.late_result=true' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
    expect_status 0
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state == "failed" and .human.late_result'
}

notice_retries_remain_valid() {
    state_setup; owned_worker; assigned_run; valid_report
    completion_candidate
    helper run-state cas run "$RUN_ID" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
    expect_status 0
    local outcome revision=2 token=5
    for outcome in missing-requester uncertain input-accepted; do
        jq --arg at "$TEST_NOW" --arg token "${token}5555555555555555555555555555555" '.notice.in_flight=true | .notice.phase="pending" | .notice.attempts += 1 | .notice.last_attempt_at=$at | .notice.attempt_id=$token' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
        helper run-state cas run "$RUN_ID" --expect-revision "$revision" --document "$TEST_ROOT/candidate.json"
        expect_status 0
        revision=$((revision + 1))
        jq --arg outcome "$outcome" '.notice.in_flight=false | .notice.last_outcome=$outcome | .notice.phase=(if $outcome == "input-accepted" then "sent" elif $outcome == "missing-requester" then "missing-requester" else "pending" end) | if $outcome == "input-accepted" then .state="relayed" else . end' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
        helper run-state cas run "$RUN_ID" --expect-revision "$revision" --document "$TEST_ROOT/candidate.json"
        expect_status 0
        revision=$((revision + 1)); token=$((token + 1))
    done
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state == "relayed" and .notice.phase == "sent" and .notice.attempts == 3'
}

concurrent_run_ids() {
    state_setup
    local a b sa=0 sb=0
    "$TEST_REPO/bin/new-run" --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md" > "$TEST_ROOT/a.json" 2> "$TEST_ROOT/a.err" & a=$!
    "$TEST_REPO/bin/new-run" --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md" > "$TEST_ROOT/b.json" 2> "$TEST_ROOT/b.err" & b=$!
    wait "$a" || sa=$?
    wait "$b" || sb=$?
    assert_envelope "$TEST_ROOT/a.json"
    assert_envelope "$TEST_ROOT/b.json"
    if [ "$sa" -ne 0 ] || [ "$sb" -ne 0 ]; then
        printf 'Concurrent publisher responses:\n' >&2
        jq -c . "$TEST_ROOT/a.json" "$TEST_ROOT/b.json" >&2
    fi
    assert_equal 0 "$sa"
    assert_equal 0 "$sb"
    jq -se '.[0].result.run_id != .[1].result.run_id' "$TEST_ROOT/a.json" "$TEST_ROOT/b.json" >/dev/null
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs | length == 2 and all(.[]; .classification == "queued" and .status.revision == 0 and .request.run_id == .run_id)'
    assert_no_mutations
}

existing_run_never_overwritten() {
    state_setup
    published_run
    cp "$RUN_ROOT/$RUN_ID/request.md" "$TEST_ROOT/original-request"
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/original-status"
    # Force the first generated ID to collide. The next ID uses OS randomness.
    mkdir "$TEST_ROOT/collision-bin"
    ln -s "$TEST_REPO/tests/fixtures/collision-date" "$TEST_ROOT/collision-bin/date"
    ln -s "$TEST_REPO/tests/fixtures/collision-od" "$TEST_ROOT/collision-bin/od"
    export TEST_COLLISION_ID="$RUN_ID"
    export PATH="$TEST_ROOT/collision-bin:$PATH"
    helper new-run --cwd "$TEST_ROOT/work" --body-file "$TEST_ROOT/body.md"
    expect_status 0
    assert_equal 1 "$(< "$TEST_ROOT/collision-used")"
    [ "$(jq -r .result.run_id "$TEST_ROOT/helper.json")" != "$RUN_ID" ] || fail 'collision reused existing ID'
    cmp "$TEST_ROOT/original-request" "$RUN_ROOT/$RUN_ID/request.md"
    cmp "$TEST_ROOT/original-status" "$RUN_ROOT/$RUN_ID/status"
    [ "$(find "$RUN_ROOT/$RUN_ID" -type f | wc -l | tr -d ' ')" = 2 ] || fail 'publication merged into existing run'
}

unpublished_run_ignored() {
    state_setup
    published_run
    mv "$RUN_ROOT/$RUN_ID" "$RUN_ROOT/.staging/$RUN_ID"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs == [] and .result.issues == []'
    [ -f "$RUN_ROOT/.staging/$RUN_ID/request.md" ] || fail 'staging remnant removed'
    assert_no_mutations
}

partial_result_ignored() {
    state_setup; owned_worker; assigned_run; valid_report
    mv "$RUN_ROOT/$RUN_ID/result.md" "$RUN_ROOT/$RUN_ID/result.md.tmp"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0] | .classification == "assigned" and .result_valid == false and .result_path == null'
    completion_candidate
    helper run-state cas run "$RUN_ID" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
    expect_status 3
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state == "dispatched" and .revision == 1'
    [ -f "$RUN_ROOT/$RUN_ID/result.md.tmp" ] || fail 'partial report removed'
}

completion_candidate() {
    jq '.state="done" | .notice.type="RESULT" | .notice.phase="pending"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
}
reject_report() {
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].result_valid == false and any(.result.issues[]; .code == "invalid_report")'
    completion_candidate
    helper run-state cas run "$RUN_ID" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "invalid_report"'
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state == "dispatched" and .revision == 1'
}
wrong_run_result_rejected() {
    state_setup; owned_worker; assigned_run; valid_report
    markdown "$RUN_ROOT/$RUN_ID/result.md" "$(state_fixture "$RUN_TWO" | jq -c .report)" \
        $'## Summary\nSynthetic.\n## Findings\nNone.\n## Evidence\nNone.\n## Checks\nNone.\n## Limits\nNone.'
    reject_report
}
wrong_worker_result_rejected() {
    state_setup; owned_worker; assigned_run
    markdown "$RUN_ROOT/$RUN_ID/result.md" "$(state_fixture | jq -c '.report | .worker.foreground_process_group_id=5201')" \
        $'## Summary\nSynthetic.\n## Findings\nNone.\n## Evidence\nNone.\n## Checks\nNone.\n## Limits\nNone.'
    reject_report
}
invalid_transition_rejected() {
    state_setup; published_run
    jq '.state="relayed"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision 0 --document "$TEST_ROOT/candidate.json"
    expect_status 2
    assert_json "$TEST_ROOT/helper.json" '.ok == false and .error.code == "invalid_document"'
    helper run-state get run "$RUN_ID"
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.document.state == "new" and .result.document.revision == 0'
}
malformed_metadata_reported() {
    state_setup; published_run
    printf '{broken\n' > "$RUN_ROOT/$RUN_ID/status"
    printf '%s\n' '---' '{"schema_version":2,"name":"review"}' '---' 'Synthetic.' > "$TEST_ROOT/repo/roles/review.md"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].classification == "quarantined" and .result.runs[0].status == null and .result.roles[0].metadata == null and any(.result.issues[]; .code == "malformed_run") and any(.result.issues[]; .code == "malformed_role")'
    helper run-state get run "$RUN_ID"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "malformed_record"'
}
path_escape_rejected() {
    state_setup; published_run
    helper run-state get run "../$RUN_ID"
    expect_status 2
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/outside-status"
    mv "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/saved-status"
    ln -s "$TEST_ROOT/outside-status" "$RUN_ROOT/$RUN_ID/status"
    helper run-state get run "$RUN_ID"
    expect_status 2
    helper new-run --cwd "$TEST_ROOT/work/../work" --body-file "$TEST_ROOT/body.md"
    expect_status 2
    cmp "$TEST_ROOT/saved-status" "$TEST_ROOT/outside-status"
}
unrelated_named_agent_excluded() {
    state_setup; live_rules named
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers == [] and (.result.unrelated_agents | length == 1) and .result.unrelated_agents[0].name == "review-1"'
    [ ! -e "$RUN_ROOT/.workers/review-1" ] || fail 'unrelated agent adopted'
    assert_no_mutations
}
missing_identity_quarantined() {
    state_setup; owned_worker; live_rules none
    jq '.identity=null | .lifecycle="ready"' "$RUN_ROOT/.workers/review-1" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/review-1"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers[0].classification == "quarantined" and any(.result.issues[]; .code == "ownership_conflict")'
    helper run-state worker-sync review-1 --expect-revision 0
    expect_status 3
    assert_json "$RUN_ROOT/.workers/review-1" '.revision == 0 and .identity == null'
}
stale_worker_reported() {
    state_setup; owned_worker; live_rules none
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers[0].classification == "stale" and .result.workers[0].record.identity != null and .result.workers[0].live == null'
    assert_json "$RUN_ROOT/.workers/review-1" '.revision == 0 and .lifecycle == "idle"'
    assert_no_mutations
}
failure_relay_retained() {
    state_setup; published_run
    jq --arg at "$TEST_NOW" '.state="failed" | .error={code:"invalid_role",message:"Synthetic invalid role",at:$at} | .notice.type="FAILED" | .notice.phase="pending"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision 0 --document "$TEST_ROOT/candidate.json"
    expect_status 0
    jq --arg at "$TEST_NOW" '.notice.in_flight=true | .notice.attempts=1 | .notice.last_attempt_at=$at | .notice.attempt_id="55555555555555555555555555555555"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision 1 --document "$TEST_ROOT/candidate.json"
    expect_status 0
    jq '.notice.in_flight=false | .notice.phase="sent" | .notice.last_outcome="input-accepted"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision 2 --document "$TEST_ROOT/candidate.json"
    expect_status 0
    helper run-state check-notice "$RUN_ID" FAILED "$RUN_ROOT/$RUN_ID/status"
    expect_status 0
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0] | .classification == "failed" and .status.state == "failed" and .status.notice.phase == "sent" and .status.error.code == "invalid_role" and .status.revision == 3'
    [ -f "$RUN_ROOT/$RUN_ID/request.md" ] || fail 'failed request removed'
}
duplicate_worker_assignment_rejected() {
    state_setup; owned_worker; live_rules worker; published_run; published_run "$RUN_TWO"
    # A valid first assignment must succeed. Accepting unimplemented here hides RED.
    helper run-state assign "$RUN_ID" --worker review-1 --expect-revision 0 --expect-worker-revision 0
    expect_status 0
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state == "dispatched" and .worker_release.phase == "held" and .assignment.worker_name == "review-1"'
    local revision
    revision=$(jq -r .revision "$RUN_ROOT/.workers/review-1")
    helper run-state assign "$RUN_TWO" --worker review-1 --expect-revision 0 --expect-worker-revision "$revision"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code != "unimplemented" and .ok == false'
    assert_json "$RUN_ROOT/$RUN_TWO/status" '.state == "new" and .assignment == null and .revision == 0'
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers[0] | .classification == "occupied" and (.occupancy_run_ids | length == 1)'
}
crash_between_state_files() {
    state_setup; owned_worker; live_rules worker; assigned_run
    # Simulate a crash after authoritative status but before derived cache write.
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "idle" and .active_run_id == null'
    helper run-state worker-sync review-1 --expect-revision 0
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "occupied" and .active_run_id != null and .idle_since == null and .revision == 1'
    valid_report
    # Simulate release persisted before cache. Preserve its first observation time.
    jq --arg at "$TEST_NOW" '.state="done" | .revision=2 | .notice.type="RESULT" | .notice.phase="pending" | .worker_release={phase:"released",observed_at:$at,reason:"valid_result_settled"}' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
    helper run-state worker-sync review-1 --expect-revision 1
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "idle" and .active_run_id == null and .idle_since == "2026-10-14T14:00:00Z" and .revision == 2'
    helper run-state worker-sync review-1 --expect-revision 2
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.idle_since == "2026-10-14T14:00:00Z"'
    assert_json "$RUN_ROOT/$RUN_ID/status" '.revision == 2 and .worker_release.phase == "released" and .assignment != null'
    assert_no_mutations
}
