#!/bin/bash
# Internal state helpers. No output when sourced.
# shellcheck disable=SC2034,SC1091,SC2015,SC2153
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'state-lib.sh must be sourced\n' >&2
    exit 2
fi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
ST_RESULT='{}'
ST_CODE=invalid_arguments
ST_MESSAGE='Invalid arguments'
ST_OUTCOME=not-submitted
st_error() { ST_CODE=$1; ST_MESSAGE=$2; return "$3"; }
st_finish() {
    local rc=$1 error=null
    if [ "$rc" -ne 0 ]; then
        if [ "$ST_CODE" = invalid_arguments ] && [ "$rc" -ne 2 ]; then
            case "$rc" in 3) ST_CODE=failed_precondition; ST_MESSAGE='State precondition failed' ;; 4) ST_CODE=budget_expired; ST_MESSAGE='Command budget expired' ;; 5) ST_CODE=uncertain; ST_MESSAGE='Inspect durable state before retry' ;; *) ST_CODE=io_error; ST_MESSAGE='File or external operation failed' ;; esac
        fi
        error=$(jq -cn --arg code "$ST_CODE" --arg message "$ST_MESSAGE" '{code:$code,message:$message,retryable:false}')
    fi
    hd_emit "$ST_OUTCOME" "$ST_RESULT" "$error"
}
st_init() {
    local started=$HD_STARTED_SECONDS
    hd_config_load || { st_error invalid_config 'Cannot load valid config' 2; return 2; }
    hd_deadline_start "${ST_TIMEOUT:-$(printf '%s\n' "$HD_CONFIG_JSON" | jq -r .ring_timeout_ms)}" || return 2
    HD_STARTED_SECONDS=$started
}
st_path() {
    local type=$1 key=$2
    case "$type" in
        run) printf '%s\n' "$key" | jq -Re --arg type request "${HD_SCHEMA%%# Read a single frontmatter*} run_id" >/dev/null 2>&1 || return 2; ST_PATH="$HD_RUN_ROOT/$key/status"; ST_TYPE=status ;;
        worker) printf '%s\n' "$key" | jq -Re 'length <= 32 and test("^[a-z][a-z0-9_-]*-[1-9][0-9]*$")' >/dev/null || return 2; ST_PATH="$HD_RUN_ROOT/.workers/$key"; ST_TYPE=worker ;;
        launch) [[ "$key" =~ ^[0-9a-f]{32}$ ]] || return 2; ST_PATH="$HD_RUN_ROOT/.launches/$key.json"; ST_TYPE=launch ;;
        workspace|dispatcher) [ "$key" = current ] || return 2; ST_PATH="$HD_RUN_ROOT/.$type.json"; ST_TYPE=$type ;;
        *) return 2 ;;
    esac
    hd_no_links "$ST_PATH" || return 2
}
st_load() {
    hd_safe_file "$ST_PATH" && hd_json_validate "$ST_TYPE" "$ST_PATH" || { st_error malformed_record 'Record is missing or invalid' 3; return 3; }
    ST_DOCUMENT=$(jq -c . "$ST_PATH") || return 6
    case "$ST_TYPE" in
        status) printf '%s\n' "$ST_DOCUMENT" | jq -e --arg key "$ST_KEY" '.run_id == $key' >/dev/null || return 3 ;;
        worker) printf '%s\n' "$ST_DOCUMENT" | jq -e --arg key "$ST_KEY" '.name == $key' >/dev/null || return 3 ;;
        launch) printf '%s\n' "$ST_DOCUMENT" | jq -e --arg key "$ST_KEY" '.launch_id == $key' >/dev/null || return 3 ;;
    esac
}
st_conflict() {
    ST_RESULT=$(printf '%s\n' "$ST_DOCUMENT" | jq -c '{current_revision:.revision,current_state:(.state // null),committed:false}')
    st_error conflict 'Saved revision or state changed' 3
}
st_lock() {
    local rc
    hd_lock_acquire "$HD_RUN_ROOT/.locks/state" || { rc=$?; st_error lock_unavailable 'Cannot take state lock' "$rc"; return "$rc"; }
    ST_LOCK_TOKEN=$HD_LOCK_TOKEN
}
st_unlock() { hd_lock_release "$HD_RUN_ROOT/.locks/state" "$ST_LOCK_TOKEN"; }
st_frontmatter() {
    jq -Rsc 'split("\n") as $l | ($l[1:] | index("---")) as $e | $l[1:($e+1)] | join("\n") | fromjson' "$1"
}
st_report() {
    local id=$1 status=$2 path="$HD_RUN_ROOT/$1/result.md"
    hd_safe_file "$path" && hd_json_validate result "$path" || return 3
    st_frontmatter "$path" | jq -e --arg id "$id" --argjson s "$status" '.run_id == $id and .worker_name == $s.assignment.worker_name and .assignment_id == $s.assignment.assignment_id and .worker == $s.assignment.worker' >/dev/null || return 3
    jq -Rse '
        split("\n") as $l | ($l[1:] | index("---")) as $e | $l[($e+2):] as $body |
        ["## Summary","## Findings","## Evidence","## Checks","## Limits"] as $heads |
        [$body[] | select(startswith("## "))] == $heads and
        all($heads[]; . as $h | ($body | index($h)) as $i |
            $body[($i+1):] | (map(startswith("## ")) | index(true)) as $end |
            .[:$end] | join("\n") | test("\\S"))' "$path" >/dev/null || return 3
}
st_issue() {
    jq -cn --arg path "$1" --arg code "$2" --arg message "$3" --argjson run "${4:-null}" --argjson worker "${5:-null}" '{path:$path,code:$code,message:$message,run_id:$run,worker_name:$worker}' >> "$HD_PRIVATE/issues.jsonl"
}
st_live_scan() {
    local agent pane identity name rc
    : > "$HD_PRIVATE/live.jsonl"
    : > "$HD_PRIVATE/live-issues.jsonl"
    hd_cli_read agent list || { rc=$?; st_error live_query_failed 'Live inventory failed' "$rc"; return "$rc"; }
    jq -ce '.result | select(.type == "agent_list" and (.agents | type == "array")) | .agents' "$HD_CHILD_STDOUT" > "$HD_PRIVATE/agents.json" || { st_error adapter_schema 'Invalid live inventory' 6; return 6; }
    while IFS= read -r agent; do
        pane=$(printf '%s\n' "$agent" | jq -er '.pane_id | select(type == "string" and length > 0)') || return 6
        identity=$(hd_target_identity "$pane") || {
            rc=$?
            if [ "$rc" -ne 3 ]; then st_error live_query_failed 'Cannot pin live occupant' "$rc"; return "$rc"; fi
            identity=null
            jq -cn --arg path "$pane" '{path:$path,code:"live_identity_unavailable",message:"Live occupant identity is missing or unsupported",run_id:null,worker_name:null}' >> "$HD_PRIVATE/live-issues.jsonl"
        }
        # Missing identity is not ownership or absence evidence.
        printf '%s\n' "$agent" | jq -e --argjson i "$identity" '($i == null or (.pane_id == $i.pane_id and .terminal_id == $i.terminal_id and .agent == $i.kind and .agent_session == $i.agent_session)) and (.workspace_id | type == "string" and length > 0) and (.tab_id | type == "string" and length > 0) and (.cwd | type == "string" and startswith("/")) and (.agent_status | type == "string" and length > 0) and (.name == null or (.name | type == "string")) and (.state_change_seq == null or (.state_change_seq | type == "number" and floor == . and . >= 0))' >/dev/null || { st_error snapshot_changed 'Live snapshot changed or is invalid' 3; return 3; }
        name=$(printf '%s\n' "$agent" | jq -c --argjson identity "$identity" '{identity:$identity,name:(.name // null),workspace_id,tab_id,cwd,agent_status,state_change_seq:(.state_change_seq // null)}') || return 6
        printf '%s\n' "$name" >> "$HD_PRIVATE/live.jsonl"
    done < <(jq -c '.[]' "$HD_PRIVATE/agents.json")
    jq -s '.' "$HD_PRIVATE/live.jsonl" > "$HD_PRIVATE/live.json"
}
st_owned() {
    # This proves saved creation ownership, not safe closure or readiness.
    local record=$1 launch workspace
    launch=$(printf '%s\n' "$record" | jq -r .ownership.launch_id)
    hd_safe_file "$HD_RUN_ROOT/.launches/$launch.json" && hd_json_validate launch "$HD_RUN_ROOT/.launches/$launch.json" || return 3
    jq -e --argjson r "$record" --arg config "$HD_CONFIG_PATH" '
        .target == "worker" and .ownership_mode == "created" and .launch_id == $r.ownership.launch_id and
        .ownership_token == $r.ownership.token and .name == $r.name and .role == $r.role and
        .kind == $r.kind and .cwd == $r.cwd and .config_path == $config and $r.config_path == $config and
        .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and .pane_id == $r.pane_id and
        .identity == $r.identity and $r.identity != null and (.phase | IN("ready","closing","closed")) and
        (if ($r.lifecycle | IN("closed","gone")) then .phase == "closed" else true end)' "$HD_RUN_ROOT/.launches/$launch.json" >/dev/null || return 3
    # A closed journal preserves historical ownership even if a crash left the
    # worker cache unchanged, or the workspace has since been replaced.
    if jq -e '.phase == "closed"' "$HD_RUN_ROOT/.launches/$launch.json" >/dev/null; then return 0; fi
    hd_safe_file "$HD_RUN_ROOT/.workspace.json" && hd_json_validate workspace "$HD_RUN_ROOT/.workspace.json" || return 3
    workspace=$(jq -c . "$HD_RUN_ROOT/.workspace.json") || return 6
    printf '%s\n' "$workspace" | jq -e --argjson r "$record" --arg config "$HD_CONFIG_PATH" '.workspace_id == $r.workspace_id and .config_path == $config and .lifecycle == "ready"' >/dev/null || return 3
    # Workspace creation also needs its own matching historical journal.
    launch=$(printf '%s\n' "$workspace" | jq -r .launch_id)
    hd_safe_file "$HD_RUN_ROOT/.launches/$launch.json" && hd_json_validate launch "$HD_RUN_ROOT/.launches/$launch.json" || return 3
    jq -e --argjson w "$workspace" '.ownership_mode == "created" and .ownership_token == $w.ownership_token and .workspace_id == $w.workspace_id and .tab_id == $w.initial_tab_id and .pane_id == $w.initial_pane_id' "$HD_RUN_ROOT/.launches/$launch.json" >/dev/null || return 3
}
# A proof is useful only with the complete disk inventory that produced it.
# Run this under state lock. It performs no CLI operations.
st_freeze_scan() {
    local path row saved current
    while IFS= read -r row; do
        path=$(printf '%s\n' "$row" | jq -r .path)
        saved=$(printf '%s\n' "$row" | jq -c .content)
        hd_safe_file "$path" || { st_error conflict 'Scanned file disappeared' 3; return 3; }
        current=$(jq -Rsc . "$path") || return 6
        [ "$saved" = "$current" ] || { st_error conflict 'Scanned file changed' 3; return 3; }
    done < "$HD_PRIVATE/files.jsonl"
    shopt -s nullglob dotglob
    for path in "$HD_RUN_ROOT/"* "$HD_RUN_ROOT/.workers/"* "$HD_RUN_ROOT/.launches/"* "$HD_RUN_ROOT/.workspace.json" "$HD_RUN_ROOT/.dispatcher.json" "$HD_REPO_PATH/roles/"*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        case "$path" in "$HD_RUN_ROOT/".*) case "$path" in */.workspace.json|*/.dispatcher.json|*/.workers/*|*/.launches/*) ;; *) continue ;; esac ;; esac
        if [ -d "$path" ] && [ ! -L "$path" ]; then path="$path/status"; fi
        case "$path" in */.gitkeep) continue ;; esac
        jq -se --arg path "$path" 'any(.[]; .path == $path)' "$HD_PRIVATE/files.jsonl" >/dev/null || { st_error conflict 'Disk inventory changed' 3; return 3; }
    done
    shopt -u nullglob dotglob
}
# A successful list without the saved pane is not enough. Require the explicit
# missing-pane/no-agent error too. A replacement pane/terminal is never gone proof.
st_gone_proof() {
    local identity=$1 pane rc=0
    pane=$(printf '%s\n' "$identity" | jq -r .pane_id)
    jq -e --argjson i "$identity" 'all(.[]; .pane_id != $i.pane_id and .terminal_id != $i.terminal_id)' "$HD_PRIVATE/agents.json" >/dev/null || { st_error quarantine 'Replacement or conflicting occupant is present' 3; return 3; }
    hd_cli_read agent get "$pane" || rc=$?
    [ "$rc" -eq 6 ] && [ "$HD_CHILD_EXIT" -eq 1 ] &&
        jq -e '.error.code | IN("pane_not_found","agent_not_found","no_agent")' "$HD_CHILD_STDERR" >/dev/null 2>&1 || { st_error quarantine 'Worker exit is not conclusive' 3; return 3; }
    ST_PROOF_IDENTITY=$identity
}
st_disk_scan() {
    local path name metadata request status result valid classification record live held type doc
    for type in issues roles runs workers launches snapshots; do : > "$HD_PRIVATE/$type.jsonl"; done
    if [ -f "$HD_PRIVATE/live-issues.jsonl" ]; then cp -- "$HD_PRIVATE/live-issues.jsonl" "$HD_PRIVATE/issues.jsonl" || return 6; fi
    ST_WORKSPACE=null; ST_DISPATCHER=null
    for path in "$HD_RUN_ROOT/.workers" "$HD_RUN_ROOT/.launches" "$HD_REPO_PATH/roles"; do
        if ! hd_no_links "$path" || { [ -e "$path" ] && [ ! -d "$path" ]; }; then st_issue "$path" unsafe_path 'Record directory is unsafe'; fi
    done
    # Snapshot immutable requests, roles, and every state file before interpreting them.
    : > "$HD_PRIVATE/files.jsonl"
    shopt -s nullglob dotglob
    for path in "$HD_REPO_PATH/roles/"* "$HD_RUN_ROOT/"*/request.md "$HD_RUN_ROOT/"*/status "$HD_RUN_ROOT/.workers/"* "$HD_RUN_ROOT/.launches/"* "$HD_RUN_ROOT/.workspace.json" "$HD_RUN_ROOT/.dispatcher.json"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        case "$path" in */.gitkeep|*/.staging/*) continue ;; esac
        hd_safe_file "$path" || continue
        jq -Rsc --arg path "$path" '{path:$path,content:.}' "$path" >> "$HD_PRIVATE/files.jsonl" || return 6
    done
    for path in "$HD_REPO_PATH/roles/"*; do
        name=$(basename "$path" .md)
        [ "$name" != .gitkeep ] || continue
        metadata=null
        if hd_safe_file "$path" && hd_json_validate role "$path"; then metadata=$(st_frontmatter "$path"); fi
        if ! printf '%s\n' "$metadata" | jq -e --arg name "$name" '.name == $name' >/dev/null; then
            st_issue "$path" malformed_role 'Invalid role metadata'
            metadata=null
        fi
        jq -cn --arg name "$name" --arg path "$path" --argjson m "$metadata" --argjson c "$HD_CONFIG_JSON" '{name:$name,path:$path,metadata:$m,effective_kind:(if $m == null then null else ($c.worker_kinds[$name] // $m.kind) end),effective_idle_ttl_seconds:(if $m == null then null else ($m.idle_ttl_seconds // $c.idle_ttl_seconds) end)}' >> "$HD_PRIVATE/roles.jsonl"
    done
    for path in "$HD_RUN_ROOT/"*; do
        name=$(basename "$path")
        case "$name" in .*) continue ;; esac
        request=null; status=null; result=null; valid=false; classification=quarantined
        if hd_no_links "$path" && [ -d "$path" ] && hd_safe_file "$path/request.md" && hd_json_validate request "$path/request.md"; then request=$(st_frontmatter "$path/request.md"); fi
        if hd_safe_file "$path/status" && hd_json_validate status "$path/status"; then status=$(jq -c . "$path/status"); fi
        if printf '%s\n' "$request" | jq -e --arg name "$name" --argjson s "$status" '.run_id == $name and $s.run_id == $name and .created_at == $s.created_at' >/dev/null; then
            classification=$(printf '%s\n' "$status" | jq -r 'if .state == "new" then "queued" elif .state == "dispatched" then "assigned" elif .state == "failed" then "failed" else "completed" end')
        else
            st_issue "$path" malformed_run 'Invalid published run' "$(jq -cn --arg n "$name" '$n')"
            request=null; status=null
        fi
        if [ -e "$path/result.md" ] || [ -L "$path/result.md" ]; then
            result=$(jq -cn --arg p "$path/result.md" '$p')
            if st_report "$name" "$status"; then valid=true; else st_issue "$path/result.md" invalid_report 'Invalid final report' "$(jq -cn --arg n "$name" '$n')"; fi
        fi
        jq -cn --arg id "$name" --arg path "$path" --argjson r "$request" --argjson s "$status" --argjson result "$result" --argjson valid "$valid" --arg classification "$classification" '{run_id:$id,run_path:$path,request:$r,status:$s,result_path:$result,result_valid:$valid,classification:$classification}' >> "$HD_PRIVATE/runs.jsonl"
    done
    jq -s '.' "$HD_PRIVATE/runs.jsonl" > "$HD_PRIVATE/runs.json"
    for path in "$HD_RUN_ROOT/.workspace.json" "$HD_RUN_ROOT/.dispatcher.json" "$HD_RUN_ROOT/.launches/"*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        case "$path" in */.workspace.json) type=workspace ;; */.dispatcher.json) type=dispatcher ;; *) type=launch ;; esac
        doc=null
        if hd_safe_file "$path" && hd_json_validate "$type" "$path"; then
            doc=$(jq -c . "$path")
            if [ "$type" = launch ] && [ "$(basename "$path")" != "$(printf '%s\n' "$doc" | jq -r .launch_id).json" ]; then doc=null; st_issue "$path" malformed_record 'Launch filename does not match ID'; fi
        else st_issue "$path" malformed_record 'Invalid saved record'; fi
        jq -cn --arg path "$path" --argjson document "$doc" '{path:$path,document:$document}' >> "$HD_PRIVATE/snapshots.jsonl"
        case "$type" in workspace) ST_WORKSPACE=$doc ;; dispatcher) ST_DISPATCHER=$doc ;; launch) printf '%s\n' "$doc" >> "$HD_PRIVATE/launches.jsonl" ;; esac
    done
    for path in "$HD_RUN_ROOT/.workers/"*; do
        name=$(basename "$path"); record=null; live=null; classification=quarantined
        held=$(jq -c --arg n "$name" '[.[] | select(.status.assignment.worker_name == $n and .status.worker_release.phase == "held") | .run_id]' "$HD_PRIVATE/runs.json")
        if hd_safe_file "$path" && hd_json_validate worker "$path" && jq -e --arg n "$name" '.name == $n' "$path" >/dev/null; then
            record=$(jq -c . "$path")
            live=$(jq -c --argjson r "$record" '[.[] | select(.identity == $r.identity and .workspace_id == $r.workspace_id and .tab_id == $r.tab_id and .cwd == $r.cwd)] | if length == 1 then .[0] else null end' "$HD_PRIVATE/live.json")
            if st_owned "$record" && [ "$(printf '%s\n' "$held" | jq length)" -le 1 ]; then
                if printf '%s\n' "$record" | jq -e '.lifecycle == "closed" or .lifecycle == "gone"' >/dev/null; then classification=closed
                elif [ "$live" != null ] && jq -e '.phase == "closed"' "$HD_RUN_ROOT/.launches/$(printf '%s\n' "$record" | jq -r .ownership.launch_id).json" >/dev/null; then
                    classification=quarantined
                elif [ "$live" = null ]; then
                    if jq -e --argjson r "$record" 'any(.[]; .pane_id == $r.pane_id or .terminal_id == $r.identity.terminal_id)' "$HD_PRIVATE/agents.json" >/dev/null; then classification=quarantined
                    else classification=stale; fi
                elif [ "$held" != '[]' ]; then classification=occupied
                else classification=$(printf '%s\n' "$live" | jq -r 'if .agent_status == "idle" or .agent_status == "done" then "idle" elif .agent_status == "blocked" then "blocked" else "quarantined" end'); fi
            fi
        fi
        jq -cn --arg path "$path" --argjson document "$record" '{path:$path,document:$document}' >> "$HD_PRIVATE/snapshots.jsonl"
        [ "$classification" != quarantined ] || st_issue "$path" ownership_conflict 'Missing or conflicting worker ownership' null "$(jq -cn --arg n "$name" '$n')"
        jq -cn --arg name "$name" --argjson r "$record" --argjson l "$live" --argjson held "$held" --arg c "$classification" '{name:$name,record:$r,live:$l,occupancy_run_ids:$held,classification:$c}' >> "$HD_PRIVATE/workers.jsonl"
    done
    # Missing records and duplicate occupant assignments must not disappear from scans.
    jq -s '.' "$HD_PRIVATE/workers.jsonl" > "$HD_PRIVATE/workers.json"
    while IFS= read -r name; do
        st_issue "$HD_RUN_ROOT/.workers/$name" missing_worker 'Assignment has no worker record' null "$(jq -cn --arg n "$name" '$n')"
    done < <(jq -r --slurpfile workers "$HD_PRIVATE/workers.json" '[.[] | .status.assignment.worker_name // empty] | unique[] | . as $n | select([$workers[0][] | select(.name == $n)] | length == 0)' "$HD_PRIVATE/runs.json")
    # A held assignment to the same pane/terminal is a conflict even under another name.
    while IFS= read -r name; do
        st_issue "$HD_RUN_ROOT/.workers/$name" duplicate_assignment 'Multiple held assignments share an occupant' null "$(jq -cn --arg n "$name" '$n')"
        jq --arg n "$name" 'map(if .name == $n then .classification="quarantined" else . end)' "$HD_PRIVATE/workers.json" > "$HD_PRIVATE/workers.next.json"
        mv -- "$HD_PRIVATE/workers.next.json" "$HD_PRIVATE/workers.json" || return 6
    done < <(jq -r '[.[] | select(.status.worker_release.phase == "held") | .status.assignment] as $a | $a[] | . as $x | select([$a[] | select(.worker_name == $x.worker_name or .worker.pane_id == $x.worker.pane_id or .worker.terminal_id == $x.worker.terminal_id)] | length > 1) | .worker_name' "$HD_PRIVATE/runs.json" | sort -u)
    jq -c '.[]' "$HD_PRIVATE/workers.json" > "$HD_PRIVATE/workers.jsonl"
    shopt -u nullglob dotglob
}
