#!/bin/bash
# Internal setup API. Preview uses memory only; do not source lib.sh:
# its large schema here-document can use a temporary file on Bash 3.2.
# These validation chains intentionally stop if any condition fails.
# SC2016: source signatures contain literal JavaScript template expressions.
# shellcheck disable=SC2015,SC2016
if [ "${BASH_SOURCE[0]}" = "$0" ]; then exit 2; fi
hd_directory() { [ -d "$1" ] && (cd "$1" && pwd -P); }
hd_no_links() {
    local path=$1 current='' part
    case "$path" in /*) ;; *) return 2 ;; esac
    [ "$path" != / ] || return 0
    while [ -n "$path" ]; do
        path=${path#/}; part=${path%%/*}
        case "$part" in ''|.|..) return 2 ;; esac
        current="$current/$part"; [ ! -L "$current" ] || return 2
        [ "$path" != "$part" ] || break
        path=${path#*/}
    done
}
hd_safe_file() { hd_no_links "$1" && [ -f "$1" ] && [ ! -L "$1" ]; }
hd_frontmatter() {
    jq -Rser 'split("\n") as $l | if $l[0] != "---" then error("frontmatter") else ($l[1:] | index("---")) as $e | if $e == null then error("delimiter") else $l[1:($e+1)] | join("\n") | fromjson | tojson end end' "$1"
}
hd_json_validate() {
    local role
    [ "$1" = role ] && hd_safe_file "$2" || return 2
    role=$(hd_frontmatter "$2") || return 2
    printf '%s\n' "$role" | jq -e 'type == "object" and ((keys - ["schema_version","name","kind","capabilities","max_instances","idle_ttl_seconds"]) | length == 0) and .schema_version == 1 and (.name | type == "string" and test("^[a-z][a-z0-9_-]{0,23}$")) and (.kind == "pi" or .kind == "claude") and (.capabilities | type == "array" and length > 0 and length == (unique | length) and all(.[]; type == "string" and length > 0)) and (.max_instances | type == "number" and floor == . and . > 0 and . <= 2147483647) and (if has("idle_ttl_seconds") then .idle_ttl_seconds | type == "number" and floor == . and . >= 0 and . <= 2147483647 else true end)' >/dev/null 2>&1
}

setup_emit() {
    local status=$1 code=${2:-} message=${3:-} outcome=ok
    [ "$status" -eq 0 ] || outcome=not-submitted
    [ "$status" -ne 5 ] || outcome=uncertain
    jq -n --arg mode "$MODE" --arg path "$CONFIG_PATH" --argjson config "$CONFIG" \
        --argjson checks "$CHECKS" --argjson changes "$CHANGES" --argjson conflicts "$CONFLICTS" \
        --argjson blocked "$BLOCKED" --argjson backups "$BACKUPS" --arg outcome "$outcome" \
        --arg code "$code" --arg message "$message" --argjson ok "$([ "$status" -eq 0 ] && printf true || printf false)" \
        '{schema_version:1,ok:$ok,outcome:$outcome,result:{mode:$mode,config_path:$path,config:$config,checks:$checks,changes:$changes,conflicts:$conflicts,blocked_roots:$blocked,backups:$backups},error:(if $ok then null else {code:$code,message:$message,retryable:false} end)}'
    exit "$status"
}
setup_fail() { setup_emit "$1" "$2" "$3"; }
setup_python_check() {
    python3 -I -c '
import sys
sys.dont_write_bytecode = True
if sys.version_info < (3, 8):
    sys.exit(1)
import inspect
import os
import signal
try:
    assert os.O_NOFOLLOW and os.O_DIRECTORY
    assert callable(signal.pthread_sigmask)
    assert all(fn in os.supports_dir_fd for fn in (os.open, os.mkdir, os.stat, os.unlink, os.rmdir))
    assert os.stat in os.supports_follow_symlinks
    parameters = inspect.signature(os.replace).parameters
    assert "src_dir_fd" in parameters and "dst_dir_fd" in parameters
    # Empty names cannot modify files. Unsupported dirfd APIs fail before this
    # expected pathname error, even if their signature advertises the keywords.
    try:
        os.replace("", "", src_dir_fd=-1, dst_dir_fd=-1)
    except OSError:
        pass
    else:
        sys.exit(1)
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    signal.pthread_sigmask(signal.SIG_SETMASK, previous)
except (AttributeError, AssertionError, NotImplementedError, OSError, TypeError, ValueError):
    sys.exit(1)
' || setup_fail 6 unsupported_python 'Setup requires Python >=3.8 with safe directory-relative APIs and POSIX signal masks'
}
setup_check() {
    CHECKS=$(printf '%s\n' "$CHECKS" | jq -c --arg name "$1" --arg message "$2" '. + [{name:$name,ok:true,message:$message}]') || exit 6
}
setup_conflict() {
    CONFLICTS=$(printf '%s\n' "$CONFLICTS" | jq -c --arg path "$1" --arg reason "$2" '. + [{path:$path,reason:$reason}]') || exit 6
}
setup_change() {
    CHANGES=$(printf '%s\n' "$CHANGES" | jq -c --arg path "$1" --arg action "$2" --arg target "${3:-}" '. + [{path:$path,action:$action,target:(if $target == "" then null else $target end),applied:false}]') || exit 6
}
setup_applied() {
    CHANGES=$(printf '%s\n' "$CHANGES" | jq -c --arg path "$1" 'map(if .path == $path then .applied=true else . end)') || exit 6
}
# Canonicalize a selected config, including a missing suffix. No mkdir or temp file.
setup_path() {
    local path=$1 suffix='' base link count=0
    case "$path" in /*) ;; *) return 2 ;; esac
    case "$path" in *$'\n'*|*'/../'*|*'/./'*|*/..|*/.|*'//'*) return 2 ;; esac
    while [ -L "$path" ]; do
        count=$((count+1)); [ "$count" -le 40 ] || return 2
        link=$(readlink "$path") || return 6
        case "$link" in /*) path=$link ;; *) path="$(dirname "$path")/$link" ;; esac
    done
    while [ ! -e "$path" ]; do
        base=${path##*/}; case "$base" in ''|.|..) return 2 ;; esac
        suffix="/$base$suffix"; path=${path%/*}; [ -n "$path" ] || path=/
        [ ! -L "$path" ] || [ -e "$path" ] || return 2
    done
    if [ -d "$path" ]; then path=$(cd "$path" && pwd -P) || return 6
    else
        [ -f "$path" ] || return 2
        path="$(cd "$(dirname "$path")" && pwd -P)/${path##*/}" || return 6
    fi
    printf '%s%s\n' "$path" "$suffix"
}
# Verify future private parents without changing existing directory permissions.
setup_parent_check() {
    local path=$1 parent
    hd_no_links "$path" || return 2
    parent=$(dirname "$path")
    while [ ! -e "$parent" ]; do parent=$(dirname "$parent"); done
    [ -d "$parent" ] && [ -w "$parent" ] && [ -x "$parent" ] || return 6
    if [ -e "$path" ]; then [ -f "$path" ] && [ -r "$path" ] && [ -w "$path" ] || return 6; fi
}
setup_parent_plan() {
    local dir=$1 planned
    [ ! -d "$dir" ] || return 0
    setup_parent_plan "$(dirname "$dir")" || return $?
    planned=$(printf '%s\n' "$CHANGES" | jq -r --arg path "$dir" 'any(.[]; .path == $path)') || return 6
    [ "$planned" = true ] || setup_change "$dir" mkdir
}
setup_mkdir() {
    local dir=$1
    hd_no_links "$dir" || return 2
    if [ -e "$dir" ]; then [ -d "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ]; return $?; fi
    setup_mkdir "$(dirname "$dir")" || return $?
    setup_bash_mutation mkdir "$dir"
}
# Keep the parent trap deferred through the mutation and its completion record.
# A child may complete its syscall and then exit on a signal before reporting it.
setup_bash_mutation() {
    local kind=$1 path=$2 target=${3:-} status=0 completed=false
    SETUP_WRITING=true
    case "$kind" in
        mkdir) mkdir -m 700 "$path" || status=$? ;;
        symlink) ln -sn "$target" "$path" || status=$? ;;
    esac
    if hd_no_links "$(dirname "$path")"; then
        case "$kind" in
            mkdir) [ ! -L "$path" ] && [ -d "$path" ] && completed=true ;;
            symlink) [ -L "$path" ] && [ "$(readlink "$path")" = "$target" ] && completed=true ;;
        esac
    fi
    if [ "$completed" = true ]; then setup_applied "$path"; fi
    # Shared with setup_interrupt in the sourced trust module.
    # shellcheck disable=SC2034
    SETUP_WRITING=false
    [ "$SETUP_INTERRUPTED" = false ] || setup_fail 5 interrupted 'Setup interrupted; inspect reported changes and retained evidence'
    [ "$status" -eq 0 ] && [ "$completed" = true ] ||
        setup_fail 5 mutation_uncertain 'Mutation completion is uncertain; inspect reported changes and destination'
}
setup_link_plan() {
    local path=$1 target=$2
    hd_no_links "$(dirname "$path")" || { setup_conflict "$path" 'Symlinked parent'; return; }
    if [ -L "$path" ]; then
        [ "$(readlink "$path")" = "$target" ] || setup_conflict "$path" 'Existing link has another target'
    elif [ -e "$path" ]; then setup_conflict "$path" 'Existing path is not the requested link'
    else
        setup_parent_check "$path" || setup_fail 6 unsafe_parent 'Link parent is unsafe or not writable'
        setup_parent_plan "$(dirname "$path")" || setup_fail 6 parent_plan_failed 'Cannot plan private link parents'
        setup_change "$path" symlink "$target"
    fi
}
setup_config_validate() {
    local repo root physical key role metadata name kind protected
    printf '%s\n' "$CONFIG" | jq -se '
      def uint: type == "number" and floor == . and . >= 0;
      def kind: . == "pi" or . == "claude";
      def path: type == "string" and startswith("/") and (split("/")[1:] | all(. != "" and . != "." and . != "..")) and (contains("\n") | not);
      length == 1 and (.[0] | type == "object" and (keys - ["claude_model"]) == (["schema_version","repo_path","dispatcher_kind","worker_kinds","idle_ttl_seconds","ring_timeout_ms","startup_timeout_ms","trust_roots"] | sort) and ([.. | strings | contains("\u0000")] | any | not) and .schema_version == 1 and (.repo_path | path) and (.dispatcher_kind | kind) and (.worker_kinds | type == "object" and all(keys[]; test("^[a-z][a-z0-9_-]{0,23}$")) and all(.[]; kind)) and (.idle_ttl_seconds | uint and . <= 2147483647) and (.ring_timeout_ms | uint and . >= 1 and . <= 300000) and (.startup_timeout_ms | uint and . >= 1 and . <= 300000) and (.trust_roots | type == "array" and length == (unique | length) and all(.[]; path)) and (if has("claude_model") then .claude_model | type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z") else true end))' >/dev/null 2>&1 || setup_fail 2 invalid_config 'Config does not match the complete schema'
    repo=$(printf '%s\n' "$CONFIG" | jq -r .repo_path)
    physical=$(hd_directory "$repo") || setup_fail 2 invalid_repo 'Configured checkout does not exist'
    [ "$repo" = "$physical" ] && [ -f "$repo/AGENTS.md" ] && [ -d "$repo/roles" ] && [ -f "$repo/skills/ask-dispatcher/SKILL.md" ] || setup_fail 2 invalid_repo 'Config requires a canonical dispatcher checkout'
    while IFS= read -r key; do
        role="$repo/roles/$key.md"
        hd_json_validate role "$role" && [ "$(hd_frontmatter "$role" | jq -r .name)" = "$key" ] || setup_fail 2 invalid_role 'Unknown or invalid worker role'
    done < <(printf '%s\n' "$CONFIG" | jq -r '.worker_kinds | keys[]')
    ROLE_KINDS='[]'
    for role in "$repo/roles/"*.md; do
        hd_json_validate role "$role" || setup_fail 2 invalid_role 'Invalid role metadata'
        metadata=$(hd_frontmatter "$role") || setup_fail 2 invalid_role 'Cannot read role metadata'
        name=$(printf '%s\n' "$metadata" | jq -r .name)
        [ "${role##*/}" = "$name.md" ] || setup_fail 2 invalid_role 'Role name does not match its file'
        kind=$(printf '%s\n' "$CONFIG" | jq -r --arg name "$name" --argjson role "$metadata" '.worker_kinds[$name] // $role.kind') || setup_fail 6 json_error 'Cannot select effective role kind'
        ROLE_KINDS=$(printf '%s\n' "$ROLE_KINDS" | jq -c --arg kind "$kind" '. + [$kind] | unique') || setup_fail 6 json_error 'Cannot collect effective role kinds'
    done
    while IFS= read -r root; do
        physical=$(hd_directory "$root") || setup_fail 2 invalid_root 'Trust root does not exist'
        [ "$physical" = "$root" ] && [ "$root" != / ] || setup_fail 2 invalid_root 'Trust root is not an allowed canonical directory'
        # Reject broad ancestors too. Resolve protected paths so a symlink cannot
        # move the protected test tree outside the lexical HOME path.
        for protected in "$SETUP_HOME" "$SETUP_HOME/Documents" "$SETUP_HOME/Documents/test"; do
            protected=$(setup_path "$protected") || setup_fail 2 invalid_root 'Cannot resolve protected trust path'
            case "$protected/" in "$physical/"*) setup_fail 2 invalid_root 'Trust root contains a protected home, Documents, or test tree' ;; esac
        done
    done < <(printf '%s\n' "$CONFIG" | jq -r '.trust_roots[]')
}
# Resolve executable symlinks without executing the agent (even --version can write).
setup_executable_path() {
    local p=$1 link count=0
    while [ -L "$p" ]; do
        count=$((count+1)); [ "$count" -le 40 ] || return 2
        link=$(readlink "$p") || return 6
        case "$link" in /*) p=$link ;; *) p="$(dirname "$p")/$link" ;; esac
    done
    [ -f "$p" ] && [ -x "$p" ] || return 2
    printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd -P)" "${p##*/}"
}
setup_pi_adapter() {
    local launcher version modules package manager lock
    launcher=$(setup_executable_path "$(command -v pi)") || setup_fail 3 unsupported_pi 'Cannot resolve pi launcher'
    [ "$launcher" = "$SETUP_HOME/.pi/agent/bin/pi" ] || setup_fail 3 unsupported_pi 'Only the HOME managed pi launcher is supported'
    grep -q 'install/current-version' "$launcher" && grep -q 'install/releases/' "$launcher" || setup_fail 3 unsupported_pi 'Unsupported pi launcher layout'
    IFS= read -r version < "$SETUP_HOME/.pi/agent/install/current-version" || setup_fail 3 unsupported_pi 'Missing managed version selector'
    case "$version" in 1.2.0|1.3.0) ;; *) setup_fail 3 unsupported_pi 'Only verified pi 1.2.0 and 1.3.0 trust adapters are supported' ;; esac
    modules="$SETUP_HOME/.pi/agent/install/releases/$version/node_modules"
    package="$modules/@earendil-works/pi-coding-agent"
    jq -e --arg version "$version" '.name == "@earendil-works/pi-coding-agent" and .version == $version' "$package/package.json" >/dev/null 2>&1 || setup_fail 3 unsupported_pi 'Managed package metadata does not match its version selector'
    manager="$package/dist/core/trust-manager.js"; lock="$modules/proper-lockfile"
    jq -e '.version == "4.1.2"' "$lock/package.json" >/dev/null 2>&1 || setup_fail 3 unsupported_pi 'Unsupported proper-lockfile version'
    grep -Fq 'lockfile.lockSync(trustDir, { realpath: false, lockfilePath: `${path}.lock` })' "$manager" &&
        grep -q 'stale: 10000' "$lock/lib/lockfile.js" &&
        grep -q 'options.stale / 2' "$lock/lib/lockfile.js" &&
        grep -q 'findNearestTrustEntry' "$manager" || setup_fail 3 unsupported_pi 'Native trust locking source changed'
    [ -r "$package/docs/skills.md" ] && [ -r "$package/docs/configuration.md" ] &&
        grep -q 'trust.json' "$package/docs/security.md" || setup_fail 3 unsupported_pi 'Installed trust documentation is missing or unsupported'
    setup_check pi_trust_adapter "Managed pi $version; proper-lockfile 4.1.2; stale 10000ms; update 5000ms"
}
setup_dependencies() {
    local status integrations kind kinds
    command -v herdr >/dev/null || setup_fail 6 missing_executable 'herdr is missing'
    status=$(herdr status) || setup_fail 6 herdr_status 'herdr status failed'
    printf '%s\n' "$status" | awk '
        /^[[:space:]]*client:[[:space:]]*$/ { section="client"; next }
        /^[[:space:]]*server:[[:space:]]*$/ { section="server"; next }
        /^[[:space:]]*version:/ {
            if (section == "client") client=$2
            else if (section == "server") server=$2
            else legacy=$2
        }
        /^[[:space:]]*protocol:/ && section == "client" { protocol=$2 }
        /^[[:space:]]*endpoint_compatible:/ { endpoint=$2 }
        /^[[:space:]]*private_protocol_compatible:/ { private=$2 }
        END {
            pair=(client == "0.9.3" && server == "0.9.3") ||
                 (client == "0.9.5" && server == "0.9.5")
            legacy_v093=(client == "" && server == "" && legacy == "0.9.3")
            protocol_ok=(protocol == "" || protocol == "22")
            exit !((pair || legacy_v093) && protocol_ok && endpoint == "yes" && private == "yes")
        }' || setup_fail 3 unsupported_herdr 'A verified Herdr 0.9.3 or 0.9.5 client/server pair is required'
    integrations=$(herdr integration status) || setup_fail 6 reporter_status 'Cannot inspect reporters'
    kinds=$(printf '%s\n' "$CONFIG" | jq -r --argjson roles "$ROLE_KINDS" '[.dispatcher_kind, .worker_kinds[], $roles[]] | unique[]')
    case "$TRUST" in
        pi) kinds="$kinds"$'\npi' ;;
        claude) kinds="$kinds"$'\nclaude' ;;
        both) kinds="$kinds"$'\npi\nclaude' ;;
    esac
    kinds=$(printf '%s\n' "$kinds" | LC_ALL=C sort -u)
    while IFS= read -r kind; do
        command -v "$kind" >/dev/null || setup_fail 6 missing_executable "Required $kind executable is missing"
        printf '%s\n' "$integrations" | grep -Eq "^$kind: current \\(v[0-9]+\\)" || setup_fail 3 reporter_not_current "Required $kind reporter is not current"
        setup_check "${kind}_reporter" 'Executable available and reporter current'
    done < <(printf '%s\n' "$kinds")
    setup_check herdr 'Verified Herdr 0.9.3 or 0.9.5 client/server pair is available'
}
