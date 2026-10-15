#!/bin/bash
# Offline ring contracts. Sourced by run.sh.
ring_setup() {
    state_setup; owned_worker
    [ -d "$RUN_ROOT/$RUN_ID" ] || assigned_run
    : > "$FAKE_HERDR_LOG"
    EXPECTED=$(jq -c .worker_identity "$TEST_ROOT/records.json")
    MESSAGE=$'Full brief\n$(touch NEVER) `echo NO` "quoted" ; *\nFinal line'
    jq -n --slurpfile r "$TEST_ROOT/records.json" --arg cwd "$TEST_ROOT/work" --arg message "$MESSAGE" '
      def agent($i; $w; $t): {pane_id:$i.pane_id,terminal_id:$i.terminal_id,workspace_id:$w,tab_id:$t,agent:$i.kind,agent_session:$i.agent_session,agent_status:"idle",cwd:$cwd,state_change_seq:1};
      agent($r[0].requester;"wTest";"tTest") as $c |
      (agent($r[0].worker_identity;"wDispatch";"tWorker") + {name:"review-1"}) as $a |
      [{persistent:true,argv:["agent","list"],status:0,stdout:{id:"test",result:{type:"agent_list",agents:[$c,$a]}},stderr:null},
       {persistent:true,argv:["pane","current","--current"],status:0,stdout:{id:"test",result:{type:"pane_current",pane:$c}},stderr:null},
       {persistent:true,argv:["pane","process-info","--pane",$a.pane_id],status:0,stdout:{id:"test",result:{type:"pane_process_info",process_info:{pane_id:$a.pane_id,foreground_process_group_id:5200,foreground_processes:[{pid:5201}]}}},stderr:null},
       {argv:["agent","prompt",$a.pane_id,$message,"--wait","--until","working","--timeout",{timeout_ms:true}],status:0,stdout:{id:"test",result:{type:"agent_prompted",agent:($a | .agent_status="working")}},stderr:null,after_agent_status:"working"}]
    ' > "$FAKE_HERDR_SCENARIO"
    cp "$RUN_ROOT/$RUN_ID/status" "$TEST_ROOT/status-before"
}
ring_patch() { jq "$1" "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"; mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"; }
ring_call() { helper ring review-1 "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms "${1:-10000}"; }
ring_no_prompt() { assert_json "$TEST_ROOT/helper.json" '.outcome == "not-submitted" and .result.submitted == false'; assert_no_mutations; }
ring_prompt_count() { jq -s '[.[] | select(.argv[0:2] == ["agent","prompt"])] | length' "$FAKE_HERDR_LOG"; }
ring_lock_path() { printf '%s/.locks/pane-%s\n' "$RUN_ROOT" "$(printf '%s' wDispatch:p2 | od -An -tx1 | tr -d ' \n')"; }
ring_wait_lock() {
    local i
    for ((i=0;i<160;i++)); do [ ! -f "$(ring_lock_path)/owner.json" ] || return 0; sleep 0.02; done
    fail 'ring did not acquire pane lock'
}
ring_owner() {
    local pid=$1 started=$2
    mkdir "$(ring_lock_path)"
    jq -n --argjson pid "$pid" --arg started "$started" --arg at "$TEST_NOW" '{schema_version:1,pid:$pid,process_started_at:$started,token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",created_at:$at}' > "$(ring_lock_path)/owner.json"
}
ring_success_literal() {
    ring_setup; ring_call; expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.outcome == "input-accepted" and .result.submitted == true and .result.observed_status == "working" and .result.identity.foreground_process_group_id == 5200'
    assert_equal 1 "$(ring_prompt_count)"
    jq -se --arg message "$MESSAGE" 'any(.[]; .argv[0:2] == ["agent","prompt"] and .argv[3] == $message)' "$FAKE_HERDR_LOG" >/dev/null
    [ ! -e NEVER ] || fail 'message executed'
    cmp "$TEST_ROOT/status-before" "$RUN_ROOT/$RUN_ID/status"
    [ ! -d "$(ring_lock_path)" ] || fail 'lock retained'
}
busy_target_not_prompted() {
    ring_setup; ring_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[1].agent_status="working" else . end)'
    ring_call 2000; expect_status 4; ring_no_prompt
}
blocked_target_not_typed() {
    local state
    for state in blocked unknown; do
        ring_setup; ring_patch "map(if .argv == [\"agent\",\"list\"] then .stdout.result.agents[1].agent_status=\"$state\" else . end)"
        ring_call; expect_status 3; ring_no_prompt
    done
}
ring_parallel() {
    local target=$1 a b sa=0 sb=0
    ring_setup
    "$TEST_REPO/bin/ring" review-1 "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 10000 > "$TEST_ROOT/a.json" 2> "$TEST_ROOT/a.err" & a=$!
    "$TEST_REPO/bin/ring" "$target" "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 10000 > "$TEST_ROOT/b.json" 2> "$TEST_ROOT/b.err" & b=$!
    wait "$a" || sa=$?; wait "$b" || sb=$?
    assert_envelope "$TEST_ROOT/a.json"; assert_envelope "$TEST_ROOT/b.json"
    if [ "$sa:$sb" != 0:4 ] && [ "$sa:$sb" != 4:0 ]; then
        jq -c . "$TEST_ROOT/a.json" "$TEST_ROOT/b.json" >&2
        fail "parallel exits $sa:$sb"
    fi
    jq -se 'map(.outcome) | sort == ["input-accepted","not-submitted"]' "$TEST_ROOT/a.json" "$TEST_ROOT/b.json" >/dev/null
    assert_equal 1 "$(ring_prompt_count)"
    [ ! -d "$(ring_lock_path)" ] || fail 'shared pane lock retained'
}
concurrent_ringers_serialized() { ring_parallel review-1; }
alias_lock_shared() { ring_parallel wDispatch:p2; }
total_deadline_bounded() {
    ring_setup; ring_patch 'map(if .argv == ["agent","list"] then .delay_seconds=0.35 | .stdout.result.agents[1].agent_status="working" else . end)'
    TIMEFORMAT='%R'
    { time ring_call 2000; } 2> "$TEST_ROOT/elapsed"
    expect_status 4; ring_no_prompt
    assert_json "$TEST_ROOT/elapsed" '. <= 2.25'
}
hung_query_deadline_bounded() {
    ring_setup; ring_patch 'map(if .argv == ["pane","current","--current"] then .delay_seconds=2 else . end)'
    TIMEFORMAT='%R'
    { time ring_call 2000; } 2> "$TEST_ROOT/elapsed"
    expect_status 4; ring_no_prompt
    assert_json "$TEST_ROOT/elapsed" '. <= 2.25'
}
signal_releases_own_lock() {
    ring_setup; ring_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[1].agent_status="working" else . end)'
    local pid rc=0
    "$TEST_REPO/bin/ring" review-1 "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 10000 > "$TEST_ROOT/signal.json" 2> "$TEST_ROOT/signal.err" & pid=$!
    ring_wait_lock; kill -TERM "$pid"; wait "$pid" || rc=$?
    assert_equal 143 "$rc"
    [ ! -d "$(ring_lock_path)" ] || fail 'signal left own lock'
    assert_no_mutations
}
live_lock_not_stolen() {
    ring_setup
    ring_owner "$$" "$(LC_ALL=C ps -p "$$" -o lstart= | awk '{$1=$1;print}')"
    cp "$(ring_lock_path)/owner.json" "$TEST_ROOT/owner-before"
    ring_call 2000; expect_status 4; ring_no_prompt
    cmp "$TEST_ROOT/owner-before" "$(ring_lock_path)/owner.json"
}
dead_lock_recovered() {
    ring_setup
    local pid
    /bin/bash -c 'exit 0' & pid=$!; wait "$pid"
    ring_owner "$pid" 'dead owner'
    ring_call; expect_status 0; assert_equal 1 "$(ring_prompt_count)"
    [ ! -d "$(ring_lock_path)" ] || fail 'dead lock not released'
}
ambiguous_delivery_not_resent() {
    local patch
    for patch in '.stdout={result:{type:"agent_prompted"}}' '.status=1 | .stdout=null | .stderr={error:{code:"timeout"}}' '.status=1 | .stdout=null | .stderr={error:{code:"agent_prompt_stalled"}}' '.status=1 | .stdout=null | .stderr="transport failure"'; do
        ring_setup; ring_patch "map(if .argv[0:2] == [\"agent\",\"prompt\"] then $patch else . end)"
        ring_call; expect_status 5
        assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain" and .result.submitted == null'
        assert_equal 1 "$(ring_prompt_count)"
        cmp "$TEST_ROOT/status-before" "$RUN_ROOT/$RUN_ID/status"
    done
}
replaced_target_under_lock_not_prompted() {
    ring_setup
    local holder pid rc=0
    /bin/bash -c 'sleep 1' & holder=$!
    ring_owner "$holder" "$(LC_ALL=C ps -p "$holder" -o lstart= | awk '{$1=$1;print}')"
    "$TEST_REPO/bin/ring" review-1 "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 6000 > "$TEST_ROOT/helper.json" 2> "$TEST_ROOT/helper.err" & pid=$!
    local i
    for ((i=0;i<120;i++)); do [ "$(wc -l < "$FAKE_HERDR_LOG" | tr -d ' ')" -lt 4 ] || break; sleep 0.02; done
    # Wait for initial discovery to finish before replacing the process under the lock.
    sleep 0.1
    ring_patch 'map(if .argv[0:2] == ["pane","process-info"] then .stdout.result.process_info.foreground_process_group_id=5202 else . end)'
    wait "$holder"
    wait "$pid" || rc=$?
    assert_equal 3 "$rc"; assert_envelope "$TEST_ROOT/helper.json"; ring_no_prompt
}
self_target_rejected() {
    ring_setup
    export HERDR_PANE_ID=stale-inherited-pane
    ring_patch 'map(if .argv == ["pane","current","--current"] then .stdout.result.pane.pane_id="wDispatch:p2" | .stdout.result.pane.terminal_id="term_worker" else . end)'
    ring_call; expect_status 3; ring_no_prompt
    assert_json "$TEST_ROOT/helper.json" '.error.code == "self_target"'
}
ring_ownership_required() {
    ring_setup
    jq '.ownership.token="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$RUN_ROOT/.workers/review-1" > "$TEST_ROOT/next.json"; mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/review-1"
    ring_call; expect_status 3; ring_no_prompt
}
ring_expected_required() {
    ring_setup; helper ring review-1 RECONCILE --timeout-ms 6000
    expect_status 2; ring_no_prompt
}

released_dead_owner_retried() {
    ring_setup
    local pid
    /bin/bash -c 'exit 0' & pid=$!; wait "$pid"
    ring_owner "$pid" 'dead owner'
    # Release the saved dead owner after its snapshot, before reclaim reads.
    /bin/bash -c '
        source "$1/bin/lib.sh"
        hd_deadline_start 6000
        hd_config_load
        hd_process_start() {
            if [ "$1" = "$dead" ] && [ -f "$path/owner.json" ]; then
                hd_lock_release "$path" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || exit 3
            fi
            LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | awk '\''{$1=$1; print}'\''
        }
        dead=$2; path=$3
        hd_lock_acquire "$path" || exit $?
        hd_lock_release "$path" "$HD_LOCK_TOKEN"
    ' _ "$TEST_REPO" "$pid" "$(ring_lock_path)"
    [ ! -d "$(ring_lock_path)" ] || fail 'released owner retry retained lock'
}

worker_record_disappears_while_waiting() {
    ring_setup
    local pid rc=0
    ring_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[1].agent_status="working" else . end)'
    "$TEST_REPO/bin/ring" review-1 "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 10000 > "$TEST_ROOT/helper.json" 2> "$TEST_ROOT/helper.err" & pid=$!
    # This helper publishes its lock only after initial ownership validation.
    ring_wait_lock
    mv "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-removed.json"
    wait "$pid" || rc=$?
    assert_equal 3 "$rc"; assert_envelope "$TEST_ROOT/helper.json"; ring_no_prompt
}

requester_result_input_accepted() {
    ring_setup
    EXPECTED=$(jq -c .requester "$TEST_ROOT/records.json")
    MESSAGE="RESULT $RUN_ID $RUN_ROOT/$RUN_ID/result.md"
    jq --arg message "$MESSAGE" --argjson i "$EXPECTED" '
        .[0].stdout.result.agents[0] as $a |
        map(if .argv == ["pane","current","--current"] then .stdout.result.pane=$a
            elif .argv[0:2] == ["pane","process-info"] then .argv[3]=$a.pane_id | .stdout.result.process_info.pane_id=$a.pane_id | .stdout.result.process_info.foreground_process_group_id=$i.foreground_process_group_id
            elif .argv[0:2] == ["agent","prompt"] then .argv[2]=$a.pane_id | .argv[3]=$message | .stdout.result.agent=($a | .agent_status="working")
            else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    # shellcheck disable=SC2016
    ring_patch '.[0].stdout.result.agents[1] as $caller | map(if .argv == ["pane","current","--current"] then .stdout.result.pane=$caller else . end)'
    helper ring wTest:p1 "$MESSAGE" --expected-session "$EXPECTED" --timeout-ms 10000
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.outcome == "input-accepted" and .result.submitted == true and .result.observed_status == "working"'
    assert_equal 1 "$(ring_prompt_count)"
    cmp "$TEST_ROOT/status-before" "$RUN_ROOT/$RUN_ID/status"
}

registered_dispatcher_reconcile() {
    ring_setup
    MESSAGE=RECONCILE
    jq --arg cwd "$TEST_ROOT/repo" --arg config "$HERDR_DISPATCHER_CONFIG" '.worker | del(.role,.active_run_id,.idle_since) | .name="dispatcher" | .cwd=$cwd | .config_path=$config | .ownership={mode:"registered",token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",launch_id:null} | .lifecycle="ready"' "$TEST_ROOT/records.json" > "$RUN_ROOT/.dispatcher.json"
    mv "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-removed.json"
    jq --arg cwd "$TEST_ROOT/repo" --arg message "$MESSAGE" 'map(if .argv == ["agent","list"] then .stdout.result.agents[1].name="dispatcher" | .stdout.result.agents[1].cwd=$cwd elif .argv[0:2] == ["agent","prompt"] then .argv[3]=$message | .stdout.result.agent.name="dispatcher" | .stdout.result.agent.cwd=$cwd else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    helper ring dispatcher RECONCILE --timeout-ms 10000
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.outcome == "input-accepted" and .result.submitted == true and .result.observed_status == "working"'
    assert_equal 1 "$(ring_prompt_count)"
}

ring_common_options() {
    ring_setup
    "$TEST_REPO/bin/ring" --help > "$TEST_ROOT/help.txt"
    grep -F 'bin/ring' "$TEST_ROOT/help.txt" >/dev/null
    assert_equal 0 "$(wc -l < "$FAKE_HERDR_LOG" | tr -d ' ')"
    helper ring --timeout-ms 10000 --expected-session "$EXPECTED" -- review-1 "$MESSAGE"
    expect_status 0
    ring_setup
    helper ring --expected-session "$EXPECTED" review-1 --timeout-ms 10000 "$MESSAGE"
    expect_status 0
    ring_setup
    helper ring review-1 "$MESSAGE" --timeout-ms 10000 --timeout-ms 10000 --expected-session "$EXPECTED"
    expect_status 2; ring_no_prompt
}

working_ack_identity_required() {
    local patch
    for patch in '.stdout.result.agent.agent_status="idle"' '.stdout.result.agent.agent_session.value="/replacement.jsonl"' '.stdout.result.agent.terminal_id="replacement"'; do
        ring_setup; ring_patch "map(if .argv[0:2] == [\"agent\",\"prompt\"] then $patch else . end)"
        ring_call; expect_status 5
        assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain" and .result.submitted == null'
        assert_equal 1 "$(ring_prompt_count)"
    done
}
