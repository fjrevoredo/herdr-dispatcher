#!/bin/bash
# Internal closure and explicit registration. Loaded by spawn-lib.sh.
# shellcheck disable=SC1091,SC2034,SC2015,SC2153
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'lifecycle-lib.sh must be sourced\n' >&2
    exit 2
fi
lc_pane_lock() {
    local key
    key=$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n') || return 6
    LC_PANE_LOCK="$HD_RUN_ROOT/.locks/pane-$key"
    hd_lock_acquire "$LC_PANE_LOCK" || return $?
    LC_PANE_TOKEN=$HD_LOCK_TOKEN
}
lc_pane_unlock() { hd_lock_release "$LC_PANE_LOCK" "$LC_PANE_TOKEN"; }
lc_tabs() {
    hd_cli_read tab list --workspace "$1" || return $?
    jq -ce '.result | select(.type == "tab_list" and (.tabs | type == "array")) | .tabs' "$HD_CHILD_STDOUT" > "$HD_PRIVATE/sp-tabs.json" || return 6
}
lc_record_live() {
    local record=$1 identity metadata
    identity=$(hd_target_identity "$(printf '%s\n' "$record" | jq -r .pane_id)") || return $?
    printf '%s\n' "$record" | jq -e --argjson i "$identity" '.identity == $i' >/dev/null || return 3
    metadata=$(hd_live_metadata "$(printf '%s\n' "$record" | jq -r .pane_id)") || return $?
    printf '%s\n' "$metadata" | jq -e --argjson r "$record" '
        .name == $r.name and .cwd == $r.cwd and .workspace_id == $r.workspace_id and
        .tab_id == $r.tab_id and .pane_id == $r.pane_id and .terminal_id == $r.identity.terminal_id and
        .agent == $r.kind and .agent_session == $r.identity.agent_session and (.agent_status | IN("idle","done"))' >/dev/null || return 3
    lc_tabs "$(printf '%s\n' "$record" | jq -r .workspace_id)" && sp_topology "$record"
}
# Release authority first. A later worker-sync/retirement repairs the derived cache.
lc_finish_worker() {
    local worker=$1 lifecycle=$2 next row status path name journal at
    name=$(printf '%s\n' "$worker" | jq -r .name)
    path="$HD_RUN_ROOT/.workers/$name"
    journal="$HD_RUN_ROOT/.launches/$(printf '%s\n' "$worker" | jq -r .ownership.launch_id).json"
    at=$(hd_now)
    st_lock && st_freeze_scan || return $?
    while IFS= read -r row; do
        status=$(printf '%s\n' "$row" | jq -c .status)
        printf '%s\n' "$status" | jq --arg at "$at" '.revision += 1 | .updated_at=$at | .worker_release={phase:"retired",observed_at:$at,reason:"worker_gone"}' > "$HD_PRIVATE/lc-release.json" || return 6
        hd_atomic_replace "$(printf '%s\n' "$row" | jq -r .run_path)/status" "$HD_PRIVATE/lc-release.json" || return 6
    done < <(jq -c --argjson w "$worker" '.[] | select(.status.worker_release.phase == "held" and .status.assignment.worker == $w.identity and .status.assignment.worker_name == $w.name)' "$HD_PRIVATE/runs.json")
    st_unlock || return $?
    next=$(jq -c '.phase="closed" | .error=null' "$journal") || return 6
    sp_save launch "$journal" "$(jq -c . "$journal")" "$next" || return $?
    next=$(printf '%s\n' "$worker" | jq -c --arg life "$lifecycle" '.lifecycle=$life | .active_run_id=null | .idle_since=null | .error=null') || return 6
    sp_save worker "$path" "$worker" "$next" || return $?
    LC_WORKER=$SP_SAVED
    ST_RESULT=$(jq -cn --argjson w "$LC_WORKER" '{worker:$w,committed:true}')
}
lc_retire() {
    local name=$1 revision=$2 expected=$3 desired_cwd=${4:-} desired_kind=${5:-} worker journal next held role rc=0
    ST_KEY=$name; st_path worker "$name" && st_load || return $?
    worker=$ST_DOCUMENT
    [ "$(printf '%s\n' "$worker" | jq -r .revision)" = "$revision" ] || { st_conflict; return 3; }
    printf '%s\n' "$worker" | jq -e --argjson i "$expected" '.identity == $i and .identity != null and (.lifecycle | IN("closed","gone") | not)' >/dev/null || return 3
    lc_pane_lock "$(printf '%s\n' "$worker" | jq -r .pane_id)" || return $?
    st_live_scan && st_disk_scan && st_owned "$worker" || return $?
    jq -e 'all(.[]; .status != null and .request != null and .classification != "quarantined")' "$HD_PRIVATE/runs.json" >/dev/null && [ ! -s "$HD_PRIVATE/issues.jsonl" ] || return 3
    jq -e --argjson w "$worker" 'all(.[]; if .status.assignment != null and (.status.assignment.worker_name == $w.name or .status.assignment.worker.pane_id == $w.pane_id or .status.assignment.worker.terminal_id == $w.identity.terminal_id) then .status.assignment.worker == $w.identity and .status.assignment.worker_name == $w.name else true end)' "$HD_PRIVATE/runs.json" >/dev/null || return 3
    held=$(jq --argjson w "$worker" '[.[] | select(.status.worker_release.phase == "held" and .status.assignment.worker == $w.identity)]' "$HD_PRIVATE/runs.json") || return 6
    printf '%s\n' "$held" | jq -e 'length <= 1 and all(.[]; .status.state == "failed")' >/dev/null || { st_error occupied 'Resolve held work before retirement' 3; return 3; }
    if st_gone_proof "$expected"; then
        ST_OUTCOME=uncertain
        lc_finish_worker "$worker" gone || return 5
    else
        # Lost close acknowledgements are never permission to repeat closure.
        printf '%s\n' "$worker" | jq -e '.lifecycle != "closing"' >/dev/null || { st_error closure_uncertain 'Inspect the pending close before retry' 5; ST_OUTCOME=uncertain; return 5; }
        lc_record_live "$worker" || { st_error quarantine 'Worker is not the same settled owned occupant' 3; return 3; }
        # Role rows come from st_disk_scan, which validates metadata and its name.
        role=$(jq -sce --argjson w "$worker" '[.[] | select(.name == $w.role and .metadata != null)] | select(length == 1) | .[0]' "$HD_PRIVATE/roles.jsonl") || { st_error invalid_role 'Role is missing or invalid' 3; return 3; }
        # Only spawn supplies a desired directory/kind, after request validation.
        if [ -n "$desired_cwd$desired_kind" ]; then
            [ "$(hd_directory "$desired_cwd")" = "$desired_cwd" ] &&
                printf '%s\n' "$role" | jq -e --arg k "$desired_kind" '.effective_kind == $k' >/dev/null || return 3
        fi
        printf '%s\n' "$worker" | jq -e --argjson role "$role" --argjson held "$held" \
            --arg config "$HD_CONFIG_PATH" --arg cwd "$desired_cwd" --arg at "$(hd_now)" '
            .kind != $role.effective_kind or .config_path != $config or
            ($cwd != "" and .cwd != $cwd) or ($held | length == 1) or
            (if .idle_since == null then false else
                (($at | fromdateiso8601) - (.idle_since | fromdateiso8601)) as $age |
                $age >= 0 and $age >= $role.effective_idle_ttl_seconds
             end)' >/dev/null || { st_error retirement_ineligible 'Worker has no proven retirement reason' 3; return 3; }
        journal="$HD_RUN_ROOT/.launches/$(printf '%s\n' "$worker" | jq -r .ownership.launch_id).json"
        SP_FREEZE_RESERVATION=true
        next=$(jq -c '.phase="closing" | .mutation="pane_close"' "$journal") || return 6
        sp_save launch "$journal" "$(jq -c . "$journal")" "$next" || return $?
        next=$(printf '%s\n' "$worker" | jq -c '.lifecycle="closing"') || return 6
        sp_save worker "$ST_PATH" "$worker" "$next" || return 5
        worker=$SP_SAVED
        ST_RESULT=$(jq -cn --argjson w "$worker" '{worker:$w,committed:true}')
        ST_OUTCOME=uncertain
        # Recheck after publication. A replacement or newly busy pane is never closed.
        lc_record_live "$worker" || return 5
        hd_child_call write -- herdr pane close "$(printf '%s\n' "$worker" | jq -r .pane_id)" || rc=$?
        [ "$rc" -eq 0 ] && jq -se 'length == 1 and (.[0].id | type == "string" and length > 0) and .[0].result.type == "pane_closed"' "$HD_CHILD_STDOUT" >/dev/null || { st_error closure_uncertain 'Close acknowledgement is uncertain; inspect the saved pane' 5; return 5; }
        st_live_scan && st_disk_scan || return 5
        lc_finish_worker "$worker" closed || return 5
    fi
    lc_pane_unlock || return 5
    ST_CODE=invalid_arguments; ST_OUTCOME=ok
}
lc_registration_journal() {
    local record=$1 at id next
    at=$(hd_now); id=$(hd_random 16) || return 6
    next=$(printf '%s\n' "$record" | jq -c --arg id "$id" --arg at "$at" '{schema_version:1,revision:0,launch_id:$id,target:"dispatcher",name:"dispatcher",role:null,kind,cwd,config_path,ownership_token:.ownership.token,ownership_mode:.ownership.mode,phase:"ready",mutation:null,workspace_id,tab_id,pane_id,identity,created_at:$at,updated_at:$at,error:null,human_notified:false}') || return 6
    sp_save launch "$HD_RUN_ROOT/.launches/$id.json" null "$next" || return $?
    LC_JOURNAL=$SP_SAVED
}
lc_register() {
    local expected=$1 current metadata old=null next token at journal rc=0 path pending
    hd_lock_acquire "$HD_RUN_ROOT/.locks/startup" || return $?
    current=$(hd_current_identity) || return $?
    printf '%s\n' "$current" | jq -e --argjson i "$expected" '. == $i' >/dev/null || { st_error identity_mismatch 'Current occupant differs from the expected session' 3; return 3; }
    lc_pane_lock "$(printf '%s\n' "$current" | jq -r .pane_id)" || return $?
    st_live_scan && st_disk_scan || return $?
    metadata=$(hd_live_metadata "$(printf '%s\n' "$current" | jq -r .pane_id)") || return $?
    printf '%s\n' "$metadata" | jq -e --argjson c "$HD_CONFIG_JSON" '.cwd == $c.repo_path and .agent == $c.dispatcher_kind and (.agent_status | IN("idle","done","working"))' >/dev/null || return 3
    jq -e --argjson i "$current" 'all(.[]; .name != "dispatcher" or (.pane_id == $i.pane_id and .terminal_id == $i.terminal_id))' "$HD_PRIVATE/agents.json" >/dev/null || { st_error registration_conflict 'Dispatcher name belongs to another occupant' 3; return 3; }
    jq -e --argjson i "$current" 'all(.[]; .record != null and .record.pane_id != $i.pane_id and .record.identity.terminal_id != $i.terminal_id)' "$HD_PRIVATE/workers.json" >/dev/null || { st_error managed_worker 'A worker cannot register as dispatcher' 3; return 3; }
    jq -s -e --argjson i "$current" 'all(.[]; . != null and (.target != "worker" or (.pane_id != $i.pane_id and .identity.terminal_id != $i.terminal_id)))' "$HD_PRIVATE/launches.jsonl" >/dev/null || { st_error managed_worker 'A saved worker launch cannot register as dispatcher' 3; return 3; }
    path="$HD_RUN_ROOT/.dispatcher.json"
    if [ -e "$path" ] || [ -L "$path" ]; then
        hd_safe_file "$path" && hd_json_validate dispatcher "$path" || return 3
        old=$(jq -c . "$path") || return 6
        [ "$(printf '%s\n' "$old" | jq -r .revision)" = "$ST_EXPECT" ] || { ST_DOCUMENT=$old; st_conflict; return 3; }
        if printf '%s\n' "$old" | jq -e --argjson i "$current" '.identity == $i and .ownership.mode == "registered"' >/dev/null; then
            printf '%s\n' "$old" | jq -e --arg c "$HD_CONFIG_PATH" --argjson m "$metadata" '.config_path == $c and .cwd == $m.cwd and .kind == $m.agent and .workspace_id == $m.workspace_id and .tab_id == $m.tab_id' >/dev/null || return 3
            token=$(printf '%s\n' "$old" | jq -r .ownership.token)
        else
            [ "$(printf '%s\n' "$old" | jq -c .identity)" != null ] || return 3
            st_gone_proof "$(printf '%s\n' "$old" | jq -c .identity)" || return $?
            jq -s -e 'all(.[]; . != null and (.phase | IN("ready","closed")))' "$HD_PRIVATE/launches.jsonl" >/dev/null || return 3
            if [ "$(printf '%s\n' "$old" | jq -r .ownership.mode)" = registered ]; then lc_registration_journal "$old" || return $?; fi
            token=$(hd_random 16) || return 6
        fi
    else
        [ "$ST_EXPECT" = absent ] || return 3
        # Recover only the exact pending registration, including saved topology.
        pending=$(jq -sc --argjson i "$current" --argjson m "$metadata" --arg config "$HD_CONFIG_PATH" '
            [.[] | select(. != null and .target == "dispatcher" and .name == "dispatcher" and
                .ownership_mode == "registered" and .mutation == "agent_rename" and
                (.phase | IN("ready","closed") | not) and .identity == $i and
                .config_path == $config and .kind == $m.agent and .cwd == $m.cwd and
                .workspace_id == $m.workspace_id and .tab_id == $m.tab_id and .pane_id == $m.pane_id)] |
            if length == 1 then .[0] elif length == 0 then null else error("conflicting registrations") end' "$HD_PRIVATE/launches.jsonl") || return 3
        if [ "$pending" != null ]; then token=$(printf '%s\n' "$pending" | jq -r .ownership_token)
        else token=$(hd_random 16) || return 6; fi
    fi
    # Only our own pending rename may be reconciled. Never bypass a retained create/start.
    jq -s -e --arg token "$token" --argjson i "$current" 'all(.[]; . != null and ((.phase | IN("ready","closed")) or (.ownership_mode == "registered" and .ownership_token == $token and .identity == $i and .mutation == "agent_rename")))' "$HD_PRIVATE/launches.jsonl" >/dev/null || return 3
    pending=$(jq -sc --arg token "$token" '[.[] | select(.ownership_token == $token and .ownership_mode == "registered" and (.phase | IN("ready","closed") | not))] | if length == 1 then .[0] elif length == 0 then null else error("conflicting registrations") end' "$HD_PRIVATE/launches.jsonl") || return 3
    if [ "$pending" != null ]; then
        printf '%s\n' "$pending" | jq -e --argjson i "$current" --argjson m "$metadata" --arg config "$HD_CONFIG_PATH" '
            .target == "dispatcher" and .name == "dispatcher" and .identity == $i and
            .config_path == $config and .kind == $m.agent and .cwd == $m.cwd and
            .workspace_id == $m.workspace_id and .tab_id == $m.tab_id and .pane_id == $m.pane_id' >/dev/null || return 3
        journal=$pending
        LC_DISPATCHER=$old
        if [ "$old" = null ]; then
            next=$(printf '%s\n' "$journal" | jq -c '{schema_version:1,revision:0,name,kind,cwd,config_path,workspace_id,tab_id,pane_id,identity,ownership:{mode:"registered",token:.ownership_token,launch_id:null},lifecycle:"starting",created_at,updated_at,error:null}') || return 6
            sp_save dispatcher "$path" null "$next" || return $?
            LC_DISPATCHER=$SP_SAVED
        fi
        ST_RESULT=$(jq -cn --argjson d "$LC_DISPATCHER" '{dispatcher:$d,committed:true}')
        # An ambiguous rename is never repeated, even if its original name remains.
        [ "$(printf '%s\n' "$metadata" | jq -r '.name // empty')" = dispatcher ] || { ST_OUTCOME=uncertain; st_error rename_uncertain 'Pending rename needs human inspection' 5; return 5; }
    elif [ "$old" != null ] && printf '%s\n' "$old" | jq -e --argjson i "$current" '.identity == $i and .ownership.mode == "registered" and .lifecycle == "ready"' >/dev/null; then
        [ "$(printf '%s\n' "$metadata" | jq -r '.name // empty')" = dispatcher ] || return 3
        ST_RESULT=$(jq -cn --argjson d "$old" '{dispatcher:$d,committed:false}')
        ST_OUTCOME=ok; lc_pane_unlock; return $?
    fi
    hd_identity_check "$(printf '%s\n' "$current" | jq -r .pane_id)" "$current" || return $?
    at=$(hd_now)
    next=$(printf '%s\n' "$metadata" | jq -c --argjson i "$current" --arg token "$token" --arg config "$HD_CONFIG_PATH" --arg at "$at" '{schema_version:1,revision:0,name:"dispatcher",kind:.agent,cwd,config_path:$config,workspace_id,tab_id,pane_id,identity:$i,ownership:{mode:"registered",token:$token,launch_id:null},lifecycle:"starting",created_at:$at,updated_at:$at,error:null}') || return 6
    if [ "$old" != null ] && [ "$(printf '%s\n' "$old" | jq -r .ownership.token)" = "$token" ]; then next=$(printf '%s\n' "$next" | jq -c --argjson o "$old" '.created_at=$o.created_at'); fi
    if [ "$pending" = null ]; then
    lc_registration_journal "$next" || return $?
    journal=$LC_JOURNAL
    next=$(printf '%s\n' "$journal" | jq -c '.phase="starting" | .mutation="agent_rename"') || return 6
    sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$journal" | jq -r .launch_id).json" "$journal" "$next" || return $?
    journal=$SP_SAVED
    next=$(printf '%s\n' "$journal" | jq -c '{schema_version:1,revision:0,name,kind,cwd,config_path,workspace_id,tab_id,pane_id,identity,ownership:{mode:"registered",token:.ownership_token,launch_id:null},lifecycle:"starting",created_at,updated_at,error:null}') || return 6
    sp_save dispatcher "$path" "$old" "$next" || return $?
    LC_DISPATCHER=$SP_SAVED
    fi
    ST_OUTCOME=uncertain
    ST_RESULT=$(jq -cn --argjson d "$LC_DISPATCHER" '{dispatcher:$d,committed:true}')
    if [ "$(printf '%s\n' "$metadata" | jq -r '.name // empty')" != dispatcher ]; then
        hd_identity_check "$(printf '%s\n' "$current" | jq -r .pane_id)" "$current" || return 5
        hd_child_call write -- herdr agent rename "$(printf '%s\n' "$current" | jq -r .pane_id)" dispatcher || rc=$?
        [ "$rc" -eq 0 ] || { st_error rename_uncertain 'Inspect the saved registration before retry' 5; return 5; }
    fi
    hd_identity_check "$(printf '%s\n' "$current" | jq -r .pane_id)" "$current" || return 5
    metadata=$(hd_live_metadata "$(printf '%s\n' "$current" | jq -r .pane_id)") || return 5
    printf '%s\n' "$metadata" | jq -e --argjson d "$LC_DISPATCHER" '.name == "dispatcher" and .cwd == $d.cwd and .workspace_id == $d.workspace_id and .tab_id == $d.tab_id and .agent == $d.kind' >/dev/null || return 5
    next=$(printf '%s\n' "$journal" | jq -c '.phase="ready" | .error=null') || return 5
    sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$journal" | jq -r .launch_id).json" "$journal" "$next" || return 5
    next=$(printf '%s\n' "$LC_DISPATCHER" | jq -c '.lifecycle="ready" | .error=null') || return 5
    sp_save dispatcher "$path" "$LC_DISPATCHER" "$next" || return 5
    LC_DISPATCHER=$SP_SAVED
    ST_RESULT=$(jq -cn --argjson d "$LC_DISPATCHER" '{dispatcher:$d,committed:true}')
    lc_pane_unlock || return 5
    ST_OUTCOME=ok
}
