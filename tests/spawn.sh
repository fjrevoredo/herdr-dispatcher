#!/bin/bash
# Task 2.3 offline contracts. Start is launch-only; never answer a dialog.

spawn_setup() {
    state_setup
    # Production reads the real clock. Keep reuse fixtures fresh without a clock override.
    TEST_NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    export TEST_NOW
    state_fixture > "$TEST_ROOT/records.json"
}
spawn_rules() {
    local mode=${1:-success} target=${2:-worker} cwd name
    cwd="$TEST_ROOT/work"; name=review-1
    if [ "$target" = dispatcher ]; then cwd="$TEST_ROOT/repo"; name=dispatcher; fi
    jq -n --slurpfile r "$TEST_ROOT/records.json" --arg mode "$mode" --arg cwd "$cwd" --arg name "$name" --arg config "$HERDR_DISPATCHER_CONFIG" '
        $r[0].worker_identity as $i |
        {pane_id:$i.pane_id,terminal_id:$i.terminal_id,workspace_id:"wDispatch",tab_id:"tWorker",agent:"pi",agent_session:$i.agent_session,agent_status:"idle",cwd:$cwd,foreground_cwd:$cwd,name:$name,state_change_seq:1} as $agent |
        {argv:["agent","start",$name,"--kind","pi","--pane",$i.pane_id,"--timeout",{timeout_ms:true}],status:0,stdout:{id:"start",result:{type:"agent_started"}},stderr:null,after_agent_list:[$agent]} as $start |
        {argv:["agent","start",$name,"--kind","pi","--pane",$i.pane_id,"--timeout",{timeout_ms:true}],status:1,stdout:null,stderr:{id:"busy",error:{code:"agent_pane_busy",message:"Synthetic pane is busy"}}} as $busy |
        [{persistent:true,argv:["agent","list"],status:0,stdout:{id:"list",result:{type:"agent_list",agents:[]}},stderr:null},
         {persistent:true,argv:["workspace","list"],status:0,stdout:{id:"workspaces",result:{type:"workspace_list",workspaces:[]}},stderr:null},
         {persistent:true,argv:["tab","list","--workspace","wDispatch"],status:0,stdout:{id:"tabs",result:{type:"tab_list",tabs:[{workspace_id:"wDispatch",tab_id:"tWorker"}]}},stderr:null},
         {persistent:true,argv:["pane","process-info","--pane",$i.pane_id],status:0,stdout:{id:"process",result:{type:"pane_process_info",process_info:{pane_id:$i.pane_id,shell_pid:4000,foreground_process_group_id:$i.foreground_process_group_id,foreground_processes:[{pid:5201,name:"pi",argv0:"pi",cwd:$cwd}]}}},stderr:null},
         {argv:["workspace","create","--cwd",$cwd,"--label","dispatch","--env",("HERDR_DISPATCHER_CONFIG="+$config),"--no-focus"],status:0,stdout:{id:"create",result:{workspace:{workspace_id:"wDispatch"},tab:{workspace_id:"wDispatch",tab_id:"tWorker"},root_pane:{workspace_id:"wDispatch",tab_id:"tWorker",pane_id:$i.pane_id}}},stderr:null,after_workspace_list:[{workspace_id:"wDispatch",label:"dispatch"}]}] +
         (if $mode == "busy" then [$busy,$start]
          elif $mode == "busy_forever" then [range(0;30) | $busy + {delay_seconds:0.1}]
          elif $mode == "trust" then [$start | .status=1 | .stdout=null | .stderr={id:"trust",error:{code:"agent_not_ready",message:"Trust this folder?"}} | del(.after_agent_list)] +
             [{argv:["notification","show","Dispatcher startup blocked","--body","Inspect the saved launch and agent dialog. No answer was sent.","--sound","none"],status:0,stdout:{id:"notification",result:{type:"notification_shown"}},stderr:null}]
          elif $mode == "lost_create" then [] else [$start] end) |
         if $mode == "lost_create" then map(if .argv[0:2] == ["workspace","create"] then .status=1 | .stdout=null | .stderr=null else . end) else . end
        ' > "$FAKE_HERDR_SCENARIO"
}
spawn_worker() { helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms "${1:-15000}"; }
spawn_launch_only() {
    jq -se 'all(.[]; (.argv[0:2] | IN(["agent","prompt"],["agent","read"],["pane","type"],["pane","send-key"],["pane","close"],["tab","close"])) | not)' "$FAKE_HERDR_LOG" >/dev/null || fail 'startup submitted input or closed a pane'
}
spawn_startup_success() {
    spawn_setup; spawn_rules; spawn_worker
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.name == "review-1" and .result.reused == false and .result.identity != null and .result.workspace_id == "wDispatch"'
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "ready" and .identity != null and .active_run_id == null and .idle_since != null'
    jq -se 'length == 1 and .[0].phase == "ready" and .[0].identity != null' "$RUN_ROOT/.launches/"*.json >/dev/null
    spawn_launch_only
}
spawn_dispatcher_success() {
    spawn_setup; spawn_rules success dispatcher
    helper spawn dispatcher --timeout-ms 15000
    expect_status 0
    assert_json "$RUN_ROOT/.dispatcher.json" '.name == "dispatcher" and .lifecycle == "ready" and .ownership.mode == "created" and .identity != null'
    spawn_launch_only
}
spawn_busy_retry() {
    spawn_setup; spawn_rules busy
    local started=$SECONDS elapsed
    spawn_worker
    elapsed=$((SECONDS - started))
    expect_status 0
    [ "$elapsed" -le 18 ] || fail "startup exceeded total deadline: ${elapsed}s"
    # The production clock has one-second precision. Two retries can share a tick.
    jq -se '[.[] | select(.argv[0:2] == ["agent","start"])] | length == 2 and (.[1].argv[-1] | tonumber) <= (.[0].argv[-1] | tonumber)' "$FAKE_HERDR_LOG" >/dev/null
    jq -se '[.[] | select(.argv[0:2] == ["workspace","create"])] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
spawn_busy_deadline() {
    spawn_setup; spawn_rules busy_forever
    local started=$SECONDS elapsed
    spawn_worker 8000
    elapsed=$((SECONDS - started))
    expect_status 5
    [ "$elapsed" -le 11 ] || fail "startup exceeded total deadline: ${elapsed}s"
    assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain" and .result.reservation_retained == true'
    assert_json "$TEST_ROOT/helper.json" '.error.code == "budget_expired" or .error.code == "start_uncertain"'
    jq -se '[.[] | select(.argv[0:2] == ["agent","start"])] | length >= 2 and length < 30' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
spawn_trust_dialog() {
    spawn_setup; spawn_rules trust; spawn_worker
    expect_status 3
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "blocked"'
    jq -se 'length == 1 and .[0].phase == "blocked" and .[0].human_notified' "$RUN_ROOT/.launches/"*.json >/dev/null
    jq -se '[.[] | select(.argv[0] == "notification")] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
    helper spawn worker --role review --cwd "$TEST_ROOT/work" --timeout-ms 15000
    expect_status 3
    jq -se '[.[] | select(.argv[0:2] == ["agent","start"])] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
spawn_lost_create() {
    spawn_setup; spawn_rules lost_create; spawn_worker
    expect_status 5
    assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain" and .result.reservation_retained == true'
    jq -se 'length == 1 and .[0].phase == "uncertain" and .[0].mutation == "workspace_create"' "$RUN_ROOT/.launches/"*.json >/dev/null
    spawn_worker
    expect_status 3
    jq -se '[.[] | select(.argv[0:2] == ["workspace","create"])] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
spawn_config_propagated() {
    spawn_setup
    mv "$HERDR_DISPATCHER_CONFIG" "$TEST_ROOT/alternate config.json"
    export HERDR_DISPATCHER_CONFIG="$TEST_ROOT/alternate config.json"
    state_fixture > "$TEST_ROOT/records.json"
    spawn_rules; spawn_worker
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.config_path == env.HERDR_DISPATCHER_CONFIG'
    assert_json "$RUN_ROOT/.workspace.json" '.config_path == env.HERDR_DISPATCHER_CONFIG'
    assert_json "$RUN_ROOT/.workers/review-1" '.config_path == env.HERDR_DISPATCHER_CONFIG'
    jq -se 'any(.[]; .argv[0:2] == ["workspace","create"] and (.argv | index("HERDR_DISPATCHER_CONFIG="+env.HERDR_DISPATCHER_CONFIG)) != null)' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
spawn_unregistered_dispatcher() {
    spawn_setup; live_rules requester
    jq 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].name="dispatcher" else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
    helper spawn dispatcher --timeout-ms 15000
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "registration_required"'
    [ ! -e "$RUN_ROOT/.dispatcher.json" ] || fail 'adopted unregistered dispatcher'
    assert_no_mutations
}
spawn_reuse_setup() {
    spawn_setup; spawn_rules
    owned_worker
    # The fixture workspace launch describes a dispatcher that is not live here.
    # Keep that historical journal closed so recovery does not replace the worker.
    jq '.phase="closed"' "$RUN_ROOT/.launches/11111111111111111111111111111111.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/11111111111111111111111111111111.json"
    jq --slurpfile r "$TEST_ROOT/records.json" 'map(select(.persistent == true) | if .argv == ["agent","list"] then .stdout.result.agents=[{pane_id:$r[0].worker_identity.pane_id,terminal_id:$r[0].worker_identity.terminal_id,workspace_id:"wDispatch",tab_id:"tWorker",agent:"pi",agent_session:$r[0].worker_identity.agent_session,agent_status:"idle",cwd:$r[0].worker.cwd,foreground_cwd:$r[0].worker.cwd,name:"review-1",state_change_seq:1}] elif .argv == ["workspace","list"] then .stdout.result.workspaces=[{workspace_id:"wDispatch",label:"dispatch"}] else . end)' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
}
spawn_same_cwd_reuse() {
    spawn_reuse_setup
    cp "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/original-worker"
    spawn_worker
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.reused == true and .result.name == "review-1"'
    cmp "$TEST_ROOT/original-worker" "$RUN_ROOT/.workers/review-1"
    jq -se 'all(.[]; .argv[0:2] != ["workspace","create"] and .argv[0:2] != ["tab","create"] and .argv[0:2] != ["agent","start"] and .argv[0:2] != ["pane","close"])' "$FAKE_HERDR_LOG" >/dev/null
}
spawn_retirement_rules() {
    local cwd=$1
    jq --arg cwd "$cwd" --arg config "$HERDR_DISPATCHER_CONFIG" --arg session "$TEST_ROOT/next-worker.jsonl" '
        map(if .argv == ["tab","list","--workspace","wDispatch"] then .stdout.result.tabs += [{workspace_id:"wDispatch",tab_id:"tNext"}] else . end) +
        [{argv:["pane","close","wDispatch:p2"],status:0,stdout:{id:"close",result:{type:"pane_closed"}},stderr:null,after_agent_list:[]},
         {argv:["tab","create","--workspace","wDispatch","--cwd",$cwd,"--label","review-2","--env",("HERDR_DISPATCHER_CONFIG="+$config),"--no-focus"],status:0,stdout:{id:"tab",result:{tab:{workspace_id:"wDispatch",tab_id:"tNext"},root_pane:{workspace_id:"wDispatch",tab_id:"tNext",pane_id:"wDispatch:p3"}}},stderr:null},
         {argv:["agent","start","review-2","--kind","pi","--pane","wDispatch:p3","--timeout",{timeout_ms:true}],status:0,stdout:{id:"start",result:{type:"agent_started"}},stderr:null,after_agent_list:[{pane_id:"wDispatch:p3",terminal_id:"term_next",workspace_id:"wDispatch",tab_id:"tNext",agent:"pi",agent_session:{agent:"pi",kind:"path",source:"herdr:pi",value:$session},agent_status:"idle",cwd:$cwd,foreground_cwd:$cwd,name:"review-2",state_change_seq:1}]},
         {persistent:true,argv:["pane","process-info","--pane","wDispatch:p3"],status:0,stdout:{id:"process",result:{type:"pane_process_info",process_info:{pane_id:"wDispatch:p3",shell_pid:6000,foreground_process_group_id:6200,foreground_processes:[{pid:6201,name:"pi",argv0:"pi",cwd:$cwd}]}}},stderr:null}]
        ' "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
}
spawn_retirement_assertions() {
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "closed" and .active_run_id == null'
    assert_json "$RUN_ROOT/.workers/review-2" '.lifecycle == "ready" and .identity.pane_id == "wDispatch:p3"'
    assert_json "$TEST_ROOT/helper.json" '.result.reused == false and .result.name == "review-2"'
    jq -se '[.[] | select(.argv[0:2] == ["pane","close"])] | length == 1 and .[0].argv[2] == "wDispatch:p2"' "$FAKE_HERDR_LOG" >/dev/null
    jq -se 'all(.[]; .argv[0:2] != ["agent","prompt"] and .argv[0:2] != ["pane","type"])' "$FAKE_HERDR_LOG" >/dev/null
}
spawn_different_cwd_retirement() {
    spawn_reuse_setup
    mkdir "$TEST_ROOT/other-work"
    spawn_retirement_rules "$TEST_ROOT/other-work"
    helper spawn worker --role review --cwd "$TEST_ROOT/other-work" --timeout-ms 20000
    spawn_retirement_assertions
    assert_json "$RUN_ROOT/.workers/review-2" '.cwd == (env.TEST_ROOT+"/other-work")'
}
spawn_expired_retirement() {
    spawn_reuse_setup
    jq '.idle_since="2020-01-01T00:00:00Z"' "$RUN_ROOT/.workers/review-1" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/review-1"
    spawn_retirement_rules "$TEST_ROOT/work"
    spawn_worker 20000
    spawn_retirement_assertions
}
spawn_capacity() {
    spawn_reuse_setup; assigned_run
    spawn_worker
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "capacity_full"'
    assert_json "$RUN_ROOT/$RUN_ID/status" '.worker_release.phase == "held" and .state == "dispatched"'
    spawn_launch_only
}

# Exact Task 2.3 acceptance selectors map to the existing contract functions.
busy_shell_retry_bounded() { spawn_busy_retry; }
trust_dialog_not_answered() { spawn_trust_dialog; }
worker_capacity_reserved() { spawn_capacity; }
same_cwd_reuse() { spawn_same_cwd_reuse; }
different_cwd_replaced() { spawn_different_cwd_retirement; }
expired_worker_replaced() { spawn_expired_retirement; }
create_response_lost_not_repeated() { spawn_lost_create; }
config_override_propagated() { spawn_config_propagated; }
unregistered_dispatcher_refused() { spawn_unregistered_dispatcher; }

spawn_patch() {
    jq "$1" "$FAKE_HERDR_SCENARIO" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$FAKE_HERDR_SCENARIO"
}
concurrent_dispatcher_start() {
    spawn_setup; spawn_rules success dispatcher
    local a b first=0 second=0
    "$TEST_REPO/bin/spawn" dispatcher --timeout-ms 20000 > "$TEST_ROOT/a.json" 2> "$TEST_ROOT/a.err" & a=$!
    "$TEST_REPO/bin/spawn" dispatcher --timeout-ms 20000 > "$TEST_ROOT/b.json" 2> "$TEST_ROOT/b.err" & b=$!
    wait "$a" || first=$?
    wait "$b" || second=$?
    assert_equal 0 "$first"; assert_equal 0 "$second"
    assert_envelope "$TEST_ROOT/a.json"; assert_envelope "$TEST_ROOT/b.json"
    jq -se '.[0].result.identity == .[1].result.identity and ([.[].result.reused] | sort == [false,true])' "$TEST_ROOT/a.json" "$TEST_ROOT/b.json" >/dev/null
    jq -se '[.[] | select(.argv[0:2] == ["workspace","create"])] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    jq -se '[.[] | select(.argv[0:2] == ["agent","start"])] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    assert_json "$RUN_ROOT/.dispatcher.json" '.lifecycle == "ready" and .identity != null'
    spawn_launch_only
}
startup_lock_deadline_bounded() {
    spawn_setup; spawn_rules
    mkdir "$RUN_ROOT/.locks/startup"
    jq -n --argjson pid "$$" --arg started "$(LC_ALL=C ps -p "$$" -o lstart= | awk '{$1=$1;print}')" --arg at "$TEST_NOW" '{schema_version:1,pid:$pid,process_started_at:$started,token:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",created_at:$at}' > "$RUN_ROOT/.locks/startup/owner.json"
    cp "$RUN_ROOT/.locks/startup/owner.json" "$TEST_ROOT/owner-before"
    local started=$SECONDS elapsed
    spawn_worker 2000
    elapsed=$((SECONDS - started))
    expect_status 4
    [ "$elapsed" -le 5 ] || fail "startup lock exceeded deadline: ${elapsed}s"
    assert_json "$TEST_ROOT/helper.json" '.error.code == "startup_lock_unavailable"'
    cmp "$TEST_ROOT/owner-before" "$RUN_ROOT/.locks/startup/owner.json"
    [ ! -s "$FAKE_HERDR_LOG" ] || fail 'startup called CLI while lock was held'
    [ ! -e "$RUN_ROOT/.workers/review-1" ] || fail 'startup published worker while lock was held'
}
wrong_named_agent_refused() {
    spawn_setup; live_rules named
    spawn_worker
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "worker_name_conflict"'
    [ ! -e "$RUN_ROOT/.workers/review-1" ] || fail 'adopted unrelated named agent'
    assert_no_mutations
}
unrelated_pane_never_closed() {
    spawn_reuse_setup
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents += [(.stdout.result.agents[0] | .pane_id="wUser:p9" | .terminal_id="term_user" | .workspace_id="wUser" | .tab_id="tUser" | .name="personal" | .agent_session.value += ".unrelated")] else . end) + [(.[] | select(.argv[0:2] == ["pane","process-info"]) | .argv[3]="wUser:p9" | .stdout.result.process_info.pane_id="wUser:p9")]'
    spawn_worker
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.reused == true and .result.identity.pane_id == "wDispatch:p2"'
    spawn_launch_only
    jq -se 'all(.[]; .argv[0:2] != ["pane","close"] and .argv[0:2] != ["tab","close"])' "$FAKE_HERDR_LOG" >/dev/null
}
startup_timeout_preserves_evidence() {
    spawn_setup; spawn_rules
    # Start succeeds, but the agent remains working instead of becoming ready.
    spawn_patch 'map(if .argv[0:2] == ["agent","start"] then .after_agent_list[0].agent_status="working" else . end)'
    local started=$SECONDS elapsed
    spawn_worker 5000
    elapsed=$((SECONDS - started))
    expect_status 5
    [ "$elapsed" -le 8 ] || fail "startup timeout exceeded deadline: ${elapsed}s"
    assert_json "$TEST_ROOT/helper.json" '.outcome == "uncertain" and .result.reservation_retained == true'
    assert_json "$RUN_ROOT/.workers/review-1" '.pane_id == "wDispatch:p2" and (.lifecycle | IN("starting","quarantined"))'
    jq -se 'length == 1 and (.[0].phase | IN("starting","uncertain")) and .[0].mutation == "agent_start" and .[0].pane_id == "wDispatch:p2"' "$RUN_ROOT/.launches/"*.json >/dev/null
    cp "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-before"
    spawn_worker
    expect_status 3
    cmp "$TEST_ROOT/worker-before" "$RUN_ROOT/.workers/review-1"
    jq -se '[.[] | select(.argv[0:2] == ["agent","start"])] | length == 1' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
ready_journal_missing_registration_recovered() {
    spawn_reuse_setup
    mv "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-before"
    spawn_worker
    expect_status 0
    assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "ready" and .identity.pane_id == "wDispatch:p2" and .ownership.launch_id == "22222222222222222222222222222222"'
    assert_json "$TEST_ROOT/helper.json" '.result.reused == true'
    jq -se 'all(.[]; .argv[0:2] != ["agent","start"] and .argv[0:2] != ["workspace","create"] and .argv[0:2] != ["tab","create"])' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
ambiguous_created_recovery_refuses_start() {
    spawn_reuse_setup
    jq '.phase="created" | .mutation="tab_create" | .identity=null' "$RUN_ROOT/.launches/22222222222222222222222222222222.json" > "$TEST_ROOT/next.json"
    mv "$TEST_ROOT/next.json" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].name="personal" else . end)'
    cp "$RUN_ROOT/.launches/22222222222222222222222222222222.json" "$TEST_ROOT/journal-before"
    spawn_worker
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "reconciliation_required"'
    cmp "$TEST_ROOT/journal-before" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    jq -se 'all(.[]; .argv[0:2] != ["agent","start"] and .argv[0:2] != ["workspace","create"] and .argv[0:2] != ["tab","create"])' "$FAKE_HERDR_LOG" >/dev/null
    spawn_launch_only
}
fresh_worker_retirement_refused() {
    spawn_reuse_setup
    spawn_retirement_rules "$TEST_ROOT/work"
    cp "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-before"
    cp "$RUN_ROOT/.launches/22222222222222222222222222222222.json" "$TEST_ROOT/journal-before"
    helper run-state retire-worker review-1 --expect-revision 0 --expected-session "$(jq -c .worker_identity "$TEST_ROOT/records.json")" --timeout-ms 15000
    expect_status 3
    cmp "$TEST_ROOT/worker-before" "$RUN_ROOT/.workers/review-1"
    cmp "$TEST_ROOT/journal-before" "$RUN_ROOT/.launches/22222222222222222222222222222222.json"
    jq -se 'all(.[]; (.argv[0:2] | IN(["agent","list"],["pane","process-info"],["tab","list"])))' "$FAKE_HERDR_LOG" >/dev/null || fail 'unexpected CLI mutation'
}
ambiguous_idle_retirement_refused() {
    local timestamp
    for timestamp in null '"2999-01-01T00:00:00Z"'; do
        spawn_reuse_setup
        markdown "$TEST_ROOT/repo/roles/review.md" '{"schema_version":1,"name":"review","kind":"pi","capabilities":["review"],"max_instances":1,"idle_ttl_seconds":0}' 'Review only.'
        jq --argjson timestamp "$timestamp" '.idle_since=$timestamp' "$RUN_ROOT/.workers/review-1" > "$TEST_ROOT/next.json"
        mv "$TEST_ROOT/next.json" "$RUN_ROOT/.workers/review-1"
        cp "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-before"
        helper run-state retire-worker review-1 --expect-revision 0 --expected-session "$(jq -c .worker_identity "$TEST_ROOT/records.json")" --timeout-ms 15000
        expect_status 3
        assert_json "$TEST_ROOT/helper.json" '.error.code == "retirement_ineligible"'
        cmp "$TEST_ROOT/worker-before" "$RUN_ROOT/.workers/review-1"
        spawn_worker
        expect_status 3
        cmp "$TEST_ROOT/worker-before" "$RUN_ROOT/.workers/review-1"
        spawn_launch_only
    done
}
public_retirement_eligibility() {
    local reason
    for reason in role_ttl role_kind failed_held gone; do
        : > "$FAKE_HERDR_LOG"
        jq '.worker_kinds.review="pi"' "$HERDR_DISPATCHER_CONFIG" > "$TEST_ROOT/next-config.json"
        mv "$TEST_ROOT/next-config.json" "$HERDR_DISPATCHER_CONFIG"
        spawn_reuse_setup
        case "$reason" in
            role_ttl)
                markdown "$TEST_ROOT/repo/roles/review.md" '{"schema_version":1,"name":"review","kind":"pi","capabilities":["review"],"max_instances":1,"idle_ttl_seconds":0}' 'Review only.'
                ;;
            role_kind)
                jq '.worker_kinds.review="claude"' "$HERDR_DISPATCHER_CONFIG" > "$TEST_ROOT/next-config.json"
                mv "$TEST_ROOT/next-config.json" "$HERDR_DISPATCHER_CONFIG"
                ;;
            failed_held)
                assigned_run
                jq --arg at "$TEST_NOW" '.state="failed" | .error={code:"synthetic",message:"Synthetic failure",at:$at} | .notice.type="FAILED" | .notice.phase="pending"' "$RUN_ROOT/$RUN_ID/status" > "$TEST_ROOT/next.json"
                mv "$TEST_ROOT/next.json" "$RUN_ROOT/$RUN_ID/status"
                ;;
            gone)
                spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents=[] else . end) + [{persistent:true,argv:["agent","get","wDispatch:p2"],status:1,stdout:null,stderr:{id:"gone",error:{code:"pane_not_found",message:"Synthetic missing pane"}}}]'
                ;;
        esac
        spawn_retirement_rules "$TEST_ROOT/work"
        helper run-state retire-worker review-1 --expect-revision 0 --expected-session "$(jq -c .worker_identity "$TEST_ROOT/records.json")" --timeout-ms 15000
        expect_status 0
        if [ "$reason" = gone ]; then
            assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "gone"'
            spawn_launch_only
        else
            assert_json "$RUN_ROOT/.workers/review-1" '.lifecycle == "closed"'
        fi
        if [ "$reason" = failed_held ]; then
            assert_json "$RUN_ROOT/$RUN_ID/status" '.state == "failed" and .worker_release.phase == "retired"'
        fi
    done
}
replaced_occupant_retirement_refused() {
    spawn_reuse_setup
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].terminal_id="term_replaced" | .stdout.result.agents[0].agent_session.value += ".replaced" else . end)'
    cp "$RUN_ROOT/.workers/review-1" "$TEST_ROOT/worker-before"
    helper run-state retire-worker review-1 --expect-revision 0 --expected-session "$(jq -c .worker_identity "$TEST_ROOT/records.json")" --timeout-ms 15000
    expect_status 3
    cmp "$TEST_ROOT/worker-before" "$RUN_ROOT/.workers/review-1"
    spawn_launch_only
}
explicit_dispatcher_registration_reused() {
    spawn_setup; live_rules requester
    spawn_patch 'map(if .argv == ["agent","list"] then .stdout.result.agents[0].name="dispatcher" | .stdout.result.agents[0].cwd=(env.TEST_ROOT+"/repo") | .stdout.result.agents[0].foreground_cwd=(env.TEST_ROOT+"/repo") elif .argv == ["pane","current","--current"] then .stdout.result.pane.name="dispatcher" | .stdout.result.pane.cwd=(env.TEST_ROOT+"/repo") | .stdout.result.pane.foreground_cwd=(env.TEST_ROOT+"/repo") elif .argv[0:2] == ["pane","process-info"] then .stdout.result.process_info.foreground_processes[0].cwd=(env.TEST_ROOT+"/repo") else . end)'
    helper run-state register-dispatcher --expect-revision absent --expected-session "$(jq -c .requester "$TEST_ROOT/records.json")" --timeout-ms 15000
    expect_status 0
    assert_json "$RUN_ROOT/.dispatcher.json" '.lifecycle == "ready" and .ownership.mode == "registered" and .ownership.launch_id == null'
    cp "$RUN_ROOT/.dispatcher.json" "$TEST_ROOT/dispatcher-before"
    helper spawn dispatcher --timeout-ms 15000
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.reused == true and .result.identity.pane_id == "wTest:p1"'
    cmp "$TEST_ROOT/dispatcher-before" "$RUN_ROOT/.dispatcher.json"
    [ ! -e "$RUN_ROOT/.workspace.json" ] || fail 'registered pane acquired workspace ownership'
    assert_no_mutations
}
