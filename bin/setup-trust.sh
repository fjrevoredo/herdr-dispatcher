#!/bin/bash
# Internal trust adapters. Only setup --apply calls the writers.
# Validation chains intentionally stop if any condition fails.
# shellcheck disable=SC2015
if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 2; fi

TRUST_PATHS=()
TRUST_JSON=()
TRUST_ORIGINALS=()
TRUST_PRESENT=()
SETUP_WRITING=false
SETUP_INTERRUPTED=false

setup_interrupt() {
    # A writer must return its durable evidence before the parent reports a signal.
    if [ "$SETUP_WRITING" = true ]; then SETUP_INTERRUPTED=true
    else setup_fail 5 interrupted 'Setup interrupted; inspect reported changes and retained evidence'; fi
}

setup_blocked() {
    BLOCKED=$(printf '%s\n' "$BLOCKED" | jq -c --arg path "$1" --arg reason "$2" '. + [{path:$path,reason:$reason}]') || exit 6
}
setup_trust_plan() {
    local kind=$1 path=$2 original='{}' proposed root denied denied_path exists=false
    setup_parent_check "$path" || setup_fail 6 unsafe_trust_path 'Trust store or expected parent is unsafe or not writable'
    if [ "$kind" = pi ]; then
        [ -d "$SETUP_HOME/.pi/agent" ] && hd_no_links "$SETUP_HOME/.pi/agent" || setup_fail 3 unsafe_trust_parent 'Expected pi agent directory is missing or unsafe'
        if [ -e "$path.lock" ] || [ -L "$path.lock" ]; then setup_conflict "$path.lock" 'Native pi trust lock exists; never reclaimed'; fi
    else
        [ "$(dirname "$path")" = "$SETUP_HOME" ] || setup_fail 3 unsafe_trust_parent 'Unexpected Claude store parent'
        # Inspect the installed native executable, never run its CLI.
        grep -aq 'hasTrustDialogAccepted' "$(command -v claude)" || setup_fail 3 unsupported_claude 'Installed Claude trust schema cannot be verified'
    fi
    if [ -e "$path" ]; then
        exists=true
        original=$(jq -cse 'if length == 1 and (.[0] | type == "object") and ([.. | strings | contains("\u0000")] | any | not) and ([.. | objects | keys[] | contains("\u0000")] | any | not) then .[0] else error("invalid store") end' "$path") || setup_fail 2 invalid_trust_json 'Trust store is not a single JSON object'
    fi
    if [ "$kind" = pi ]; then
        printf '%s\n' "$original" | jq -e 'all(to_entries[]; (.key | startswith("/")) and (.value == true or .value == false or .value == null))' >/dev/null || setup_fail 2 invalid_trust_json 'Invalid pi trust decisions'
    else
        printf '%s\n' "$original" | jq -e '(.projects == null or (.projects | type == "object")) and ((.projects // {}) | all(.[]; type == "object" and (has("hasTrustDialogAccepted") | not) or (type == "object" and (.hasTrustDialogAccepted | type == "boolean"))))' >/dev/null || setup_fail 2 invalid_trust_json 'Invalid Claude project trust decisions'
    fi
    proposed=$original
    while IFS= read -r root; do
        if [ "$kind" = pi ]; then
            denied=$(printf '%s\n' "$original" | jq -r --arg root "$root" 'to_entries[] | select(.value == false and (.key == $root or (.key | startswith($root + "/")))) | .key')
        else
            denied=$(printf '%s\n' "$original" | jq -r --arg root "$root" '(.projects // {}) | to_entries[] | select(.value.hasTrustDialogAccepted == false and (.key == $root or (.key | startswith($root + "/")))) | .key')
        fi
        while IFS= read -r denied_path; do
            [ -n "$denied_path" ] || continue
            setup_blocked "$denied_path" "Saved $kind denial is preserved"
            [ "$denied_path" != "$root" ] || setup_conflict "$root" "Explicit $kind denial cannot be replaced"
        done < <(printf '%s\n' "$denied")
        if [ "$kind" = pi ]; then
            proposed=$(printf '%s\n' "$proposed" | jq -c --arg root "$root" 'if .[$root] == false then . else .[$root]=true end') || setup_fail 6 json_error 'Cannot prepare pi trust'
        else
            proposed=$(printf '%s\n' "$proposed" | jq -c --arg root "$root" 'if .projects[$root].hasTrustDialogAccepted == false then . else .projects[$root].hasTrustDialogAccepted=true end') || setup_fail 6 json_error 'Cannot prepare Claude trust'
        fi
    done < <(printf '%s\n' "$CONFIG" | jq -r '.trust_roots[]')
    setup_check "${kind}_trust_roots" "$(printf '%s\n' "$CONFIG" | jq -c .trust_roots)"
    if [ "$original" != "$proposed" ]; then
        TRUST_PATHS[${#TRUST_PATHS[@]}]=$path
        TRUST_JSON[${#TRUST_JSON[@]}]=$proposed
        TRUST_ORIGINALS[${#TRUST_ORIGINALS[@]}]=$original
        TRUST_PRESENT[${#TRUST_PRESENT[@]}]=$exists
        setup_change "$path" trust
    fi
}
# JSON contents travel only on stdin, never in the Python process argument list.
setup_write_file() {
    local path=$1 json=$2 expected=$3 present=$4 native=$5 response status=0 applied
    if [ "$native" = true ]; then setup_pi_adapter; fi
    if [ "$path" = "$SETUP_HOME/.claude.json" ]; then
        [ "$QUIET" = true ] && grep -aq 'hasTrustDialogAccepted' "$(command -v claude)" || setup_fail 3 unsupported_claude 'Claude writers or installed schema are not verified'
    fi
    # Config creation has no previous JSON value. Trust creation uses {}.
    [ -n "$expected" ] || expected=null
    SETUP_WRITING=true
    response=$(printf '%s\n%s\n' "$json" "$expected" | jq -cs --arg path "$path" \
        --argjson present "$present" --argjson native "$native" \
        '{mode:"apply",path:$path,proposed:.[0],expected:.[1],present:$present,native:$native}' |
        python3 -I "$SETUP_FILES_HELPER") || status=$?
    case "$status" in 0|3|5|6) ;; *) setup_fail 5 writer_uncertain 'File writer did not return a known exit status; inspect destinations' ;; esac
    printf '%s\n' "$response" | jq -e --argjson status "$status" '
        type == "object" and (.ok == ($status == 0)) and
        (.result.backups | type == "array" and all(.[]; (.path | type == "string") and (.backup_path | type == "string"))) and
        (.result.applied_paths | type == "array" and all(.[]; type == "string")) and
        (.result.retained_paths | type == "array" and all(.[]; type == "string")) and
        (if $status == 0 then .error == null else (.error.code | type == "string") and (.error.message | type == "string") end)' >/dev/null ||
        setup_fail 5 writer_uncertain 'File writer response is invalid; inspect destinations and backups'
    BACKUPS=$(jq -nc --argjson existing "$BACKUPS" --argjson response "$response" '$existing + $response.result.backups') ||
        setup_fail 5 writer_uncertain 'Cannot record file writer backups'
    while IFS= read -r applied; do
        setup_applied "$applied"
    done < <(printf '%s\n' "$response" | jq -r '.result.applied_paths[]')
    if [ "$(printf '%s\n' "$response" | jq '.result.retained_paths | length')" -gt 0 ]; then
        setup_check file_writer_evidence "$(printf '%s\n' "$response" | jq -c .result.retained_paths)"
    fi
    SETUP_WRITING=false
    [ "$SETUP_INTERRUPTED" = false ] || setup_fail 5 interrupted 'Setup interrupted; inspect reported changes and retained evidence'
    [ "$status" -eq 0 ] || setup_fail "$status" "$(printf '%s\n' "$response" | jq -r .error.code)" "$(printf '%s\n' "$response" | jq -r .error.message)"
}
