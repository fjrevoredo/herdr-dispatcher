#!/bin/bash
# Internal startup recovery. Saved topology is evidence; labels are not.
# shellcheck disable=SC1091,SC2034,SC2015,SC2153
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'spawn-recovery.sh must be sourced\n' >&2
    exit 2
fi
sp_empty_tab() {
    local journal=$1 pane workspace tab first second rc=0
    pane=$(printf '%s\n' "$journal" | jq -r .pane_id)
    workspace=$(printf '%s\n' "$journal" | jq -r .workspace_id)
    tab=$(printf '%s\n' "$journal" | jq -r .tab_id)
    hd_cli_read pane list --workspace "$workspace" || return $?
    jq -e --argjson l "$journal" '.result | select(.type == "pane_list" and (.panes | type == "array") and all(.panes[]; (.pane_id | type == "string" and length > 0) and (.tab_id | type == "string" and length > 0) and (.workspace_id | type == "string" and length > 0))) | [.panes[] | select(.tab_id == $l.tab_id)] | length == 1 and .[0].pane_id == $l.pane_id and .[0].workspace_id == $l.workspace_id' "$HD_CHILD_STDOUT" >/dev/null || return 3
    hd_cli_read agent list || return $?
    jq -e --arg pane "$pane" --arg tab "$tab" '.result | select(.type == "agent_list" and (.agents | type == "array")) | all(.agents[]; .pane_id != $pane and .tab_id != $tab)' "$HD_CHILD_STDOUT" >/dev/null || return 3
    hd_cli_read pane process-info --pane "$pane" || return $?
    first=$(jq -ce --arg pane "$pane" '.result | select(.type == "pane_process_info") | .process_info | select(.pane_id == $pane and (.shell_pid | type == "number" and . > 0) and .foreground_process_group_id == .shell_pid and (.foreground_processes | length == 1) and .foreground_processes[0].pid == .shell_pid and (.foreground_processes[0].name | IN("bash","zsh","nu","fish","sh")))' "$HD_CHILD_STDOUT") || return 3
    hd_cli_read agent get "$pane" || rc=$?
    [ "$rc" -eq 6 ] && [ "$HD_CHILD_EXIT" -eq 1 ] && jq -e '.error.code | IN("no_agent","agent_not_found")' "$HD_CHILD_STDERR" >/dev/null || return 3
    hd_cli_read pane process-info --pane "$pane" || return $?
    second=$(jq -c '.result.process_info' "$HD_CHILD_STDOUT") || return 3
    printf '%s\n' "$first" | jq -e --argjson other "$second" '. == $other' >/dev/null || return 3
}
sp_loser() {
    local journal=$1 winner=$2 next path rc=0 saved_record=$SP_RECORD saved_name=$SP_NAME saved_workspace=$SP_WORKSPACE saved_target=$SP_TARGET saved_cwd=$SP_CWD saved_kind=$SP_KIND
    printf '%s\n' "$journal" | jq -e --argjson w "$winner" '.target == "dispatcher" and .ownership_mode == "created" and .identity == null and .pane_id != null and .tab_id != null and .workspace_id != null and .pane_id != $w.pane_id and .tab_id != $w.tab_id and (.mutation | IN("tab_create","agent_start"))' >/dev/null || return 3
    SP_WORKSPACE=$(jq -c . "$HD_RUN_ROOT/.workspace.json") || return 3
    ST_DISPATCHER=$winner
    SP_TARGET=dispatcher; SP_CWD=$HD_REPO_PATH; SP_KIND=$(printf '%s\n' "$HD_CONFIG_JSON" | jq -r .dispatcher_kind)
    sp_inventory && sp_reuse || return $?
    SP_RECORD=$saved_record; SP_NAME=$saved_name; SP_WORKSPACE=$saved_workspace; SP_REUSED=false
    SP_TARGET=$saved_target; SP_CWD=$saved_cwd; SP_KIND=$saved_kind
    lc_pane_lock "$(printf '%s\n' "$journal" | jq -r .pane_id)" || return $?
    sp_empty_tab "$journal" || { st_error quarantine 'Losing tab is not a proven empty created shell' 3; return 3; }
    path="$HD_RUN_ROOT/.launches/$(printf '%s\n' "$journal" | jq -r .launch_id).json"
    next=$(printf '%s\n' "$journal" | jq -c '.phase="closing" | .mutation="tab_close"') || return 6
    sp_save launch "$path" "$journal" "$next" || return $?
    journal=$SP_SAVED; ST_OUTCOME=uncertain
    sp_empty_tab "$journal" || return 5
    hd_child_call write -- herdr tab close "$(printf '%s\n' "$journal" | jq -r .tab_id)" || rc=$?
    [ "$rc" -eq 0 ] && jq -se 'length == 1 and (.[0].id | type == "string" and length > 0) and .[0].result.type == "tab_closed"' "$HD_CHILD_STDOUT" >/dev/null || { st_error closure_uncertain 'Empty-tab close acknowledgement is uncertain' 5; return 5; }
    next=$(printf '%s\n' "$journal" | jq -c '.phase="closed"') || return 5
    sp_save launch "$path" "$journal" "$next" || return 5
    lc_pane_unlock || return 5
    ST_OUTCOME=not-submitted
}
sp_recover_record() {
    local journal=$1 record=null next identity metadata pane target name phase path type rc
    target=$(printf '%s\n' "$journal" | jq -r .target)
    name=$(printf '%s\n' "$journal" | jq -r .name)
    phase=$(printf '%s\n' "$journal" | jq -r .phase)
    pane=$(printf '%s\n' "$journal" | jq -r .pane_id)
    type=$target
    if [ "$target" = worker ]; then path="$HD_RUN_ROOT/.workers/$name"; else path="$HD_RUN_ROOT/.dispatcher.json"; fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        hd_safe_file "$path" && hd_json_validate "$type" "$path" || return 3
        record=$(jq -c . "$path") || return 6
        # A later singleton is never overwritten from a historical launch.
        if [ "$target" = dispatcher ] && [ "$(printf '%s\n' "$record" | jq -r .ownership.token)" != "$(printf '%s\n' "$journal" | jq -r .ownership_token)" ]; then
            [ "$phase" != ready ] || return 0
            sp_loser "$journal" "$record"
            return $?
        fi
        printf '%s\n' "$record" | jq -e --argjson l "$journal" '
            .ownership.mode == $l.ownership_mode and .ownership.token == $l.ownership_token and
            (.ownership.mode == "registered" or .ownership.launch_id == $l.launch_id) and
            .name == $l.name and .kind == $l.kind and .cwd == $l.cwd and .config_path == $l.config_path and
            .workspace_id == $l.workspace_id and .tab_id == $l.tab_id and .pane_id == $l.pane_id and
            (.identity == null or $l.identity == null or .identity == $l.identity)' >/dev/null || return 3
        if [ "$(printf '%s\n' "$record" | jq -r .lifecycle)" = closed ]; then return 0; fi
    fi
    identity=$(printf '%s\n' "$journal" | jq -c .identity)
    if [ "$identity" != null ] && st_gone_proof "$identity"; then
        if [ "$target" = worker ]; then
            [ "$record" != null ] || { st_error quarantine 'Gone worker lacks its assignment record' 3; return 3; }
            st_disk_scan || return $?
            st_owned "$record" || return 3
            jq -e 'all(.[]; .request != null and .status != null)' "$HD_PRIVATE/runs.json" >/dev/null || return 3
            jq -e --argjson w "$record" 'all(.[]; if .status.assignment != null and (.status.assignment.worker_name == $w.name or .status.assignment.worker.pane_id == $w.pane_id or .status.assignment.worker.terminal_id == $w.identity.terminal_id) then .status.assignment.worker_name == $w.name and .status.assignment.worker == $w.identity else true end)' "$HD_PRIVATE/runs.json" >/dev/null || return 3
            lc_finish_worker "$record" gone || return $?
        else
            if [ "$record" != null ]; then
                next=$(printf '%s\n' "$record" | jq -c '.lifecycle="gone"') || return 6
                sp_save dispatcher "$path" "$record" "$next" || return $?
                SP_OLD_DISPATCHER=$SP_SAVED
            fi
            next=$(printf '%s\n' "$journal" | jq -c '.phase="closed"') || return 6
            sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$journal" | jq -r .launch_id).json" "$journal" "$next" || return $?
        fi
        return 0
    fi
    [ "$phase" != closing ] || { st_error closure_uncertain 'Retained close is not conclusively gone' 5; ST_OUTCOME=uncertain; return 5; }
    # A complete ready pair needs no writes. The reuse path performs fresh checks.
    if [ "$phase" = ready ] && [ "$record" != null ] && printf '%s\n' "$record" | jq -e --argjson l "$journal" '.identity == $l.identity and (.lifecycle | IN("starting","blocked","quarantined") | not)' >/dev/null; then return 0; fi
    if [ "$(printf '%s\n' "$journal" | jq -r .ownership_mode)" = created ]; then
        hd_safe_file "$HD_RUN_ROOT/.workspace.json" && hd_json_validate workspace "$HD_RUN_ROOT/.workspace.json" || return 3
        SP_WORKSPACE=$(jq -c . "$HD_RUN_ROOT/.workspace.json")
        printf '%s\n' "$SP_WORKSPACE" | jq -e --argjson l "$journal" '.workspace_id == $l.workspace_id and .config_path == $l.config_path and .lifecycle == "ready"' >/dev/null || return 3
        lc_tabs "$(printf '%s\n' "$journal" | jq -r .workspace_id)" && sp_topology "$journal" || return 3
    fi
    metadata=$(hd_live_metadata "$pane") || {
        rc=$?
        [ "$rc" -eq 3 ] || return "$rc"
        # Created is the only phase that proves agent_start has not been attempted.
        [ "$phase" = created ] && [ "$(printf '%s\n' "$journal" | jq -r .mutation)" != agent_start ] || { st_error reconciliation_required 'Pending start has no verified settled occupant' 3; return 3; }
        sp_empty_tab "$journal" || { st_error reconciliation_required 'Pending launch is not a proven empty stable shell' 3; return 3; }
        metadata=null
    }
    if [ "$metadata" != null ]; then
        printf '%s\n' "$metadata" | jq -e --argjson l "$journal" '.pane_id == $l.pane_id and .workspace_id == $l.workspace_id and .tab_id == $l.tab_id and .cwd == $l.cwd and .agent == $l.kind and .name == $l.name and (.agent_status | IN("idle","done"))' >/dev/null || { st_error reconciliation_required 'Pending launch is blocked, working, or conflicting' 3; return 3; }
        identity=$(hd_target_identity "$pane") || return $?
        printf '%s\n' "$journal" | jq -e --argjson i "$identity" '.identity == null or .identity == $i' >/dev/null || return 3
    fi
    if [ "$record" = null ]; then
        next=$(printf '%s\n' "$journal" | jq -c '{schema_version:1,revision:0,name,kind,cwd,config_path,ownership:{mode:.ownership_mode,token:.ownership_token,launch_id:(if .ownership_mode == "created" then .launch_id else null end)},workspace_id,tab_id,pane_id,identity:null,lifecycle:"starting",created_at,updated_at,error:null} + (if .target == "worker" then {role,active_run_id:null,idle_since:null} else {} end)') || return 6
        sp_save "$type" "$path" null "$next" || return $?
        record=$SP_SAVED
    fi
    SP_LAUNCH=$journal; SP_RECORD=$record; SP_RECORD_TYPE=$type; SP_RECORD_PATH=$path
    if [ "$metadata" = null ]; then
        # Check again after saving the worker record. Unknown occupancy retains evidence.
        sp_empty_tab "$journal" || { st_error reconciliation_required 'Pending launch is not a proven empty stable shell' 3; return 3; }
        # Use saved launch parameters, not the next caller's requested role/cwd.
        local saved_name=$SP_NAME saved_kind=$SP_KIND
        SP_NAME=$(printf '%s\n' "$journal" | jq -c .name); SP_KIND=$(printf '%s\n' "$journal" | jq -r .kind)
        sp_start || return $?
        SP_NAME=$saved_name; SP_KIND=$saved_kind
    else
        sp_ready "$identity" || return $?
    fi
}
sp_recover() {
    local path journal phase next workspace=null present=true record identity
    st_live_scan && st_disk_scan || return $?
    if [ "$ST_WORKSPACE" != null ]; then workspace=$ST_WORKSPACE; fi
    # Malformed journals cannot authorize recovery.
    jq -s -e 'all(.[]; . != null)' "$HD_PRIVATE/launches.jsonl" >/dev/null || return 3
    shopt -s nullglob
    for path in "$HD_RUN_ROOT/.launches/"*.json; do
        hd_safe_file "$path" && hd_json_validate launch "$path" || return 3
        journal=$(jq -c . "$path") || return 6
        phase=$(printf '%s\n' "$journal" | jq -r .phase)
        [ "$phase" != closed ] || continue
        SP_LAUNCH=$journal; SP_RETAINED=true
        case "$phase" in
            reserved)
                [ "$(printf '%s\n' "$journal" | jq -c .mutation)" = null ] || return 3
                next=$(printf '%s\n' "$journal" | jq -c '.phase="closed"') || return 6
                sp_save launch "$path" "$journal" "$next" || return $?; continue ;;
            creating|uncertain|failed)
                printf '%s\n' "$journal" | jq -e '.pane_id != null and .tab_id != null and .workspace_id != null' >/dev/null || { st_error reconciliation_required 'Uncertain creation retains its reservation' 3; return 3; } ;;
        esac
        if [ "$workspace" = null ] && [ "$(printf '%s\n' "$journal" | jq -r .mutation)" = workspace_create ]; then
            printf '%s\n' "$journal" | jq -e '.ownership_mode == "created" and .pane_id != null and .tab_id != null and .workspace_id != null' >/dev/null || return 3
            next=$(printf '%s\n' "$journal" | jq -c '{schema_version:1,revision:0,label:"dispatch",ownership_token,launch_id,workspace_id,initial_tab_id:.tab_id,initial_pane_id:.pane_id,config_path,lifecycle:"ready",created_at,updated_at,error:null}') || return 6
            sp_save workspace "$HD_RUN_ROOT/.workspace.json" null "$next" || return $?
            workspace=$SP_SAVED
        fi
        sp_recover_record "$journal" || return $?
    done
    shopt -u nullglob
    # A registered singleton without a journal still requires an explicit gone proof.
    if hd_safe_file "$HD_RUN_ROOT/.dispatcher.json" && hd_json_validate dispatcher "$HD_RUN_ROOT/.dispatcher.json"; then
        record=$(jq -c . "$HD_RUN_ROOT/.dispatcher.json")
        identity=$(printf '%s\n' "$record" | jq -c .identity)
        if [ "$identity" != null ] && st_gone_proof "$identity"; then
            if [ "$(printf '%s\n' "$record" | jq -r .ownership.mode)" = registered ] && [ "$(printf '%s\n' "$record" | jq -r .lifecycle)" != gone ]; then
                lc_registration_journal "$record" || return $?
                journal=$LC_JOURNAL
                next=$(printf '%s\n' "$journal" | jq -c '.phase="closed"')
                sp_save launch "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$journal" | jq -r .launch_id).json" "$journal" "$next" || return $?
            fi
            next=$(printf '%s\n' "$record" | jq -c '.lifecycle="gone"')
            sp_save dispatcher "$HD_RUN_ROOT/.dispatcher.json" "$record" "$next" || return $?
            SP_OLD_DISPATCHER=$SP_SAVED
        fi
    fi
    if [ "$workspace" != null ]; then
        hd_cli_read workspace list || return $?
        jq -ce '.result | select(.type == "workspace_list" and (.workspaces | type == "array")) | .workspaces' "$HD_CHILD_STDOUT" > "$HD_PRIVATE/sp-workspaces.json" || return 6
        if ! jq -e --argjson w "$workspace" 'any(.[]; .workspace_id == $w.workspace_id)' "$HD_PRIVATE/sp-workspaces.json" >/dev/null; then
            st_disk_scan || return $?
            jq -s -e --argjson w "$workspace" 'all(.[]; .workspace_id != $w.workspace_id or .phase == "closed")' "$HD_PRIVATE/launches.jsonl" >/dev/null || return 3
            jq -e --argjson w "$workspace" 'all(.[]; .workspace_id != $w.workspace_id)' "$HD_PRIVATE/agents.json" >/dev/null || return 3
            next=$(printf '%s\n' "$workspace" | jq -c '.lifecycle="gone"') || return 6
            sp_save workspace "$HD_RUN_ROOT/.workspace.json" "$workspace" "$next" || return $?
            SP_OLD_WORKSPACE=$SP_SAVED
        fi
    fi
    SP_LAUNCH=null; SP_RECORD=null; SP_RETAINED=false; SP_NAME=null
    ST_CODE=invalid_arguments; ST_OUTCOME=not-submitted
}
