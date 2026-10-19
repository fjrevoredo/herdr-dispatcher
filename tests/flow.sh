#!/bin/bash
# jq receives literal expressions and binds $at in flow_cas.
# shellcheck disable=SC2016
# Whole-flow simulations. The test drives dispatcher decisions, not a model.
# Allow CPU contention in the shell-heavy offline fixture, but keep calls bounded.
FLOW_TIMEOUT_MS=60000

flow_setup() {
    local role=${1:-review}
    spawn_setup
    FLOW_NAME="$role-1"
    markdown "$TEST_ROOT/repo/roles/explore.md" '{"schema_version":1,"name":"explore","kind":"pi","capabilities":["explore"],"max_instances":1}' 'Explore only.'
    jq --arg role "$role" --arg name "$FLOW_NAME" '.worker.name=$name | .worker.role=$role | .worker_launch.name=$name | .worker_launch.role=$role' "$TEST_ROOT/records.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$TEST_ROOT/records.json"
    owned_worker
    if [ "$role" != review ]; then mv "$RUN_ROOT/.workers/review-1" "$RUN_ROOT/.workers/$FLOW_NAME"; fi
    jq --arg cwd "$TEST_ROOT/repo" '.worker | del(.role,.active_run_id,.idle_since) | .name="dispatcher" | .cwd=$cwd | .tab_id="tDispatch" | .pane_id="wDispatch:p1" | .identity=input.workspace_launch.identity | .ownership={mode:"created",token:"11111111111111111111111111111111",launch_id:"11111111111111111111111111111111"} | .lifecycle="ready"' "$TEST_ROOT/records.json" "$TEST_ROOT/records.json" > "$RUN_ROOT/.dispatcher.json"
    flow_live
    helper new-run --cwd "$TEST_ROOT/work" --role "$role" --body-file "$TEST_REPO/tests/fixtures/requests/$role.md" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
    RUN_ID=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
    cp "$RUN_ROOT/$RUN_ID/request.md" "$TEST_ROOT/request-snapshot"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].classification == "queued"'
}

flow_live() {
    jq -n --slurpfile r "$TEST_ROOT/records.json" --arg name "$FLOW_NAME" --arg cwd "$TEST_ROOT/work" --arg repo "$TEST_ROOT/repo" '
      def agent($i;$w;$t;$cwd): {pane_id:$i.pane_id,terminal_id:$i.terminal_id,workspace_id:$w,tab_id:$t,agent:$i.kind,agent_session:$i.agent_session,agent_status:"idle",cwd:$cwd,foreground_cwd:$cwd,state_change_seq:1};
      [agent($r[0].requester;"wTest";"tTest";$cwd),
       (agent($r[0].worker_identity;"wDispatch";"tWorker";$cwd)+{name:$name}),
       (agent($r[0].workspace_launch.identity;"wDispatch";"tDispatch";$repo)+{name:"dispatcher"})] as $agents |
      [{persistent:true,argv:["agent","list"],status:0,stdout:{id:"flow",result:{type:"agent_list",agents:$agents}},stderr:null},
       {persistent:true,argv:["pane","current","--current"],status:0,stdout:{id:"flow",result:{type:"pane_current",pane:$agents[0]}},stderr:null},
       {persistent:true,argv:["workspace","list"],status:0,stdout:{id:"flow",result:{type:"workspace_list",workspaces:[{workspace_id:"wDispatch"}]}},stderr:null},
       {persistent:true,argv:["tab","list","--workspace","wDispatch"],status:0,stdout:{id:"flow",result:{type:"tab_list",tabs:[{workspace_id:"wDispatch",tab_id:"tWorker"},{workspace_id:"wDispatch",tab_id:"tDispatch"}]}},stderr:null}] +
      ([$r[0].requester,$r[0].worker_identity,$r[0].workspace_launch.identity] | map(. as $i |
       {persistent:true,argv:["pane","process-info","--pane",$i.pane_id],status:0,stdout:{id:"flow",result:{type:"pane_process_info",process_info:{pane_id:$i.pane_id,foreground_process_group_id:$i.foreground_process_group_id,foreground_processes:[{pid:9999}]}}},stderr:null}))' > "$FAKE_HERDR_SCENARIO"
}
flow_patch() { jq "$1" "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"; mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"; }
flow_status() {
    local target=$1 state=$2
    flow_patch "map(if .argv == [\"agent\",\"list\"] then .stdout.result.agents |= map(if .pane_id == \"$target\" then .agent_status=\"$state\" else . end) else . end)"
}
flow_caller() {
    local target=$1
    jq --arg target "$target" '(.[0].stdout.result.agents | map(select(.pane_id==$target))[0]) as $a | map(if .argv == ["pane","current","--current"] then .stdout.result.pane=$a else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
}
flow_prompt_rule() {
    local target=$1 message=$2 mode=${3:-ok}
    jq --arg target "$target" --arg message "$message" --arg mode "$mode" '
      (.[0].stdout.result.agents | map(select(.pane_id==$target))[0]) as $a |
      . + [{argv:["agent","prompt",$target,$message,"--wait","--until","working","--timeout",{timeout_ms:true}],status:(if $mode=="ok" then 0 else 1 end),stdout:(if $mode=="ok" then {id:"flow",result:{type:"agent_prompted",agent:($a|.agent_status="working")}} else null end),stderr:(if $mode=="ok" then null else {error:{code:"timeout",message:"Synthetic submitted timeout"}} end),after_agent_status:"working"}]' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
}
flow_cas() {
    local patch=$1 revision state
    helper run-state get run "$RUN_ID"; expect_status 0
    revision=$(jq -r .result.document.revision "$TEST_ROOT/helper.json")
    state=$(jq -r .result.document.state "$TEST_ROOT/helper.json")
    jq --arg at "$TEST_NOW" ".result.document | $patch" "$TEST_ROOT/helper.json" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision "$revision" --expect-state "$state" --document "$TEST_ROOT/candidate.json" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
}
flow_assign() {
    helper spawn worker --role "${FLOW_NAME%-1}" --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.reused'
    helper run-state assign "$RUN_ID" --worker "$FLOW_NAME" --expect-revision 0 --expect-worker-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
    jq .assignment "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/assignment-snapshot"
    FLOW_WORKER=$(jq -c .assignment.worker "$RUN_ROOT/$RUN_ID/status")
}
flow_send() {
    local mode=${1:-ok}
    FLOW_BRIEF="Synthetic brief $RUN_ID $(jq -r .assignment.assignment_id "$RUN_ROOT/$RUN_ID/status")"
    flow_prompt_rule wDispatch:p2 "$FLOW_BRIEF" "$mode"
    helper ring "$FLOW_NAME" "$FLOW_BRIEF" --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"
    if [ "$mode" = ok ]; then
        expect_status 0
        assert_json "$TEST_ROOT/helper.json" '.outcome == "input-accepted" and .result.observed_status == "working"'
        flow_cas '.delivery.phase="sent" | .delivery.acknowledged_at=$at'
    else expect_status 5; fi
}
flow_report() {
    local metadata
    metadata=$(jq -c --arg at "$TEST_NOW" '{schema_version:1,run_id,worker_name:.assignment.worker_name,assignment_id:.assignment.assignment_id,worker:.assignment.worker,created_at:$at}' "$RUN_ROOT/$RUN_ID/status")
    markdown "$RUN_ROOT/$RUN_ID/result.md.tmp" "$metadata" "$(< "$TEST_REPO/tests/fixtures/reports/${FLOW_NAME%-1}.md")"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].result_valid == false'
    [ ! -e "$RUN_ROOT/$RUN_ID/result.md" ] || fail 'final report already exists'
    mv "$RUN_ROOT/$RUN_ID/result.md.tmp" "$RUN_ROOT/$RUN_ID/result.md"
    cp "$RUN_ROOT/$RUN_ID/result.md" "$TEST_ROOT/result-snapshot"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].result_valid'
}
flow_done() { flow_cas '.state="done" | .notice.type="RESULT" | .notice.phase="pending"'; }
flow_notice_start() {
    local token
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    flow_cas ".notice.phase=\"pending\" | .notice.in_flight=true | .notice.attempts+=1 | .notice.attempt_id=\"$token\" | .notice.last_attempt_at=\$at"
}
flow_relay() {
    flow_notice_start
    flow_caller wDispatch:p1
    flow_prompt_rule wTest:p1 "RESULT $RUN_ID $RUN_ROOT/$RUN_ID/result.md"
    helper ring wTest:p1 "RESULT $RUN_ID $RUN_ROOT/$RUN_ID/result.md" --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
    flow_cas '.state="relayed" | .notice.phase="sent" | .notice.in_flight=false | .notice.last_outcome="input-accepted"'
}
flow_sync() {
    helper run-state worker-sync "$FLOW_NAME" --expect-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
}
# Repeat a bell's scan and a forbidden duplicate assignment at every scenario end.
flow_invariants() {
    local revision before
    registry_ok
    before=$(jq -c .assignment "$RUN_ROOT/$RUN_ID/status")
    revision=$(jq -r .revision "$RUN_ROOT/$RUN_ID/status")
    helper run-state assign "$RUN_ID" --worker "$FLOW_NAME" --expect-revision "$revision" --expect-worker-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_equal "$before" "$(jq -c .assignment "$RUN_ROOT/$RUN_ID/status")"
    if [ -f "$TEST_ROOT/assignment-snapshot" ]; then
        assert_equal "$(jq -c . "$TEST_ROOT/assignment-snapshot")" "$(jq -c .assignment "$RUN_ROOT/$RUN_ID/status")"
    fi
    cmp "$TEST_ROOT/request-snapshot" "$RUN_ROOT/$RUN_ID/request.md"
    if [ -f "$TEST_ROOT/result-snapshot" ]; then cmp "$TEST_ROOT/result-snapshot" "$RUN_ROOT/$RUN_ID/result.md"; fi
    jq -se --argjson closed "${FLOW_CLOSED:-false}" 'all(.[]; if .argv[0:2]==["agent","prompt"] then (.target | IN("wTest:p1","wDispatch:p1","wDispatch:p2")) elif .argv[0:2]==["pane","close"] then $closed and .target=="wDispatch:p2" else .argv[0:2]!=["tab","close"] end)' "$FAKE_HERDR_LOG" >/dev/null || fail 'unowned prompt or unexpected close'
}
flow_assert_no_prompt_or_close() {
    assert_equal 0 "$(ring_prompt_count)"
    jq -se 'all(.[];
        .argv == ["agent","list"] or
        (.argv[0:2] == ["agent","get"] and (.argv | length) == 3) or
        (.argv[0:2] == ["agent","read"] and (.argv | length) == 7 and .argv[3] == "--source" and .argv[5] == "--lines") or
        .argv == ["pane","current","--current"] or
        (.argv[0:2] == ["pane","process-info"] and (.argv | length) == 4 and .argv[2] == "--pane") or
        .argv == ["workspace","list"] or
        (.argv[0:3] == ["tab","list","--workspace"] and (.argv | length) == 4)
    )' "$FAKE_HERDR_LOG" >/dev/null || fail 'unexpected non-read-only CLI command'
}
flow_round_trip() {
    flow_setup "$1"; flow_assign; flow_send; flow_report
    flow_caller wDispatch:p2
    flow_prompt_rule wDispatch:p1 "DONE $RUN_ID"
    helper ring dispatcher "DONE $RUN_ID" --expected-session "$(jq -c .identity "$RUN_ROOT/.dispatcher.json")" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
    flow_done; flow_relay; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase=="held"'
    flow_status wDispatch:p2 idle; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="relayed" and .worker_release.phase=="released"'
    helper spawn worker --role "$1" --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.reused'
    flow_invariants
}
review_round_trip() { flow_round_trip review; }
explore_round_trip() { flow_round_trip explore; }
restart_after_send() {
    flow_setup; flow_assign
    local delivery_attempt assignment_id replacement_attempt
    delivery_attempt=$(jq -r .delivery.attempt_id "$RUN_ROOT/$RUN_ID/status")
    assignment_id=$(jq -r .assignment.assignment_id "$RUN_ROOT/$RUN_ID/status")
    FLOW_BRIEF="Synthetic brief $RUN_ID"
    flow_prompt_rule wDispatch:p2 "$FLOW_BRIEF"
    helper ring "$FLOW_NAME" "$FLOW_BRIEF" --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.outcome=="input-accepted"'
    # A restart before the post-send CAS leaves the durable attempt as sending.
    jq -e --arg token "$delivery_attempt" --arg assignment "$assignment_id" '.delivery.phase=="sending" and .delivery.attempt_id==$token and .assignment.assignment_id==$assignment' "$RUN_ROOT/$RUN_ID/status" >/dev/null || fail 'delivery attempt or assignment changed after successful ring'
    assert_equal 1 "$(ring_prompt_count)"

    # Simulate a later turn: inspect durable state, but do not replay a prompt
    # or assign replacement work while the attempt is unresolved and no report exists.
    [ ! -e "$RUN_ROOT/$RUN_ID/result.md" ] || fail 'unresolved attempt has a report'
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].result_valid==false'
    flow_sync; registry_ok
    jq -e --arg token "$delivery_attempt" --arg assignment "$assignment_id" '.state=="dispatched" and .delivery.phase=="sending" and .delivery.attempt_id==$token and .assignment.assignment_id==$assignment' "$RUN_ROOT/$RUN_ID/status" >/dev/null || fail 'later turn changed the unresolved delivery or assignment'

    # A fresh sending token must not replace an unresolved delivery attempt.
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before-rejected-delivery-retry"
    replacement_attempt=$delivery_attempt
    if [ "${replacement_attempt:0:1}" = 0 ]; then replacement_attempt="1${replacement_attempt:1}"; else replacement_attempt="0${replacement_attempt:1}"; fi
    jq --arg token "$replacement_attempt" --arg at "$TEST_NOW" '.delivery={phase:"sending",attempt_id:$token,started_at:$at,acknowledged_at:null,error:null}' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision "$(jq -r .revision "$RUN_ROOT/$RUN_ID/status")" --expect-state dispatched --document "$TEST_ROOT/candidate.json" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="invariant_violation"'
    cmp "$TEST_ROOT/status-before-rejected-delivery-retry" "$RUN_ROOT/$RUN_ID/status"
    jq -e --arg token "$delivery_attempt" --arg assignment "$assignment_id" '.delivery.phase=="sending" and .delivery.attempt_id==$token and .assignment.assignment_id==$assignment' "$RUN_ROOT/$RUN_ID/status" >/dev/null || fail 'rejected delivery retry changed its attempt or assignment'
    assert_equal 1 "$(ring_prompt_count)"
    flow_invariants
    assert_equal 1 "$(ring_prompt_count)"
}
lost_bell_then_reconcile() {
    flow_setup; flow_assign; flow_send; flow_report
    # No DONE input. A fresh registry discovers the final file.
    registry_ok; flow_done; flow_relay; flow_status wDispatch:p2 idle; flow_sync; flow_invariants
}
role_queue_preserved() {
    flow_setup; flow_assign; flow_send
    flow_caller wTest:p1
    helper new-run --cwd "$TEST_ROOT/work" --role review --body-file "$TEST_ROOT/body.md"; expect_status 0
    local queued
    queued=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="capacity_full"'
    assert_json "$RUN_ROOT/$queued/status" '.state=="new" and .assignment==null'
    flow_report; flow_done; flow_invariants
}
result_before_worker_idle() {
    flow_setup; flow_assign; flow_send; flow_report; flow_done; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase=="held"'
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    flow_status wDispatch:p2 idle; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase=="released"'
    flow_invariants
}
busy_requester_relay_deferred() {
    flow_setup; flow_assign; flow_send; flow_report; flow_done; flow_notice_start
    flow_status wTest:p1 working; flow_caller wDispatch:p1
    helper ring wTest:p1 "RESULT $RUN_ID $RUN_ROOT/$RUN_ID/result.md" --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms 2000; expect_status 4
    flow_cas '.notice.in_flight=false | .notice.last_outcome="not-submitted"'
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="done" and .notice.phase=="pending"'
    assert_equal 1 "$(ring_prompt_count)"
    flow_status wDispatch:p2 idle; flow_sync
    flow_status wTest:p1 idle; flow_relay; flow_invariants
}
replaced_requester_not_prompted() {
    flow_setup; flow_assign; flow_send; flow_report; flow_done; flow_notice_start
    flow_patch 'map(if .argv==["agent","list"] then .stdout.result.agents[0].agent_session.value="/replacement.jsonl" else . end)'
    flow_caller wDispatch:p1
    helper ring wTest:p1 "RESULT $RUN_ID $RUN_ROOT/$RUN_ID/result.md" --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    flow_cas '.notice.in_flight=false | .notice.phase="missing-requester" | .notice.last_outcome="missing-requester" | .human.missing_requester=true'
    assert_equal 1 "$(ring_prompt_count)"
    flow_status wDispatch:p2 idle; flow_sync; flow_invariants
}
flow_nudge() {
    local mode=${1:-ok}
    flow_status wDispatch:p2 idle
    # The Herdr CLI renders agent-read output as text, not a JSON envelope.
    flow_patch '. + [{persistent:true,argv:["agent","read","wDispatch:p2","--source","visible","--lines","120"],status:0,stdout:"Synthetic settled output without report",stderr:null}]'
    flow_cas '.nudge.phase="sending" | .nudge.attempt_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" | .nudge.started_at=$at'
    flow_prompt_rule wDispatch:p2 "Publish the missing report for $RUN_ID. Do not repeat the job." "$mode"
    helper ring "$FLOW_NAME" "Publish the missing report for $RUN_ID. Do not repeat the job." --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"
    if [ "$mode" = ok ]; then expect_status 0; flow_cas '.nudge.phase="sent" | .nudge.acknowledged_at=$at'; else expect_status 5; flow_cas '.nudge.phase="uncertain"'; fi
}
nudge_only_once() {
    flow_setup; flow_assign; flow_send; flow_nudge
    registry_ok; flow_sync
    assert_equal 2 "$(ring_prompt_count)"
    flow_status wDispatch:p2 idle
    jq '.nudge.phase="sending" | .nudge.attempt_id="cccccccccccccccccccccccccccccccc" | .nudge.acknowledged_at=null' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision "$(jq -r .revision "$RUN_ROOT/$RUN_ID/status")" --document "$TEST_ROOT/candidate.json"; expect_status 3
    assert_equal 2 "$(ring_prompt_count)"; flow_invariants
}
completed_result_survives_worker_exit() {
    flow_setup; flow_assign; flow_send; flow_report; flow_gone_worker; flow_done; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase=="retired"'
    flow_relay; flow_invariants
}
flow_gone_worker() {
    flow_patch 'map(if .argv==["agent","list"] then .stdout.result.agents |= map(select(.pane_id!="wDispatch:p2")) else . end) + [{persistent:true,argv:["agent","get","wDispatch:p2"],status:1,stdout:null,stderr:{error:{code:"pane_not_found",message:"Synthetic missing"}}}]'
}
relayed_worker_released_on_later_turn() {
    flow_setup; flow_assign; flow_send; flow_report; flow_done; flow_relay; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="relayed" and .worker_release.phase=="held"'
    flow_status wDispatch:p2 idle; flow_sync
    local first
    first=$(jq -r .idle_since "$RUN_ROOT/.workers/$FLOW_NAME")
    flow_sync; assert_equal "$first" "$(jq -r .idle_since "$RUN_ROOT/.workers/$FLOW_NAME")"; flow_invariants
}
gone_requester_does_not_hold_capacity() {
    flow_setup; flow_assign; flow_send; flow_report; flow_done
    local requester target get_status
    requester=$(jq -c .requester "$TEST_ROOT/records.json")
    target=$(printf '%s\n' "$requester" | jq -r .pane_id)
    flow_patch 'map(if .argv==["agent","list"] then .stdout.result.agents |= map(select(.pane_id!="wTest:p1")) else . end)'
    flow_caller wDispatch:p1
    assert_json "$FAKE_HERDR_SCENARIO" '.[0].stdout.result.agents | all(.[]; .pane_id!="wTest:p1")'
    assert_json "$FAKE_HERDR_SCENARIO" 'any(.[]; .argv==["pane","current","--current"] and .stdout.result.pane.pane_id=="wDispatch:p1")'
    flow_notice_start
    helper ring "$target" "RESULT $RUN_ID $RUN_ROOT/$RUN_ID/result.md" --expected-session "$requester" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_equal 1 "$(ring_prompt_count)"

    # Missing from a successful inventory is not enough. Require explicit pane-not-found proof.
    jq --arg target "$target" '. + [{persistent:true,argv:["agent","get",$target],status:1,stdout:null,stderr:{id:"flow",error:{code:"pane_not_found",message:"Synthetic missing requester"}}}]' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    get_status=0
    herdr agent get "$target" > "$TEST_ROOT/requester-get.out" 2> "$TEST_ROOT/requester-get.err" || get_status=$?
    assert_equal 1 "$get_status"
    assert_json "$TEST_ROOT/requester-get.err" '.error.code=="pane_not_found"'
    jq -se --arg target "$target" 'any(.[]; .argv==["agent","get",$target])' "$FAKE_HERDR_LOG" >/dev/null || fail 'saved requester absence was not checked'
    flow_cas '.notice.phase="missing-requester" | .notice.in_flight=false | .notice.last_outcome="missing-requester" | .human.missing_requester=true'
    flow_status wDispatch:p2 idle; flow_sync
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.reused'; flow_invariants
}
unknown_worker_not_reassigned() {
    flow_setup; flow_assign; flow_send; flow_status wDispatch:p2 unknown
    helper run-state worker-sync "$FLOW_NAME" --expect-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="quarantine"'
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase=="held"'; flow_invariants
}
flow_fail() { flow_cas '.state="failed" | .error={code:"worker_gone",message:"Synthetic failure",at:$at} | .notice.type="FAILED" | .notice.phase="pending"'; }
failed_late_result_preserved() {
    flow_setup; flow_assign; flow_send; flow_gone_worker; flow_fail; flow_report
    flow_cas '.human.late_result=true'
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="failed" and .notice.type=="FAILED" and .human.late_result'
    flow_sync; flow_invariants
}
nudge_timeout_not_resent() {
    flow_setup; flow_assign; flow_send; flow_nudge timeout
    registry_ok; flow_status wDispatch:p2 idle; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.nudge.phase=="uncertain" and .state=="dispatched"'
    assert_equal 2 "$(ring_prompt_count)"; flow_invariants
}

blocked_assigned_worker_quarantined() {
    flow_setup; flow_assign
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before-blocked-sync"
    cp "$RUN_ROOT/.workers/$FLOW_NAME" "$TEST_ROOT/worker-before-blocked-sync"
    flow_status wDispatch:p2 blocked
    helper run-state worker-sync "$FLOW_NAME" --expect-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="quarantine"'
    flow_caller wDispatch:p1
    helper ring "$FLOW_NAME" "Do not prompt a blocked worker" --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="target_not_ready"'
    cmp "$TEST_ROOT/status-before-blocked-sync" "$RUN_ROOT/$RUN_ID/status"
    cmp "$TEST_ROOT/worker-before-blocked-sync" "$RUN_ROOT/.workers/$FLOW_NAME"
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="dispatched" and .worker_release.phase=="held" and .assignment!=null'
    flow_assert_no_prompt_or_close
    flow_invariants
}

malformed_run_inventory_blocks_assignment() {
    flow_setup
    local malformed records
    malformed=20261014T140001Z-fedcba9876543210
    records=$(state_fixture "$malformed")
    mkdir "$RUN_ROOT/$malformed"
    markdown "$RUN_ROOT/$malformed/request.md" "$(printf '%s\n' "$records" | jq -c .request)" "$(< "$TEST_ROOT/body.md")"
    printf '{malformed status\n' > "$RUN_ROOT/$malformed/status"
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before-malformed-inventory"
    cp "$RUN_ROOT/.workers/$FLOW_NAME" "$TEST_ROOT/worker-before-malformed-inventory"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs | any(.run_id=="20261014T140001Z-fedcba9876543210" and .classification=="quarantined")'
    assert_json "$TEST_ROOT/helper.json" 'any(.result.issues[]; .code=="malformed_run")'
    helper run-state assign "$RUN_ID" --worker "$FLOW_NAME" --expect-revision 0 --expect-worker-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="quarantine"'
    cmp "$TEST_ROOT/status-before-malformed-inventory" "$RUN_ROOT/$RUN_ID/status"
    cmp "$TEST_ROOT/worker-before-malformed-inventory" "$RUN_ROOT/.workers/$FLOW_NAME"
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="new" and .assignment==null'
    flow_assert_no_prompt_or_close
    flow_invariants
}

worker_launch_ownership_mismatch_blocks_assignment_and_reuse() {
    flow_setup
    local journal
    journal="$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    cp "$RUN_ROOT/.workers/$FLOW_NAME" "$TEST_ROOT/worker-before-ownership-mismatch"
    jq '.ownership_token="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$journal" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$journal"
    cp "$journal" "$TEST_ROOT/launch-after-ownership-mismatch"
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers | any(.name=="review-1" and .classification=="quarantined")'
    assert_json "$TEST_ROOT/helper.json" 'any(.result.issues[]; .code=="ownership_conflict")'
    helper run-state assign "$RUN_ID" --worker "$FLOW_NAME" --expect-revision 0 --expect-worker-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="quarantine"'
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="quarantine"'
    cmp "$TEST_ROOT/worker-before-ownership-mismatch" "$RUN_ROOT/.workers/$FLOW_NAME"
    cmp "$TEST_ROOT/launch-after-ownership-mismatch" "$journal"
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="new" and .assignment==null'
    flow_assert_no_prompt_or_close
    flow_invariants
}

held_worker_cannot_be_claimed_by_second_run() {
    flow_setup; flow_assign
    local queued
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/original-assigned-status"
    cp "$RUN_ROOT/.workers/$FLOW_NAME" "$TEST_ROOT/original-occupied-worker"
    jq --arg at "$TEST_NOW" '.lifecycle="idle" | .active_run_id=null | .idle_since=$at' "$RUN_ROOT/.workers/$FLOW_NAME" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/$FLOW_NAME"
    assert_json "$RUN_ROOT/.workers/$FLOW_NAME" '.lifecycle=="idle" and .active_run_id==null and .idle_since==env.TEST_NOW'
    assert_equal "$(jq -c '{revision,ownership}' "$TEST_ROOT/original-occupied-worker")" "$(jq -c '{revision,ownership}' "$RUN_ROOT/.workers/$FLOW_NAME")"
    flow_caller wTest:p1
    helper new-run --cwd "$TEST_ROOT/work" --role review --body-file "$TEST_ROOT/body.md" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
    queued=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/held-run-before-second-assignment"
    cp "$RUN_ROOT/$queued/status" "$TEST_ROOT/queued-run-before-second-assignment"
    cp "$RUN_ROOT/.workers/$FLOW_NAME" "$TEST_ROOT/idle-worker-before-second-assignment"
    helper run-state assign "$queued" --worker "$FLOW_NAME" --expect-revision 0 --expect-worker-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.ok==false and .error.code=="conflict" and .error.message=="Worker already has a held assignment"'
    cmp "$TEST_ROOT/held-run-before-second-assignment" "$RUN_ROOT/$RUN_ID/status"
    cmp "$TEST_ROOT/queued-run-before-second-assignment" "$RUN_ROOT/$queued/status"
    cmp "$TEST_ROOT/idle-worker-before-second-assignment" "$RUN_ROOT/.workers/$FLOW_NAME"
    cmp "$TEST_ROOT/original-assigned-status" "$RUN_ROOT/$RUN_ID/status"
    assert_json "$RUN_ROOT/$queued/status" '.state=="new" and .assignment==null and .revision==0'
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.workers | any(.name=="review-1" and .classification=="occupied" and (.occupancy_run_ids|length)==1)'
    assert_equal "$RUN_ID" "$(jq -r '.result.workers[] | select(.name=="review-1") | .occupancy_run_ids[0]' "$TEST_ROOT/helper.json")"
    flow_assert_no_prompt_or_close
    flow_invariants
}

direct_cas_cannot_mutate_assignment_snapshot() {
    flow_setup; flow_assign
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before-assignment-cas"
    cp "$RUN_ROOT/.workers/$FLOW_NAME" "$TEST_ROOT/worker-before-assignment-cas"
    jq '.assignment.assignment_id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision "$(jq -r .revision "$RUN_ROOT/$RUN_ID/status")" --expect-state dispatched --document "$TEST_ROOT/candidate.json" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code=="invariant_violation"'
    cmp "$TEST_ROOT/status-before-assignment-cas" "$RUN_ROOT/$RUN_ID/status"
    cmp "$TEST_ROOT/worker-before-assignment-cas" "$RUN_ROOT/.workers/$FLOW_NAME"
    flow_assert_no_prompt_or_close
    flow_invariants
}

uncertain_nudge_blocks_retry_and_failure() {
    flow_setup; flow_assign; flow_send; flow_nudge timeout
    flow_status wDispatch:p2 idle; flow_sync
    assert_json "$RUN_ROOT/$RUN_ID/status" '.nudge.phase=="uncertain" and .nudge.attempt_id=="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and .state=="dispatched"'
    assert_equal 2 "$(ring_prompt_count)"

    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before-rejected-actions"
    jq --arg at "$TEST_NOW" '.nudge.phase="sending" | .nudge.attempt_id="cccccccccccccccccccccccccccccccc" | .nudge.started_at=$at | .nudge.acknowledged_at=null | .nudge.error=null' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision "$(jq -r .revision "$RUN_ROOT/$RUN_ID/status")" --expect-state dispatched --document "$TEST_ROOT/candidate.json" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    cmp "$TEST_ROOT/status-before-rejected-actions" "$RUN_ROOT/$RUN_ID/status"
    assert_equal 2 "$(ring_prompt_count)"

    jq --arg at "$TEST_NOW" '.state="failed" | .error={code:"missing_report",message:"Synthetic missing report",at:$at} | .notice.type="FAILED" | .notice.phase="pending"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/candidate.json"
    helper run-state cas run "$RUN_ID" --expect-revision "$(jq -r .revision "$RUN_ROOT/$RUN_ID/status")" --expect-state dispatched --document "$TEST_ROOT/candidate.json" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 3
    cmp "$TEST_ROOT/status-before-rejected-actions" "$RUN_ROOT/$RUN_ID/status"
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="dispatched" and .nudge.phase=="uncertain" and .nudge.attempt_id=="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and .notice.phase=="none"'
    assert_equal "$(jq -c . "$TEST_ROOT/assignment-snapshot")" "$(jq -c .assignment "$RUN_ROOT/$RUN_ID/status")"
    assert_equal 2 "$(ring_prompt_count)"
    flow_invariants
}

missing_report_failure_relayed_to_saved_requester() {
    flow_setup; flow_assign; flow_send; flow_nudge
    # flow_nudge reads scripted visible output before sending. Start a separate
    # simulated turn with fresh registry and status reads before settling it.
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="dispatched" and .nudge.phase=="sent" and .nudge.settled_observed_at==null'
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].result_valid==false and .result.runs[0].status.nudge.phase=="sent"'
    helper run-state get run "$RUN_ID"; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.document.nudge.phase=="sent" and .result.document.nudge.settled_observed_at==null'

    flow_status wDispatch:p2 idle
    # The later turn rereads visible output. No model action decides the result.
    sleep 1
    herdr agent read wDispatch:p2 --source visible --lines 120 > "$TEST_ROOT/later-turn-output.txt"
    assert_equal 'Synthetic settled output without report' "$(< "$TEST_ROOT/later-turn-output.txt")"
    flow_cas '.nudge.settled_observed_at=$at'
    jq -e '.nudge.phase=="sent" and .nudge.settled_observed_at > .nudge.acknowledged_at' "$RUN_ROOT/$RUN_ID/status" >/dev/null || fail 'later settled observation was not recorded'
    registry_ok
    assert_json "$TEST_ROOT/helper.json" '.result.runs[0].result_valid==false and .result.runs[0].status.nudge.settled_observed_at!=null'
    helper run-state get run "$RUN_ID"; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.document.nudge.phase=="sent" and .result.document.nudge.settled_observed_at!=null'
    flow_cas '.state="failed" | .error={code:"missing_report",message:"Synthetic missing report",at:$at} | .notice.type="FAILED" | .notice.phase="pending"'
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="failed" and .error.code=="missing_report" and .notice.type=="FAILED" and .notice.phase=="pending"'
    [ ! -e "$RUN_ROOT/$RUN_ID/result.md" ] || fail 'missing-report failure has a result'

    local requester target message notice_attempt
    helper run-state check-notice "$RUN_ID" FAILED "$RUN_ROOT/$RUN_ID/status" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
    requester=$(awk 'NR == 2 {print; exit}' "$RUN_ROOT/$RUN_ID/request.md" | jq -c .requester)
    target=$(printf '%s\n' "$requester" | jq -r .pane_id)
    message="FAILED $RUN_ID $RUN_ROOT/$RUN_ID/status"
    flow_notice_start
    notice_attempt=$(jq -r .notice.attempt_id "$RUN_ROOT/$RUN_ID/status")
    jq -e --arg token "$notice_attempt" '.notice.in_flight and .notice.attempts==1 and .notice.attempt_id==$token and ($token|test("^[0-9a-f]{32}$"))' "$RUN_ROOT/$RUN_ID/status" >/dev/null || fail 'FAILED notice attempt token was not saved before ring'
    flow_caller wDispatch:p1
    flow_prompt_rule "$target" "$message"
    helper ring "$target" "$message" --expected-session "$requester" --timeout-ms "$FLOW_TIMEOUT_MS"
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.outcome=="input-accepted"'
    flow_cas '.notice.in_flight=false | .notice.phase="sent" | .notice.last_outcome="input-accepted"'
    jq -e --arg token "$notice_attempt" '.state=="failed" and .notice.type=="FAILED" and .notice.phase=="sent" and .notice.last_outcome=="input-accepted" and .notice.attempt_id==$token' "$RUN_ROOT/$RUN_ID/status" >/dev/null || fail 'FAILED notice outcome did not retain its attempt token'
    jq -se --arg target "$target" --arg message "$message" 'any(.[]; .argv[0:2]==["agent","prompt"] and .target==$target and .argv[3]==$message)' "$FAKE_HERDR_LOG" >/dev/null || fail 'FAILED notice did not reach the saved requester'
    assert_equal 3 "$(ring_prompt_count)"
    assert_equal "$(jq -c . "$TEST_ROOT/assignment-snapshot")" "$(jq -c .assignment "$RUN_ROOT/$RUN_ID/status")"
    flow_invariants
}
flow_retire() {
    # A close rule is added only after independent settled/ownership checks.
    assert_json "$RUN_ROOT/.workers/$FLOW_NAME" '.ownership.mode=="created" and .identity.pane_id=="wDispatch:p2"'
    assert_json "$FAKE_HERDR_SCENARIO" '.[0].stdout.result.agents | any(.[]; .pane_id=="wDispatch:p2" and (.agent_status=="idle" or .agent_status=="done"))'
    flow_patch '. + [{argv:["pane","close","wDispatch:p2"],status:0,stdout:{id:"flow",result:{type:"pane_closed"}},stderr:null,after_agent_list:[.[0].stdout.result.agents[] | select(.pane_id!="wDispatch:p2")]}]'
    helper run-state retire-worker "$FLOW_NAME" --expect-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
    FLOW_CLOSED=true
    jq -se '[.[] | select(.argv[0:2]==["pane","close"])] | length==1' "$FAKE_HERDR_LOG" >/dev/null
}
ttl_cleanup_only_owned_idle() {
    flow_setup; flow_assign; flow_send; flow_report; flow_done
    # Zero TTL does not permit closure while work is active.
    jq '.idle_ttl_seconds=0' "$HERDR_DISPATCHER_CONFIG" > "$TEST_ROOT/next.json"; mv "$TEST_ROOT/next.json" "$HERDR_DISPATCHER_CONFIG"
    helper run-state retire-worker "$FLOW_NAME" --expect-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    flow_status wDispatch:p2 idle; flow_sync; flow_retire; flow_invariants
}
failed_worker_retired_only_when_settled() {
    flow_setup; flow_assign; flow_send; flow_gone_worker; flow_fail
    # The saved occupant appears again, but is working. Failure is not reuse permission.
    flow_live; flow_status wDispatch:p2 working
    helper run-state retire-worker "$FLOW_NAME" --expect-revision "$(jq -r .revision "$RUN_ROOT/.workers/$FLOW_NAME")" --expected-session "$FLOW_WORKER" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 3
    flow_status wDispatch:p2 idle; flow_retire
    assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="failed" and .worker_release.phase=="retired"'
    flow_invariants
}
failed_notice_retry_fair() {
    flow_setup; flow_assign; flow_send; flow_gone_worker; flow_fail
    local original second order id
    original=$RUN_ID
    flow_notice_start; flow_cas '.notice.in_flight=false | .notice.last_outcome="uncertain"'
    flow_caller wTest:p1
    helper new-run --cwd "$TEST_ROOT/work" --role invalid --body-file "$TEST_ROOT/body.md"; expect_status 0
    second=$(jq -r .result.run_id "$TEST_ROOT/helper.json")
    RUN_ID=$second
    flow_cas '.state="failed" | .error={code:"invalid_role",message:"Synthetic invalid role",at:$at} | .notice.type="FAILED" | .notice.phase="pending"'
    registry_ok
    order=$(jq -r '[.result.runs[] | select(.status.notice.phase=="pending")] | sort_by(.status.notice.last_attempt_at,.request.created_at,.run_id) | .[].run_id' "$TEST_ROOT/helper.json")
    assert_equal "$second" "$(printf '%s\n' "$order" | head -1)"
    flow_caller wDispatch:p1
    for id in $order; do
        RUN_ID=$id
        flow_notice_start; flow_status wTest:p1 idle
        flow_prompt_rule wTest:p1 "FAILED $RUN_ID $RUN_ROOT/$RUN_ID/status"
        helper ring wTest:p1 "FAILED $RUN_ID $RUN_ROOT/$RUN_ID/status" --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms "$FLOW_TIMEOUT_MS"; expect_status 0
        flow_cas '.notice.in_flight=false | .notice.phase="sent" | .notice.last_outcome="input-accepted"'
        assert_json "$RUN_ROOT/$RUN_ID/status" '.state=="failed"'
    done
    assert_equal "FAILED $second $RUN_ROOT/$second/status" "$(jq -sr '[.[] | select(.argv[0:2]==["agent","prompt"] and (.argv[3]|startswith("FAILED ")))][0].argv[3]' "$FAKE_HERDR_LOG")"
    RUN_ID=$original; flow_invariants
}
