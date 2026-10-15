#!/bin/bash
# Launch-only startup support. File changes use short state locks; CLI calls do not.
# shellcheck disable=SC1091,SC2034,SC2015,SC2153
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'spawn-lib.sh must be sourced\n' >&2
    exit 2
fi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/state-lib.sh"
SP_TARGET=''; SP_NAME=null; SP_ROLE=''; SP_CWD=''; SP_KIND=''
SP_LAUNCH=null; SP_RECORD=null; SP_WORKSPACE=null; SP_REUSED=false
SP_RECORD_PATH=''; SP_RECORD_TYPE=''; SP_RETAINED=false
SP_OLD_WORKSPACE=null; SP_OLD_DISPATCHER=null

sp_result() {
    ST_RESULT=$(jq -cn --arg target "$SP_TARGET" --argjson name "$SP_NAME" \
        --arg config "${HD_CONFIG_PATH:-}" --argjson l "$SP_LAUNCH" --argjson r "$SP_RECORD" \
        --argjson reused "$SP_REUSED" --argjson retained "$SP_RETAINED" --argjson failed "$1" '
        {target:(if $target == "" then null else $target end),name:$name,
         identity:($r.identity // $l.identity // null),workspace_id:($r.workspace_id // $l.workspace_id // null),
         tab_id:($r.tab_id // $l.tab_id // null),config_path:(if $config == "" then null else $config end),
         reused:$reused,launch_id:($r.ownership.launch_id // $l.launch_id // null)} |
        if $failed then . + {phase:($l.phase // null),reservation_retained:$retained} else . end')
}
# Compare the complete old document, not just a revision supplied by another process.
sp_save() {
    local type=$1 path=$2 old=$3 next=$4 current revision
    printf '%s\n' "$next" > "$HD_PRIVATE/sp-save.json" || return 6
    hd_json_validate "$type" "$HD_PRIVATE/sp-save.json" || return 2
    st_lock || return $?
    if [ "${SP_FREEZE_RESERVATION:-false}" = true ]; then
        st_freeze_scan || return $?
        SP_FREEZE_RESERVATION=false
    fi
    hd_no_links "$path" || return 2
    if [ "$old" = null ]; then
        [ ! -e "$path" ] && [ ! -L "$path" ] || { st_error conflict 'Record already exists' 3; return 3; }
        revision=0
    else
        hd_safe_file "$path" && hd_json_validate "$type" "$path" || return 3
        current=$(jq -c . "$path") || return 6
        [ "$current" = "$old" ] || { st_error conflict 'Saved record changed' 3; return 3; }
        revision=$(printf '%s\n' "$old" | jq '.revision + 1') || return 6
    fi
    jq --argjson rev "$revision" --arg at "$(hd_now)" '.revision=$rev | .updated_at=$at' "$HD_PRIVATE/sp-save.json" > "$HD_PRIVATE/sp-next.json" || return 6
    hd_atomic_replace "$path" "$HD_PRIVATE/sp-next.json" || return $?
    SP_SAVED=$(jq -c . "$HD_PRIVATE/sp-next.json") || return 6
    st_unlock || return $?
}
sp_journal() {
    local next
    next=$(printf '%s\n' "$SP_LAUNCH" | jq -c --arg phase "$1" --argjson mutation "$2" '.phase=$phase | .mutation=$mutation') || return 6
    sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$SP_LAUNCH" | jq -r .launch_id).json" "$SP_LAUNCH" "$next" || return $?
    SP_LAUNCH=$SP_SAVED
}
sp_problem() {
    local phase=$1 code=$2 rc=$3 next lifecycle message outcome
    ST_CODE=$code; ST_MESSAGE='Startup needs human inspection; no mutation will be repeated'
    if [ "$phase" = uncertain ]; then ST_OUTCOME=uncertain; fi
    message=$ST_MESSAGE; outcome=$ST_OUTCOME
    if [ "$SP_LAUNCH" != null ]; then
        next=$(printf '%s\n' "$SP_LAUNCH" | jq -c --arg p "$phase" --arg c "$code" --arg at "$(hd_now)" '.phase=$p | .error={code:$c,message:"Startup requires inspection",at:$at}') || return 5
        if sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$SP_LAUNCH" | jq -r .launch_id).json" "$SP_LAUNCH" "$next"; then SP_LAUNCH=$SP_SAVED; else ST_CODE=$code; ST_MESSAGE=$message; ST_OUTCOME=$outcome; return 5; fi
        if [ "$SP_RECORD" != null ]; then
            lifecycle=quarantined; [ "$phase" != blocked ] || lifecycle=blocked
            next=$(printf '%s\n' "$SP_RECORD" | jq -c --arg life "$lifecycle" --argjson err "$(printf '%s\n' "$SP_LAUNCH" | jq -c .error)" '.lifecycle=$life | .error=$err') || return 5
            if sp_save "$SP_RECORD_TYPE" "$SP_RECORD_PATH" "$SP_RECORD" "$next"; then SP_RECORD=$SP_SAVED; else ST_CODE=$code; ST_MESSAGE=$message; ST_OUTCOME=$outcome; return 5; fi
        fi
        if [ "$phase" = blocked ] && [ "$(printf '%s\n' "$SP_LAUNCH" | jq -r .human_notified)" = false ]; then
            next=$(printf '%s\n' "$SP_LAUNCH" | jq -c '.human_notified=true') || return 5
            if sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$SP_LAUNCH" | jq -r .launch_id).json" "$SP_LAUNCH" "$next"; then
                SP_LAUNCH=$SP_SAVED
                hd_child_call write -- herdr notification show 'Dispatcher startup blocked' --body 'Inspect the saved launch and agent dialog. No answer was sent.' --sound none || :
            else ST_CODE=$code; ST_MESSAGE=$message; ST_OUTCOME=$outcome; return 5; fi
        fi
    fi
    return "$rc"
}
sp_inventory() {
    hd_cli_read workspace list || return $?
    jq -ce '.result | select(.type == "workspace_list" and (.workspaces | type == "array")) | .workspaces | select(all(.[]; (.workspace_id | type == "string" and length > 0)))' "$HD_CHILD_STDOUT" > "$HD_PRIVATE/sp-workspaces.json" || { st_error adapter_schema 'Invalid workspace inventory' 6; return 6; }
    if [ "$SP_WORKSPACE" = null ]; then
        jq -e 'all(.[]; .label != "dispatch")' "$HD_PRIVATE/sp-workspaces.json" >/dev/null || { st_error workspace_conflict 'An unowned dispatch workspace exists' 3; return 3; }
        return 0
    fi
    printf '%s\n' "$SP_WORKSPACE" | jq -e --arg config "$HD_CONFIG_PATH" '.config_path == $config and .lifecycle == "ready"' >/dev/null || { st_error workspace_conflict 'Workspace config or lifecycle differs' 3; return 3; }
    jq -e --argjson w "$SP_WORKSPACE" '[.[] | select(.workspace_id == $w.workspace_id)] | length == 1' "$HD_PRIVATE/sp-workspaces.json" >/dev/null || { st_error reconciliation_required 'Recorded workspace absence requires owned incarnation recovery' 3; return 3; }
    local id journal
    id=$(printf '%s\n' "$SP_WORKSPACE" | jq -r .launch_id)
    journal="$HD_RUN_ROOT/.launches/$id.json"
    hd_safe_file "$journal" && hd_json_validate launch "$journal" || return 3
    jq -e --argjson w "$SP_WORKSPACE" '.ownership_mode == "created" and .ownership_token == $w.ownership_token and .launch_id == $w.launch_id and .workspace_id == $w.workspace_id and .tab_id == $w.initial_tab_id and .pane_id == $w.initial_pane_id' "$journal" >/dev/null || return 3
    hd_cli_read tab list --workspace "$(printf '%s\n' "$SP_WORKSPACE" | jq -r .workspace_id)" || return $?
    jq -ce '.result | select(.type == "tab_list" and (.tabs | type == "array")) | .tabs | select(all(.[]; (.tab_id | type == "string" and length > 0) and (.workspace_id | type == "string" and length > 0)))' "$HD_CHILD_STDOUT" > "$HD_PRIVATE/sp-tabs.json" || { st_error adapter_schema 'Invalid tab inventory' 6; return 6; }
}
sp_topology() {
    local record=$1
    jq -e --argjson r "$record" '[.[] | select(.workspace_id == $r.workspace_id and .tab_id == $r.tab_id)] | length == 1' "$HD_PRIVATE/sp-tabs.json" >/dev/null
}
sp_verify_reuse() {
    local record=$1 identity metadata pane
    pane=$(printf '%s\n' "$record" | jq -r .pane_id)
    identity=$(hd_target_identity "$pane") || return $?
    printf '%s\n' "$record" | jq -e --argjson i "$identity" '.identity == $i' >/dev/null || { st_error identity_mismatch 'Saved occupant no longer matches' 3; return 3; }
    metadata=$(hd_live_metadata "$pane") || return $?
    printf '%s\n' "$metadata" | jq -e --argjson r "$record" '.pane_id == $r.identity.pane_id and .terminal_id == $r.identity.terminal_id and .agent == $r.kind and .agent_session == $r.identity.agent_session and .name == $r.name and .cwd == $r.cwd and .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and (.agent_status | IN("idle","done"))' >/dev/null || { st_error not_ready 'Saved agent is not the same settled occupant' 3; return 3; }
}
sp_reuse() {
    local row record name ttl age held
    if [ "$SP_TARGET" = dispatcher ]; then
        record=$ST_DISPATCHER
        if [ "$record" = null ]; then
            jq -e 'all(.[]; .name != "dispatcher")' "$HD_PRIVATE/agents.json" >/dev/null || { st_error registration_required 'Named dispatcher is not registered' 3; return 3; }
            return 1
        fi
        SP_RECORD=$record; SP_NAME='"dispatcher"'
        printf '%s\n' "$record" | jq -e --arg c "$SP_CWD" --arg k "$SP_KIND" --arg config "$HD_CONFIG_PATH" '.cwd == $c and .kind == $k and .config_path == $config and .lifecycle == "ready" and .identity != null' >/dev/null || { st_error dispatcher_conflict 'Dispatcher registration is not compatible and ready' 3; return 3; }
        if [ "$(printf '%s\n' "$record" | jq -r .ownership.mode)" = created ]; then
            local journal
            journal="$HD_RUN_ROOT/.launches/$(printf '%s\n' "$record" | jq -r .ownership.launch_id).json"
            hd_safe_file "$journal" && hd_json_validate launch "$journal" || return 3
            jq -e --argjson r "$record" '.target == "dispatcher" and .phase == "ready" and .ownership_token == $r.ownership.token and .identity == $r.identity and .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and .pane_id == $r.pane_id and .config_path == $r.config_path' "$journal" >/dev/null || return 3
            sp_topology "$record" || return 3
        fi
        jq -e --argjson r "$record" 'any(.[]; .identity == $r.identity and .name == "dispatcher" and .cwd == $r.cwd and .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and (.agent_status | IN("idle","done")))' "$HD_PRIVATE/live.json" >/dev/null || { st_error dispatcher_conflict 'Registered dispatcher identity or readiness differs' 3; return 3; }
        sp_verify_reuse "$record" || return $?
        SP_REUSED=true; return 0
    fi
    while IFS= read -r row; do
        record=$(printf '%s\n' "$row" | jq -c .record)
        name=$(printf '%s\n' "$record" | jq -r .name)
        held=$(printf '%s\n' "$row" | jq '.occupancy_run_ids | length')
        [ "$held" -eq 0 ] || continue
        printf '%s\n' "$row" | jq -e '.classification == "idle" and (.record.lifecycle | IN("ready","idle")) and .record.active_run_id == null' >/dev/null || continue
        SP_RECORD=$record; SP_NAME=$(jq -cn --arg n "$name" '$n')
        ttl=$SP_TTL
        age=$(printf '%s\n' "$record" | jq --arg at "$(hd_now)" 'if .idle_since == null then -1 else ($at | fromdateiso8601) - (.idle_since | fromdateiso8601) end') || return 3
        if ! printf '%s\n' "$record" | jq -e --arg k "$SP_KIND" --arg cwd "$SP_CWD" --arg config "$HD_CONFIG_PATH" '.kind == $k and .cwd == $cwd and .config_path == $config' >/dev/null || { [ "$age" -ge 0 ] && [ "$age" -ge "$ttl" ]; }; then
            lc_retire "$name" "$(printf '%s\n' "$record" | jq -r .revision)" "$(printf '%s\n' "$record" | jq -c .identity)" "$SP_CWD" "$SP_KIND" || return $?
            # Internal control signal: retirement changed the saved scan.
            return 7
        fi
        [ "$age" -ge 0 ] || { st_error retirement_ambiguous 'Worker idle time is missing or in the future' 3; return 3; }
        st_owned "$record" && sp_topology "$record" || return 3
        sp_verify_reuse "$record" || return $?
        SP_REUSED=true; return 0
    done < <(jq -c --arg role "$SP_ROLE" '.[] | select(.record.role == $role and .classification != "closed")' "$HD_PRIVATE/workers.json")
    SP_RECORD=null; SP_NAME=null
    return 1
}
sp_plan() {
    local rc
    while :; do
        rc=0
        sp_plan_once || rc=$?
        [ "$rc" -eq 7 ] || return "$rc"
        hd_remaining_ms >/dev/null || return 4
    done
}
sp_plan_once() {
    local rc=0 count suffix=1 name next id token at
    sp_recover || return $?
    st_live_scan || return $?
    st_disk_scan || return $?
    SP_WORKSPACE=$ST_WORKSPACE
    if [ "$SP_OLD_WORKSPACE" != null ]; then SP_WORKSPACE=null; fi
    if [ "$SP_OLD_DISPATCHER" != null ]; then ST_DISPATCHER=null; fi
    SP_LAUNCH=$(jq -sc '[.[] | select(. != null and (.phase | IN("ready","closed") | not))] | if length > 0 then .[0] else null end' "$HD_PRIVATE/launches.jsonl") || return 6
    if [ "$SP_LAUNCH" != null ]; then
        SP_RETAINED=true
        SP_NAME=$(printf '%s\n' "$SP_LAUNCH" | jq -c .name)
    fi
    # Count a worker and its journal only once. Unknown launches retain capacity.
    if [ "$SP_TARGET" = worker ]; then
        count=$(jq -s --arg role "$SP_ROLE" --slurpfile workers "$HD_PRIVATE/workers.json" '
            ([$workers[0][] | select(.record.role == $role and (.record.lifecycle | IN("closed","gone") | not)) | .name] +
             [.[] | select(.target == "worker" and .role == $role and (.phase | IN("ready","closed") | not)) | .name]) | unique | length' "$HD_PRIVATE/launches.jsonl") || return 6
        if [ "$count" -ge "$SP_LIMIT" ] && jq -s -e --arg role "$SP_ROLE" 'any(.[]; .role == $role and (.phase | IN("ready","closed") | not))' "$HD_PRIVATE/launches.jsonl" >/dev/null; then
            st_error capacity_full 'Role capacity includes unresolved launch reservations' 3; return 3
        fi
        jq -e --arg role "$SP_ROLE" --slurpfile workers "$HD_PRIVATE/workers.json" '
            all(.[]; . as $a | if (.name // "" | startswith($role + "-")) then
                any($workers[0][]; .record.name == $a.name and .record.pane_id == $a.pane_id)
                else true end)' "$HD_PRIVATE/agents.json" >/dev/null || { st_error worker_name_conflict 'A worker name belongs to an unrelated agent' 3; return 3; }
    fi
    # Unresolved mutations block all later launches, not just this role.
    jq -s -e 'all(.[]; . != null and (.phase | IN("ready","closed")))' "$HD_PRIVATE/launches.jsonl" >/dev/null || { st_error reconciliation_required 'Resolve retained launch journals before another launch' 3; return 3; }
    jq -s -e 'length == 0' "$HD_PRIVATE/issues.jsonl" >/dev/null || { st_error quarantine 'Saved records or live identity need reconciliation' 3; return 3; }
    if [ "$SP_TARGET" = dispatcher ] && [ "$ST_DISPATCHER" = null ]; then
        jq -e 'all(.[]; .name != "dispatcher")' "$HD_PRIVATE/agents.json" >/dev/null || { st_error registration_required 'Named dispatcher is not registered' 3; return 3; }
    fi
    # A registered dispatcher need not be in our workspace.
    if [ "$SP_TARGET" = dispatcher ] && [ "$ST_DISPATCHER" != null ] && [ "$(printf '%s\n' "$ST_DISPATCHER" | jq -r .ownership.mode)" = registered ]; then
        sp_reuse || return $?
        st_lock && st_freeze_scan && st_unlock || return $?
        ST_OUTCOME=ok; return 0
    fi
    sp_inventory || return $?
    sp_reuse || rc=$?
    if [ "$rc" -eq 0 ]; then
        st_lock && st_freeze_scan && st_unlock || return $?
        ST_OUTCOME=ok; return 0
    fi
    [ "$rc" -eq 1 ] || return "$rc"
    if [ "$SP_TARGET" = worker ]; then
        count=$(jq --arg role "$SP_ROLE" '[.[] | select(.record.role == $role and .classification != "closed")] | length' "$HD_PRIVATE/workers.json") || return 6
        [ "$count" -lt "$SP_LIMIT" ] || { st_error capacity_full 'Role capacity is reserved' 3; return 3; }
        while :; do
            hd_remaining_ms >/dev/null || return 4
            name="$SP_ROLE-$suffix"
            [ "${#name}" -le 32 ] || { st_error name_exhausted 'Worker name space is exhausted' 3; return 3; }
            if ! jq -e --arg n "$name" 'any(.[]; .name == $n)' "$HD_PRIVATE/agents.json" >/dev/null &&
                ! jq -s -e --arg n "$name" 'any(.[]; .name == $n)' "$HD_PRIVATE/launches.jsonl" >/dev/null &&
                [ ! -e "$HD_RUN_ROOT/.workers/$name" ] && [ ! -L "$HD_RUN_ROOT/.workers/$name" ]; then break; fi
            # A matching unowned live name is a conflict, not an adoption or silent skip.
            if jq -e --arg n "$name" 'any(.[]; .name == $n)' "$HD_PRIVATE/agents.json" >/dev/null && [ ! -e "$HD_RUN_ROOT/.workers/$name" ]; then st_error worker_name_conflict 'Worker name belongs to an unrelated agent' 3; return 3; fi
            suffix=$((suffix + 1))
        done
    else name=dispatcher; fi
    SP_NAME=$(jq -cn --arg n "$name" '$n')
    id=$(hd_random 16) || return 6; token=$(hd_random 16) || return 6; at=$(hd_now)
    next=$(jq -cn --arg id "$id" --arg token "$token" --arg target "$SP_TARGET" --arg name "$name" --arg role "$SP_ROLE" --arg kind "$SP_KIND" --arg cwd "$SP_CWD" --arg config "$HD_CONFIG_PATH" --arg at "$at" '{schema_version:1,revision:0,launch_id:$id,target:$target,name:$name,role:(if $target == "worker" then $role else null end),kind:$kind,cwd:$cwd,config_path:$config,ownership_token:$token,ownership_mode:"created",phase:"reserved",mutation:null,workspace_id:null,tab_id:null,pane_id:null,identity:null,created_at:$at,updated_at:$at,error:null,human_notified:false}') || return 6
    SP_FREEZE_RESERVATION=true
    SP_RESERVED_PATH="$HD_RUN_ROOT/.launches/$id.json"
    sp_save launch "$SP_RESERVED_PATH" null "$next" || return $?
    SP_LAUNCH=$SP_SAVED; SP_RETAINED=true
    sp_launch
}
sp_launch() {
    local rc=0 next topology workspace tab pane remaining code identity metadata
    if [ "$SP_WORKSPACE" = null ]; then
        sp_journal creating '"workspace_create"' || return $?
        SP_MUTATION_ATTEMPTED=true
        hd_child_call write -- herdr workspace create --cwd "$SP_CWD" --label dispatch --env "HERDR_DISPATCHER_CONFIG=$HD_CONFIG_PATH" --no-focus || rc=$?
    else
        sp_journal creating '"tab_create"' || return $?
        workspace=$(printf '%s\n' "$SP_WORKSPACE" | jq -r .workspace_id)
        SP_MUTATION_ATTEMPTED=true
        hd_child_call write -- herdr tab create --workspace "$workspace" --cwd "$SP_CWD" --label "$(printf '%s\n' "$SP_NAME" | jq -r .)" --env "HERDR_DISPATCHER_CONFIG=$HD_CONFIG_PATH" --no-focus || rc=$?
    fi
    [ "$rc" -eq 0 ] || { sp_problem uncertain create_uncertain 5; return $?; }
    topology=$(jq -sce --argjson w "$SP_WORKSPACE" 'select(length == 1) | .[0] | select((.id | type == "string" and length > 0) and (.result | type == "object")) | .result | {workspace_id:(if $w == null then .workspace.workspace_id else $w.workspace_id end),tab_id:.tab.tab_id,pane_id:.root_pane.pane_id,tab_workspace:.tab.workspace_id,pane_workspace:.root_pane.workspace_id,pane_tab:.root_pane.tab_id} | select(all(.[]; type == "string" and length > 0) and .workspace_id == .tab_workspace and .workspace_id == .pane_workspace and .tab_id == .pane_tab) | {workspace_id,tab_id,pane_id}' "$HD_CHILD_STDOUT") || { sp_problem uncertain adapter_schema 5; return $?; }
    next=$(printf '%s\n' "$SP_LAUNCH" | jq -c --argjson t "$topology" '. + $t | .phase="created"') || return 5
    sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$SP_LAUNCH" | jq -r .launch_id).json" "$SP_LAUNCH" "$next" || return 5
    SP_LAUNCH=$SP_SAVED
    if [ "$SP_WORKSPACE" = null ]; then
        next=$(printf '%s\n' "$SP_LAUNCH" | jq -c '{schema_version:1,revision:0,label:"dispatch",ownership_token,launch_id,workspace_id,initial_tab_id:.tab_id,initial_pane_id:.pane_id,config_path,lifecycle:"ready",created_at,updated_at,error:null}') || return 5
        sp_save workspace "$HD_RUN_ROOT/.workspace.json" "$SP_OLD_WORKSPACE" "$next" || return 5
        SP_OLD_WORKSPACE=null
        SP_WORKSPACE=$SP_SAVED
    fi
    next=$(printf '%s\n' "$SP_LAUNCH" | jq -c '{schema_version:1,revision:0,name,kind,cwd,config_path,ownership:{mode:"created",token:.ownership_token,launch_id},workspace_id,tab_id,pane_id,identity:null,lifecycle:"starting",created_at,updated_at,error:null} + (if .target == "worker" then {role,active_run_id:null,idle_since:null} else {} end)') || return 5
    SP_RECORD_TYPE=$SP_TARGET
    if [ "$SP_TARGET" = worker ]; then SP_RECORD_PATH="$HD_RUN_ROOT/.workers/$(printf '%s\n' "$SP_NAME" | jq -r .)"; else SP_RECORD_PATH="$HD_RUN_ROOT/.dispatcher.json"; fi
    sp_save "$SP_RECORD_TYPE" "$SP_RECORD_PATH" "$([ "$SP_TARGET" = dispatcher ] && printf '%s' "$SP_OLD_DISPATCHER" || printf null)" "$next" || return 5
    SP_OLD_DISPATCHER=null
    SP_RECORD=$SP_SAVED
    sp_start
}
sp_start() {
    local rc=0 next pane remaining code identity metadata
    pane=$(printf '%s\n' "$SP_LAUNCH" | jq -r .pane_id)
    while :; do
        remaining=$(hd_remaining_ms) || { sp_problem uncertain budget_expired 5; return $?; }
        rc=0
        sp_journal starting '"agent_start"' || rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 4 ]; then sp_problem uncertain budget_expired 5; return $?; fi
            return 5
        fi
        rc=0
        hd_child_call write -- herdr agent start "$(printf '%s\n' "$SP_NAME" | jq -r .)" --kind "$SP_KIND" --pane "$pane" --timeout "$remaining" || rc=$?
        if [ "$rc" -eq 0 ]; then
            # Creation is fixture-backed; startup acknowledgement is not. Require a
            # structured response and independent readiness, never a text success.
            jq -se 'length == 1 and (.[0].id | type == "string" and length > 0) and (.[0].result | type == "object" and .type == "agent_started")' "$HD_CHILD_STDOUT" >/dev/null || { sp_problem uncertain adapter_schema 5; return $?; }
            break
        fi
        code=''
        if [ "$HD_CHILD_EXIT" -eq 1 ]; then
            code=$(jq -ser 'select(length == 1) | .[0] | select(type == "object" and (.id | type == "string" and length > 0) and (has("result") | not) and (.error | type == "object" and (.message | type == "string"))) | .error.code | select(type == "string" and test("^[a-z][a-z0-9_]*$"))' "$HD_CHILD_STDERR" 2>/dev/null) || code=''
        fi
        case "$code" in
            agent_pane_busy) hd_sleep || { sp_problem uncertain budget_expired 5; return $?; } ;;
            agent_not_ready|agent_blocked) sp_problem blocked "$code" 3; return $? ;;
            *) sp_problem uncertain "${code:-start_uncertain}" 5; return $? ;;
        esac
    done
    while :; do
        hd_remaining_ms >/dev/null || { sp_problem uncertain identity_unavailable 5; return $?; }
        metadata=$(hd_live_metadata "$pane") || { rc=$?; if [ "$rc" -eq 3 ]; then hd_sleep || { sp_problem uncertain identity_unavailable 5; return $?; }; continue; fi; sp_problem uncertain live_query_failed 5; return $?; }
        if printf '%s\n' "$metadata" | jq -e '.agent_status == "blocked"' >/dev/null; then sp_problem blocked agent_not_ready 3; return $?; fi
        if ! printf '%s\n' "$metadata" | jq -e --argjson r "$SP_RECORD" '.pane_id == $r.pane_id and .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and .cwd == $r.cwd and .agent == $r.kind and .name == $r.name and (.agent_status | IN("idle","done"))' >/dev/null; then hd_sleep || { sp_problem uncertain identity_unavailable 5; return $?; }; continue; fi
        identity=$(hd_target_identity "$pane") || { rc=$?; if [ "$rc" -eq 3 ]; then hd_sleep || { sp_problem uncertain identity_unavailable 5; return $?; }; continue; fi; sp_problem uncertain identity_unavailable 5; return $?; }
        metadata=$(hd_live_metadata "$pane") || { sp_problem uncertain identity_unavailable 5; return $?; }
        printf '%s\n' "$metadata" | jq -e --argjson i "$identity" --argjson r "$SP_RECORD" '.pane_id == $i.pane_id and .terminal_id == $i.terminal_id and .agent_session == $i.agent_session and .agent == $i.kind and .agent == $r.kind and .name == $r.name and .cwd == $r.cwd and .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and (.agent_status | IN("idle","done"))' >/dev/null || { sp_problem uncertain identity_mismatch 5; return $?; }
        break
    done
    sp_ready "$identity"
}
sp_ready() {
    local identity=$1 next
    # Journal first: a crash before the derived registration is recoverable evidence.
    next=$(printf '%s\n' "$SP_LAUNCH" | jq -c --argjson i "$identity" '.identity=$i | .phase="ready" | .error=null') || return 5
    sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$SP_LAUNCH" | jq -r .launch_id).json" "$SP_LAUNCH" "$next" || return 5
    SP_LAUNCH=$SP_SAVED
    next=$(printf '%s\n' "$SP_RECORD" | jq -c --argjson i "$identity" --arg at "$(hd_now)" '.identity=$i | .lifecycle="ready" | .error=null | if has("idle_since") and .idle_since == null then .idle_since=$at else . end') || return 5
    sp_save "$SP_RECORD_TYPE" "$SP_RECORD_PATH" "$SP_RECORD" "$next" || return 5
    SP_RECORD=$SP_SAVED; SP_RETAINED=false; ST_OUTCOME=ok
}
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lifecycle-lib.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/spawn-recovery.sh"
