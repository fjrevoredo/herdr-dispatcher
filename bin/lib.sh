#!/bin/bash
# Internal shared API. No output when sourced.
# Public API variables are consumed by the shipped helpers.
# shellcheck disable=SC2034
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf 'lib.sh must be sourced by a shipped helper\n' >&2
    exit 2
fi
umask 077
HD_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# Kept here so bin contains only the shipped Bash helpers.
IFS= read -r -d '' HD_SCHEMA <<'HD_SCHEMA_EOF' || :
# Schema and saved-state invariants. Transition and ownership proofs belong to callers.
def fields($required; $optional): type == "object" and ((keys - ($required + $optional)) | length == 0) and (($required - keys) | length == 0);
def text: type == "string" and length > 0;
def uint: type == "number" and floor == . and . >= 0;
def positive: uint and . > 0;
def ttl: uint and . <= 2147483647;
def budget: positive and . <= 300000;
def kind: . == "pi" or . == "claude";
def token: type == "string" and test("^[0-9a-f]{32}$");
def role_name: type == "string" and test("^[a-z][a-z0-9_-]{0,23}$");
def worker_name: type == "string" and length <= 32 and test("^[a-z][a-z0-9_-]*-[1-9][0-9]*$");
def path: text and startswith("/") and (split("/")[1:] | all(. != "" and . != "." and . != ".."));
def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and (try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | strftime("%Y-%m-%dT%H:%M:%SZ")) catch null) == .;
def run_id: type == "string" and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$") and (.[0:16] as $s | (try ($s | strptime("%Y%m%dT%H%M%SZ") | mktime | strftime("%Y%m%dT%H%M%SZ")) catch null) == $s);
def nullable(f): . == null or f;
def code: type == "string" and test("^[a-z][a-z0-9_]*$");
def saved_error: fields(["code","message","at"]; []) and (.code | code) and (.message | text) and (.at | utc);
def session: fields(["agent","kind","source","value"]; []) and (.value | text) and (if .agent == "pi" then .kind == "path" and .source == "herdr:pi" and (.value | startswith("/")) elif .agent == "claude" then .kind == "id" and .source == "herdr:claude" else false end);
def occupant: fields(["pane_id","terminal_id","kind","agent_session","foreground_process_group_id"]; []) and (.pane_id | text) and (.terminal_id | text) and (.kind | kind) and (.agent_session | session) and .kind == .agent_session.agent and (.foreground_process_group_id | positive);
def config: fields(["schema_version","repo_path","dispatcher_kind","worker_kinds","idle_ttl_seconds","ring_timeout_ms","startup_timeout_ms","trust_roots"]; ["claude_model"]) and .schema_version == 1 and (.repo_path | path) and (.dispatcher_kind | kind) and (.worker_kinds | type == "object" and all(keys[]; role_name) and all(.[]; kind)) and (.idle_ttl_seconds | ttl) and (.ring_timeout_ms | budget) and (.startup_timeout_ms | budget) and (.trust_roots | type == "array" and length == (unique | length) and all(.[]; path)) and (if has("claude_model") then .claude_model | type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z") else true end);
def role: fields(["schema_version","name","kind","capabilities","max_instances"]; ["idle_ttl_seconds"]) and .schema_version == 1 and (.name | role_name) and (.kind | kind) and (.capabilities | type == "array" and length > 0 and length == (unique | length) and all(.[]; text)) and (.max_instances | positive and . <= 2147483647) and (if has("idle_ttl_seconds") then .idle_ttl_seconds | ttl else true end);
def request: fields(["schema_version","run_id","from_pane","requester","cwd","created_at"]; ["role"]) and .schema_version == 1 and (.run_id | run_id) and (.requester | occupant) and .from_pane == .requester.pane_id and (.cwd | path) and (.created_at | utc) and (if has("role") then .role | text else true end);
def report: fields(["schema_version","run_id","worker_name","assignment_id","worker","created_at"]; []) and .schema_version == 1 and (.run_id | run_id) and (.worker_name | worker_name) and (.assignment_id | token) and (.worker | occupant) and (.created_at | utc);
def assignment: fields(["assignment_id","worker_name","role","kind","cwd","worker","assigned_at"]; []) and (.assignment_id | token) and (.worker_name | worker_name) and (.role | role_name) and (.kind | kind) and (.cwd | path) and (.worker | occupant) and .kind == .worker.kind and (.assigned_at | utc);
def attempt: fields(["phase","attempt_id","started_at","acknowledged_at","error"]; []) and (.phase | IN("none","sending","sent","not-submitted","uncertain")) and (.attempt_id | nullable(token)) and (.started_at | nullable(utc)) and (.acknowledged_at | nullable(utc)) and (.error | nullable(saved_error));
def attempt_consistent:
    if .phase == "none" then .attempt_id == null and .started_at == null and .acknowledged_at == null and .error == null
    else .attempt_id != null and .started_at != null and
        (if .phase == "sent" then .acknowledged_at != null and .error == null
         elif .phase == "sending" then .acknowledged_at == null and .error == null
         else .acknowledged_at == null end) end;
def status_consistent:
    (.delivery | attempt_consistent) and (.nudge | attempt_consistent) and
    (if .nudge.settled_observed_at != null then .nudge.phase == "sent" else true end) and
    (if .nudge.phase != "none" then .delivery.phase == "sent" else true end) and
    (if .assignment == null then .worker_release.phase == "none" and .delivery.phase == "none" and .nudge.phase == "none" and (.state | IN("new","failed"))
     else .state != "new" and .worker_release.phase != "none" and .delivery.phase != "none" end) and
    (if .worker_release.phase == "none" or .worker_release.phase == "held" then .worker_release.observed_at == null and .worker_release.reason == null
     elif .worker_release.phase == "released" then (.state | IN("done","relayed")) and .worker_release.observed_at != null and .worker_release.reason == "valid_result_settled"
     else .worker_release.observed_at != null and (.worker_release.reason | IN("worker_gone","owned_worker_closed")) end) and
    (if .state == "new" or .state == "dispatched" then .error == null and .notice.type == null and .notice.phase == "none"
     elif .state == "failed" then .error != null and .notice.type == "FAILED" and .notice.phase != "none"
     else .error == null and .notice.type == "RESULT" and .notice.phase != "none" and
         (if .state == "relayed" then .notice.phase == "sent" else .notice.phase != "sent" end) end) and
    (if .notice.phase == "none" then .notice.type == null and .notice.attempts == 0 and .notice.attempt_id == null and .notice.last_attempt_at == null and .notice.in_flight == false and .notice.last_outcome == null and .notice.error == null
     else .notice.type != null and
         (if .notice.attempts == 0 then .notice.phase == "pending" and .notice.in_flight == false and .notice.attempt_id == null and .notice.last_attempt_at == null and .notice.last_outcome == null and .notice.error == null
          else .notice.attempt_id != null and .notice.last_attempt_at != null and
              (if .notice.in_flight then .notice.phase == "pending"
               elif .notice.phase == "sent" then .notice.last_outcome == "input-accepted"
               elif .notice.phase == "missing-requester" then .notice.last_outcome == "missing-requester"
               else (.notice.last_outcome | IN("not-submitted","uncertain")) end) end) end) and
    (if .human.late_result then .state == "failed" and .assignment != null else true end);
def status: status_consistent and fields(["schema_version","run_id","revision","state","created_at","updated_at","assignment","worker_release","delivery","nudge","notice","error","human"]; []) and .schema_version == 1 and (.run_id | run_id) and (.revision | uint) and (.state | IN("new","dispatched","done","relayed","failed")) and (.created_at | utc) and (.updated_at | utc) and (.assignment | nullable(assignment)) and (.worker_release | fields(["phase","observed_at","reason"]; []) and (.phase | IN("none","held","released","retired")) and (.observed_at | nullable(utc)) and (.reason | IN(null,"valid_result_settled","worker_gone","owned_worker_closed"))) and (.delivery | attempt) and (.nudge | fields(["phase","attempt_id","started_at","acknowledged_at","settled_observed_at","error"]; []) and (del(.settled_observed_at) | attempt) and (.settled_observed_at | nullable(utc))) and (.notice | fields(["type","phase","attempts","last_attempt_at","attempt_id","in_flight","last_outcome","error"]; []) and (.type | IN(null,"RESULT","FAILED")) and (.phase | IN("none","pending","sent","missing-requester")) and (.attempts | uint) and (.last_attempt_at | nullable(utc)) and (.attempt_id | nullable(token)) and (.in_flight | type == "boolean") and (.last_outcome | IN(null,"input-accepted","not-submitted","uncertain","missing-requester")) and (.error | nullable(saved_error))) and (.error | nullable(saved_error)) and (.human | fields(["attention","missing_requester","late_result"]; []) and all(.[]; type == "boolean"));
def ownership: fields(["mode","token","launch_id"]; []) and (.token | token) and (if .mode == "created" then .launch_id | token elif .mode == "registered" then .launch_id == null else false end);
def common_record: .schema_version == 1 and (.revision | uint) and (.kind | kind) and (.cwd | path) and (.config_path | path) and (.created_at | utc) and (.updated_at | utc) and (.error | nullable(saved_error));
def worker: fields(["schema_version","revision","name","role","kind","cwd","config_path","ownership","workspace_id","tab_id","pane_id","identity","lifecycle","active_run_id","idle_since","created_at","updated_at","error"]; []) and common_record and (.name | worker_name) and (.role | role_name) and (.ownership | ownership and .mode == "created") and (.workspace_id | text) and (.tab_id | text) and (.pane_id | text) and (.identity | nullable(occupant)) and (if .identity != null then .identity.pane_id == .pane_id and .identity.kind == .kind else true end) and (.lifecycle | IN("starting","ready","occupied","idle","blocked","quarantined","closing","closed","gone")) and (.active_run_id | nullable(run_id)) and (.idle_since | nullable(utc));
def dispatcher: fields(["schema_version","revision","name","kind","cwd","config_path","workspace_id","tab_id","pane_id","identity","ownership","lifecycle","created_at","updated_at","error"]; []) and common_record and .name == "dispatcher" and (.workspace_id | text) and (.tab_id | text) and (.pane_id | text) and (.identity | nullable(occupant)) and (if .identity != null then .identity.pane_id == .pane_id and .identity.kind == .kind else true end) and (.ownership | ownership) and (.lifecycle | IN("starting","ready","blocked","quarantined","gone"));
def workspace: fields(["schema_version","revision","label","ownership_token","launch_id","workspace_id","initial_tab_id","initial_pane_id","config_path","lifecycle","created_at","updated_at","error"]; []) and .schema_version == 1 and (.revision | uint) and .label == "dispatch" and (.ownership_token | token) and (.launch_id | token) and (.workspace_id | text) and (.initial_tab_id | text) and (.initial_pane_id | text) and (.config_path | path) and (.lifecycle | IN("ready","quarantined","gone")) and (.created_at | utc) and (.updated_at | utc) and (.error | nullable(saved_error));
def launch: fields(["schema_version","revision","launch_id","target","name","role","kind","cwd","config_path","ownership_token","ownership_mode","phase","mutation","workspace_id","tab_id","pane_id","identity","created_at","updated_at","error","human_notified"]; []) and common_record and (.launch_id | token) and (.ownership_token | token) and (.ownership_mode | IN("created","registered")) and (if .target == "worker" then (.name | worker_name) and (.role | role_name) and .ownership_mode == "created" elif .target == "dispatcher" then .name == "dispatcher" and .role == null else false end) and (.phase | IN("reserved","creating","created","starting","ready","blocked","uncertain","failed","closing","closed")) and (.mutation | IN(null,"workspace_create","tab_create","agent_start","agent_rename","pane_close","tab_close")) and (.workspace_id | nullable(text)) and (.tab_id | nullable(text)) and (.pane_id | nullable(text)) and (.identity | nullable(occupant)) and (.human_notified | type == "boolean");
def lock: fields(["schema_version","pid","process_started_at","token","created_at"]; []) and .schema_version == 1 and (.pid | positive) and (.process_started_at | text) and (.token | token) and (.created_at | utc);
# Read a single frontmatter object. The body is not executable input.
def frontmatter: split("\n") as $lines | if $lines[0] != "---" then error("missing frontmatter") else ($lines[1:] | index("---")) as $end | if $end == null then error("missing delimiter") else $lines[1:($end+1)] | join("\n") | fromjson end end;
if type == "string" then [.] else . end | if length != 1 then false else .[0] | if ([.. | strings | contains("\u0000")] | any) then false else (if $type == "role" or $type == "request" or $type == "result" then frontmatter else . end) | ([.. | strings | contains("\u0000")] | any | not) and (if $type == "config" then config elif $type == "role" then role elif $type == "request" then request elif $type == "result" then report elif $type == "status" then status elif $type == "worker" then worker elif $type == "workspace" then workspace elif $type == "dispatcher" then dispatcher elif $type == "launch" then launch elif $type == "lock" then lock else false end) end end
HD_SCHEMA_EOF

HD_PRIVATE=''
HD_LOCK_PATHS=()
HD_LOCK_TOKENS=()
HD_ACTIVE_CHILD=''
HD_ACTIVE_WATCHDOG=''

hd_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
hd_random() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
hd_deadline_start() {
    case "${1:-}" in ''|*[!0-9]*) return 2 ;; esac
    [ "${#1}" -le 6 ] && [ "$1" -ge 1 ] && [ "$1" -le 300000 ] || return 2
    HD_BUDGET_MS=$((10#$1))
    HD_STARTED_SECONDS=$SECONDS
}
hd_remaining_ms() {
    local remaining
    remaining=$((HD_BUDGET_MS - 1000 * (SECONDS - HD_STARTED_SECONDS) - 1000))
    [ "$remaining" -gt 0 ] || return 4
    printf '%s\n' "$remaining"
}
hd_sleep() {
    local remaining delay
    remaining=$(hd_remaining_ms) || return 4
    if [ "$remaining" -gt 50 ]; then remaining=50; fi
    printf -v delay '0.%03d' "$remaining"
    sleep "$delay"
}
hd_no_links() {
    local path=$1 part current=''
    case "$path" in /*) ;; *) return 2 ;; esac
    [ "$path" = / ] && return 0
    while [ -n "$path" ]; do
        path=${path#/}
        part=${path%%/*}
        case "$part" in ''|.|..) return 2 ;; esac
        current="$current/$part"
        [ ! -L "$current" ] || return 2
        if [ "$path" = "$part" ]; then break; fi
        path=${path#*/}
    done
}
hd_directory() {
    [ -d "$1" ] || return 2
    (cd "$1" && pwd -P) || return 6
}
hd_safe_file() { hd_no_links "$1" && [ -f "$1" ] && [ ! -L "$1" ]; }
hd_private_init() {
    [ -n "$HD_PRIVATE" ] && return 0
    HD_PRIVATE=$(mktemp -d "${TMPDIR:-/tmp}/herdr-dispatcher.XXXXXX") || return 6
    HD_PRIVATE=$(cd "$HD_PRIVATE" && pwd -P) || return 6
}
hd_cleanup() {
    local i
    if [ -n "$HD_ACTIVE_CHILD" ]; then
        kill -TERM "$HD_ACTIVE_CHILD" 2>/dev/null || :
        sleep 0.1
        kill -KILL "$HD_ACTIVE_CHILD" 2>/dev/null || :
        wait "$HD_ACTIVE_CHILD" 2>/dev/null || :
    fi
    if [ -n "$HD_ACTIVE_WATCHDOG" ]; then
        kill "$HD_ACTIVE_WATCHDOG" 2>/dev/null || :
        wait "$HD_ACTIVE_WATCHDOG" 2>/dev/null || :
    fi
    for ((i=${#HD_LOCK_PATHS[@]}-1; i>=0; i--)); do
        hd_lock_release "${HD_LOCK_PATHS[$i]}" "${HD_LOCK_TOKENS[$i]}" || :
    done
    if [ -n "$HD_PRIVATE" ] && [ -d "$HD_PRIVATE" ] && [ ! -L "$HD_PRIVATE" ]; then
        rm -rf -- "$HD_PRIVATE"
    fi
}
trap hd_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

hd_json_validate() {
    local type=$1 file=$2
    [ -f "$file" ] && [ ! -L "$file" ] || return 2
    [ -r "$file" ] || return 6
    iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1 || return 2
    case "$type" in
        role|request|result) jq -Rse --arg type "$type" "$HD_SCHEMA" "$file" >/dev/null 2>&1 ;;
        config|status|worker|workspace|dispatcher|launch|lock) jq -se --arg type "$type" "$HD_SCHEMA" "$file" >/dev/null 2>&1 ;;
        *) return 2 ;;
    esac || return 2
}
hd_frontmatter() {
    jq -Rsr 'split("\n") as $l | ($l[1:] | index("---")) as $e | $l[1:($e+1)] | join("\n") | fromjson | tojson' "$1"
}
hd_config_load() {
    local selected parent base dir root role_path name key home
    HD_CONFIG_LINK_COUNT=0
    command -v jq >/dev/null || return 6
    selected=${HERDR_DISPATCHER_CONFIG:-$HOME/.config/herdr-dispatcher/config.json}
    case "$selected" in /*) ;; *) return 2 ;; esac
    [ -f "$selected" ] || return 2
    # Config entry may be a symlink. Resolve the complete link chain, not only its parent.
    while [ -L "$selected" ]; do
        root=$(readlink "$selected") || return 6
        case "$root" in /*) selected=$root ;; *) selected="$(dirname "$selected")/$root" ;; esac
        HD_CONFIG_LINK_COUNT=$((${HD_CONFIG_LINK_COUNT:-0}+1))
        [ "$HD_CONFIG_LINK_COUNT" -le 40 ] || return 2
    done
    parent=$(hd_directory "$(dirname "$selected")") || return $?
    base=$(basename "$selected")
    HD_CONFIG_PATH="$parent/$base"
    hd_json_validate config "$HD_CONFIG_PATH" || return 2
    HD_CONFIG_JSON=$(jq -c . "$HD_CONFIG_PATH") || return 6
    root=$(printf '%s\n' "$HD_CONFIG_JSON" | jq -r .repo_path)
    HD_REPO_PATH=$(hd_directory "$root") || return $?
    [ "$root" = "$HD_REPO_PATH" ] || return 2
    home=$(hd_directory "$HOME") || return $?
    while IFS= read -r root; do
        dir=$(hd_directory "$root") || return $?
        [ "$root" = "$dir" ] && [ "$dir" != / ] && [ "$dir" != "$home" ] || return 2
    done < <(printf '%s\n' "$HD_CONFIG_JSON" | jq -r '.trust_roots[]')
    # Unknown override roles are invalid. The initial two roles remain known before role files ship.
    while IFS= read -r key; do
        case "$key" in review|explore) continue ;; esac
        role_path="$HD_REPO_PATH/roles/$key.md"
        hd_safe_file "$role_path" && hd_json_validate role "$role_path" || return 2
        name=$(hd_frontmatter "$role_path" | jq -r .name) || return 2
        [ "$name" = "$key" ] || return 2
    done < <(printf '%s\n' "$HD_CONFIG_JSON" | jq -r '.worker_kinds | keys[]')
    HD_RUN_ROOT="$HD_REPO_PATH/runs"
    hd_no_links "$HD_RUN_ROOT" || return 2
    if [ -e "$HD_RUN_ROOT" ] && [ ! -d "$HD_RUN_ROOT" ]; then return 2; fi
    hd_private_init || return $?
}

hd_child_call() {
    local mode=${1:-} remaining duration child watchdog status marker
    case "$mode" in read|write) ;; *) return 2 ;; esac
    shift
    [ "${1:-}" = -- ] || return 2
    shift
    [ "$#" -gt 0 ] || return 2
    HD_CHILD_UNCERTAIN=false
    HD_CHILD_EXIT=4
    HD_CHILD_STDOUT=''
    HD_CHILD_STDERR=''
    remaining=$(hd_remaining_ms) || return 4
    hd_private_init || return $?
    HD_CHILD_STDOUT=$(mktemp "$HD_PRIVATE/stdout.XXXXXX") || return 6
    HD_CHILD_STDERR=$(mktemp "$HD_PRIVATE/stderr.XXXXXX") || return 6
    marker="$HD_CHILD_STDOUT.killed"
    printf -v duration '%d.%03d' "$((remaining / 1000))" "$((remaining % 1000))"
    "$@" > "$HD_CHILD_STDOUT" 2> "$HD_CHILD_STDERR" &
    child=$!
    HD_ACTIVE_CHILD=$child
    (
        # Canceling the watchdog must cancel/reap its own sleep child too.
        sleeper=''
        trap '[ -z "$sleeper" ] || { kill "$sleeper" 2>/dev/null || :; wait "$sleeper" 2>/dev/null || :; }; exit 0' TERM INT
        sleep "$duration" & sleeper=$!
        wait "$sleeper" || exit 0
        sleeper=''
        if kill -0 "$child" 2>/dev/null; then
            : > "$marker"
            kill -TERM "$child" 2>/dev/null || :
            sleep 0.1 & sleeper=$!
            wait "$sleeper" || :
            sleeper=''
            kill -KILL "$child" 2>/dev/null || :
        fi
    ) &
    watchdog=$!
    HD_ACTIVE_WATCHDOG=$watchdog
    status=0
    wait "$child" || status=$?
    HD_ACTIVE_CHILD=''
    kill -TERM "$watchdog" 2>/dev/null || :
    wait "$watchdog" 2>/dev/null || :
    HD_ACTIVE_WATCHDOG=''
    HD_CHILD_EXIT=$status
    if [ -f "$marker" ]; then
        HD_CHILD_EXIT=4
        if [ "$mode" = write ]; then HD_CHILD_UNCERTAIN=true; return 5; fi
        return 4
    fi
    if [ "$status" -ne 0 ]; then
        # Retain only a validated server error code, never its possibly private message.
        jq -ce '.error.code | select(type == "string" and test("^[a-z][a-z0-9_]*$"))' "$HD_CHILD_STDERR" > "$HD_PRIVATE/external-code.json" 2>/dev/null || :
        return 6
    fi
}
hd_cli_read() { hd_child_call read -- herdr "$@"; }
hd_live_metadata() {
    local target=$1
    hd_cli_read agent list || return $?
    jq -ce --arg target "$target" '.result | select(.type == "agent_list" and (.agents | type == "array")) | [.agents[] | select(.pane_id == $target or .name == $target)] | select(length == 1) | .[0]' "$HD_CHILD_STDOUT" 2>/dev/null || return 3
}
hd_metadata_identity() {
    jq -ce '{pane_id,terminal_id,kind:.agent,agent_session,foreground_process_group_id:1}'
}
hd_target_identity() {
    local target=$1 first second pane process group identity
    while :; do
        hd_remaining_ms >/dev/null || return 4
        first=$(hd_live_metadata "$target") || return $?
        identity=$(printf '%s\n' "$first" | hd_metadata_identity) || return 3
        hd_private_init || return $?
        printf '%s\n' "$identity" > "$HD_PRIVATE/target.json"
        hd_occupant_validate "$HD_PRIVATE/target.json" || return 3
        pane=$(printf '%s\n' "$identity" | jq -er '.pane_id | select(type == "string" and length > 0)') || return 3
        hd_cli_read pane process-info --pane "$pane" || return $?
        process=$(jq -ce --arg pane "$pane" '.result | select(.type == "pane_process_info") | .process_info | select(.pane_id == $pane and (.foreground_processes | type == "array" and length > 0) and (.foreground_process_group_id | type == "number" and floor == . and . > 0))' "$HD_CHILD_STDOUT") || return 3
        group=$(printf '%s\n' "$process" | jq -r .foreground_process_group_id)
        second=$(hd_live_metadata "$pane") || return $?
        second=$(printf '%s\n' "$second" | hd_metadata_identity) || return 3
        if printf '%s\n' "$identity" | jq -e --argjson second "$second" '. == $second' >/dev/null; then
            printf '%s\n' "$identity" | jq -c --argjson group "$group" '.foreground_process_group_id=$group'
            return 0
        fi
        hd_sleep || return 4
    done
}
hd_current_identity() {
    local pane first identity current second process group
    [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] || return 3
    hd_cli_read pane current --current || return $?
    current=$(jq -ce '.result | select(.type == "pane_current") | .pane' "$HD_CHILD_STDOUT") || return 3
    first=$(printf '%s\n' "$current" | hd_metadata_identity) || return 3
    pane=$(printf '%s\n' "$first" | jq -er '.pane_id | select(type == "string" and length > 0)') || return 3
    # Requery via the inventory; this adapter does not depend on undocumented agent-get shapes.
    while :; do
        hd_cli_read pane process-info --pane "$pane" || return $?
        process=$(jq -ce --arg pane "$pane" '.result | select(.type == "pane_process_info") | .process_info | select(.pane_id == $pane and (.foreground_processes | type == "array" and length > 0) and (.foreground_process_group_id | type == "number" and floor == . and . > 0))' "$HD_CHILD_STDOUT") || return 3
        group=$(printf '%s\n' "$process" | jq -r .foreground_process_group_id)
        hd_cli_read agent list || return $?
        second=$(jq -ce --arg pane "$pane" '.result | select(.type == "agent_list") | [.agents[] | select(.pane_id == $pane)] | select(length == 1) | .[0] | {pane_id,terminal_id,kind:.agent,agent_session,foreground_process_group_id:1}' "$HD_CHILD_STDOUT") || return 3
        if printf '%s\n' "$first" | jq -e --argjson second "$second" '. == $second' >/dev/null; then
            identity=$(printf '%s\n' "$first" | jq -c --argjson group "$group" '.foreground_process_group_id=$group') || return 6
            printf '%s\n' "$identity" > "$HD_PRIVATE/identity.json"
            # Occupant validation is exposed separately from stored top-level schemas.
            hd_occupant_validate "$HD_PRIVATE/identity.json" || return 3
            printf '%s\n' "$identity"
            return 0
        fi
        first=$second
        hd_sleep || return 4
    done
}
hd_occupant_validate() {
    jq -e 'type == "object" and keys == ["agent_session","foreground_process_group_id","kind","pane_id","terminal_id"] and (.pane_id | type == "string" and length > 0) and (.terminal_id | type == "string" and length > 0) and (.foreground_process_group_id | type == "number" and floor == . and . > 0) and (.agent_session | type == "object" and keys == ["agent","kind","source","value"] and (.value | type == "string" and length > 0)) and .kind == .agent_session.agent and (if .kind == "pi" then .agent_session.kind == "path" and .agent_session.source == "herdr:pi" and (.agent_session.value | startswith("/")) elif .kind == "claude" then .agent_session.kind == "id" and .agent_session.source == "herdr:claude" else false end) and ([.. | strings | contains("\u0000")] | any | not)' "$1" >/dev/null 2>&1
}
hd_identity_check() {
    local actual expected=$2
    actual=$(hd_target_identity "$1") || return $?
    printf '%s\n' "$actual" | jq -e --argjson expected "$expected" '. == $expected' >/dev/null || return 3
}

hd_process_start() { LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}'; }
# 0 means live; 1 conclusive death/mismatch; 3 ambiguous evidence.
hd_owner_state() {
    local path=$1 pid saved actual inventory snapshot
    # mkdir precedes atomic owner publication. Absence is transient, never reclaimable.
    if [ ! -e "$path/owner.json" ] && [ ! -L "$path/owner.json" ]; then return 4; fi
    # Snapshot through one open file before validating. The owner can release
    # its lock between separate path reads; that is not malformed metadata.
    hd_private_init || return 3
    snapshot="$HD_PRIVATE/owner-check.json"
    if ! hd_safe_file "$path/owner.json" || ! cp -- "$path/owner.json" "$snapshot" 2>/dev/null; then
        [ -e "$path/owner.json" ] || [ -L "$path/owner.json" ] || return 4
        return 3
    fi
    hd_json_validate lock "$snapshot" || return 3
    HD_OWNER_TOKEN=$(jq -r .token "$snapshot") || return 3
    pid=$(jq -r .pid "$snapshot")
    saved=$(jq -r .process_started_at "$snapshot")
    actual=$(hd_process_start "$pid")
    if [ -n "$actual" ]; then [ "$actual" = "$saved" ] && return 0; return 1; fi
    # A failed kill probe alone does not prove death. Require a successful process inventory.
    inventory=$(LC_ALL=C ps -e -o pid=) || return 3
    printf '%s\n' "$inventory" | awk -v pid="$pid" '$1 == pid {found=1} END {exit !found}' && return 3
    return 1
}
hd_publish_owner() {
    local path=$1 token=$2 started tmp
    started=$(hd_process_start "$$")
    [ -n "$started" ] || return 6
    tmp=$(mktemp "$path/.owner.XXXXXX") || return 6
    jq -n --argjson pid "$$" --arg started "$started" --arg token "$token" --arg at "$(hd_now)" '{schema_version:1,pid:$pid,process_started_at:$started,token:$token,created_at:$at}' > "$tmp" || return 6
    mv -- "$tmp" "$path/owner.json" || return 6
}
hd_lock_release() {
    local path=$1 token=$2
    hd_no_links "$path" || return 3
    hd_safe_file "$path/owner.json" && hd_json_validate lock "$path/owner.json" || return 3
    jq -e --arg token "$token" '.token == $token' "$path/owner.json" >/dev/null || return 3
    rm -- "$path/owner.json" || return 6
    rmdir -- "$path" || return 6
}
hd_lock_acquire() {
    local path=$1 token remaining started=$SECONDS state old guard guard_token guard_state
    hd_no_links "$path" || return 2
    case "$path" in "$HD_RUN_ROOT/.locks/state"|"$HD_RUN_ROOT/.locks/startup"|"$HD_RUN_ROOT/.locks/pane-"*) ;; *) return 2 ;; esac
    [ -d "$(dirname "$path")" ] || return 2
    guard="$HD_RUN_ROOT/.locks/reclaim"
    token=$(hd_random 16) || return 6
    while :; do
        remaining=$(hd_remaining_ms) || return 4
        hd_no_links "$guard" || return 3
        if [ -e "$guard" ]; then
            [ -d "$guard" ] || return 3
            guard_state=0; hd_owner_state "$guard" || guard_state=$?
            [ "$guard_state" -eq 0 ] || [ "$guard_state" -eq 4 ] || return 3
            hd_sleep || return 4
            continue
        fi
        if mkdir -- "$path" 2>/dev/null; then
            # All acquirers respect a reclaim guard before owner publication.
            if [ -e "$guard" ]; then rmdir -- "$path" || return 6; hd_sleep || return 4; continue; fi
            hd_publish_owner "$path" "$token" || return $?
            HD_LOCK_TOKEN=$token
            HD_LOCK_PATHS[${#HD_LOCK_PATHS[@]}]=$path
            HD_LOCK_TOKENS[${#HD_LOCK_TOKENS[@]}]=$token
            return 0
        fi
        # Try the atomic acquisition before rejecting a wait at the coarse
        # second boundary. A free lock does not add any lock-wait time.
        if [ "$path" = "$HD_RUN_ROOT/.locks/state" ] && [ "$SECONDS" -gt "$started" ]; then return 4; fi
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then continue; fi
        [ -d "$path" ] && [ ! -L "$path" ] || return 6
        state=0; hd_owner_state "$path" || state=$?
        [ "$state" -ne 3 ] || return 3
        if [ "$state" -eq 4 ]; then hd_sleep || return 4; continue; fi
        if [ "$state" -eq 1 ]; then
            # The token belongs to the validated snapshot. Its path can
            # disappear when that owner finishes its own release.
            old=$HD_OWNER_TOKEN
            guard_token=$(hd_random 16) || return 6
            if mkdir -- "$guard" 2>/dev/null; then
                hd_publish_owner "$guard" "$guard_token" || return 6
                HD_LOCK_PATHS[${#HD_LOCK_PATHS[@]}]=$guard
                HD_LOCK_TOKENS[${#HD_LOCK_TOKENS[@]}]=$guard_token
                state=0; hd_owner_state "$path" || state=$?
                if [ "$state" -eq 1 ] && [ "$HD_OWNER_TOKEN" = "$old" ]; then
                    if ! hd_lock_release "$path" "$old"; then
                        # Missing metadata can be an owner release, never a
                        # reason to remove the directory or its replacement.
                        if [ -e "$path/owner.json" ] || [ -L "$path/owner.json" ]; then
                            hd_lock_release "$guard" "$guard_token"; return 3
                        fi
                    fi
                fi
                hd_lock_release "$guard" "$guard_token" || return 3
                [ "$state" -ne 3 ] || return 3
            fi
        fi
        hd_sleep || return 4
    done
}
hd_atomic_replace() {
    local destination=$1 source=$2 parent base tmp type
    hd_no_links "$destination" || return 2
    hd_safe_file "$source" || return 2
    case "$destination" in
        "$HD_RUN_ROOT/"*/status) type=status ;;
        "$HD_RUN_ROOT/.workers/"*) type=worker ;;
        "$HD_RUN_ROOT/.launches/"*) type=launch ;;
        "$HD_RUN_ROOT/.dispatcher.json") type=dispatcher ;;
        "$HD_RUN_ROOT/.workspace.json") type=workspace ;;
        *) return 2 ;;
    esac
    hd_json_validate "$type" "$source" || return 2
    parent=$(hd_directory "$(dirname "$destination")") || return $?
    base=$(basename "$destination")
    [ "$destination" = "$parent/$base" ] || return 2
    [ ! -e "$destination" ] || [ -f "$destination" ] || return 2
    tmp=$(mktemp "$parent/.replace.XXXXXX") || return 6
    cp -- "$source" "$tmp" || return 6
    chmod 600 "$tmp" || return 6
    hd_no_links "$destination" || return 2
    mv -- "$tmp" "$destination" || return 6
}
hd_emit() {
    jq -cn --arg outcome "$1" --argjson result "$2" --argjson error "$3" '{schema_version:1,ok:($error == null),outcome:$outcome,result:$result,error:$error}'
}
