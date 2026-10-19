#!/bin/bash
# Offline setup tests. Never invoke an installed agent or write outside sandbox.
setup_pi_release() {
    local version=$1 modules package
    modules="$HOME/.pi/agent/install/releases/$version/node_modules"
    package="$modules/@earendil-works/pi-coding-agent"
    mkdir -p "$package/dist/core" "$package/docs" "$modules/proper-lockfile/lib"
    printf '%s\n' "$version" > "$HOME/.pi/agent/install/current-version"
    printf '{"name":"@earendil-works/pi-coding-agent","version":"%s"}\n' "$version" > "$package/package.json"
    # The adapter compares a literal JavaScript template expression.
    # shellcheck disable=SC2016
    printf '%s\n' 'lockfile.lockSync(trustDir, { realpath: false, lockfilePath: `${path}.lock` })' 'findNearestTrustEntry' > "$package/dist/core/trust-manager.js"
    printf '{"version":"4.1.2"}\n' > "$modules/proper-lockfile/package.json"
    printf '%s\n' 'stale: 10000' 'options.stale / 2' > "$modules/proper-lockfile/lib/lockfile.js"
    : > "$package/docs/skills.md"
    : > "$package/docs/configuration.md"
    printf 'trust.json\n' > "$package/docs/security.md"
}

setup_fixture() {
    unset PI_CODING_AGENT_DIR PI_PACKAGE_DIR CLAUDE_CONFIG_DIR
    mkdir -p "$TEST_ROOT/repo/bin" "$TEST_ROOT/repo/roles" "$TEST_ROOT/repo/skills"
    cp "$TEST_REPO/bin/setup" "$TEST_REPO/bin/setup-lib.sh" "$TEST_REPO/bin/setup-trust.sh" "$TEST_ROOT/repo/bin/"
    cp -R "$TEST_REPO/lib" "$TEST_ROOT/repo/"
    cp "$TEST_REPO/AGENTS.md" "$TEST_ROOT/repo/AGENTS.md"
    cp "$TEST_REPO/roles/"*.md "$TEST_ROOT/repo/roles/"
    cp -R "$TEST_REPO/skills/ask-dispatcher" "$TEST_ROOT/repo/skills/"
    mkdir -p "$HOME/Documents/smec-dev" "$HOME/Documents/private" "$HOME/.pi/agent/bin"
    # The adapter checks the installed filesystem; agent execution is a test error.
    cat > "$HOME/.pi/agent/bin/pi" <<'AGENT'
#!/bin/bash
# install/current-version install/releases/
printf 'ERROR: fake pi was invoked\n' >&2
: > "$TEST_ROOT/agent-invoked"
exit 97
AGENT
    cat > "$HOME/.pi/agent/bin/claude" <<'AGENT'
#!/bin/bash
# hasTrustDialogAccepted
printf 'ERROR: fake claude was invoked\n' >&2
: > "$TEST_ROOT/agent-invoked"
exit 97
AGENT
    chmod 700 "$HOME/.pi/agent/bin/pi" "$HOME/.pi/agent/bin/claude"
    export PATH="$HOME/.pi/agent/bin:$PATH"
    setup_pi_release 1.2.0
    # Preserve the complete input outside HOME/repo/tmp snapshots.
    jq --arg work "$HOME/Documents/smec-dev" --arg private "$HOME/Documents/private" '.trust_roots=[$work,$private]' "$HERDR_DISPATCHER_CONFIG" > "$TEST_ROOT/setup-input.json"
    # The default config does not exist yet; no real config is ever selected.
    export HERDR_DISPATCHER_CONFIG="$HOME/.config/herdr-dispatcher/config.json"
    setup_read_rules 'pi: current (v1)
claude: current (v1)'
}

setup_read_rules() {
    local integrations=$1 client_version=${2:-0.9.3} server_version=${3:-${2:-0.9.3}} protocol=${4:-22} status
    status=$(printf 'client:\n  version: %s\n  protocol: %s\nserver:\n  version: %s\n  endpoint_compatible: yes\n  private_protocol_compatible: yes' "$client_version" "$protocol" "$server_version")
    jq -n --arg integrations "$integrations" --arg status "$status" '[
        {persistent:true,argv:["status"],status:0,stdout:$status,stderr:null},
        {persistent:true,argv:["integration","status"],status:0,stdout:$integrations,stderr:null}
    ]' > "$FAKE_HERDR_SCENARIO"
}

herdr_093_legacy_status_supported() {
    setup_fixture
    jq -n --arg integrations 'pi: current (v1)' '[
        {persistent:true,argv:["status"],status:0,stdout:"version: 0.9.3\nendpoint_compatible: yes\nprivate_protocol_compatible: yes",stderr:null},
        {persistent:true,argv:["integration","status"],status:0,stdout:$integrations,stderr:null}
    ]' > "$FAKE_HERDR_SCENARIO"
    setup_call --dry-run --trust none
    expect_status 0
}

herdr_095_pair_supported() {
    setup_fixture
    setup_read_rules 'pi: current (v9)' 0.9.5 0.9.5
    setup_call --dry-run --trust none
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.checks | any(.name == "herdr" and .ok == true)'
}

herdr_mixed_pair_refused() {
    setup_fixture
    setup_read_rules 'pi: current (v9)' 0.9.5 0.9.3
    setup_call --dry-run --trust none
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "unsupported_herdr"'
}

herdr_unknown_version_refused() {
    setup_fixture
    setup_read_rules 'pi: current (v9)' 0.9.4 0.9.4
    setup_call --dry-run --trust none
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "unsupported_herdr"'
}

herdr_wrong_protocol_refused() {
    setup_fixture
    setup_read_rules 'pi: current (v9)' 0.9.5 0.9.5 21
    setup_call --dry-run --trust none
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "unsupported_herdr"'
}

pi_13_trust_adapter_supported() {
    setup_fixture
    setup_pi_release 1.3.0
    setup_call --dry-run --trust pi
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.checks | any(.name == "pi_trust_adapter" and .ok == true)'
    [ ! -e "$HOME/.pi/agent/trust.json" ] || fail 'Pi trust preview wrote the trust store'
}

pi_unknown_trust_adapter_refused() {
    setup_fixture
    setup_pi_release 1.4.0
    setup_call --dry-run --trust pi
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "unsupported_pi"'
    [ ! -e "$HOME/.pi/agent/trust.json" ] || fail 'unsupported Pi version wrote the trust store'
}

setup_call() {
    # Consumed by expect_status in helpers.sh.
    HELPER_STATUS=0
    # shellcheck disable=SC2034
    "$TEST_ROOT/repo/bin/setup" "$@" > "$TEST_ROOT/helper.json" 2> "$TEST_ROOT/helper.err" || HELPER_STATUS=$?
    assert_envelope "$TEST_ROOT/helper.json"
    [ ! -e "$TEST_ROOT/agent-invoked" ] || fail 'setup executed an agent'
    jq -se 'all(.[]; .argv == ["status"] or .argv == ["integration","status"])' "$FAKE_HERDR_LOG" >/dev/null || fail 'setup used a mutating CLI endpoint'
}

setup_snapshot() {
    /usr/bin/python3 "$TEST_REPO/tests/fixtures/setup-snapshot.py" "$HOME" "$TEST_ROOT/repo" "$TEST_ROOT/tmp"
}

setup_claude_model_preserved() {
    setup_fixture
    jq '.claude_model="claude-haiku-5-5"' "$TEST_ROOT/setup-input.json" > "$TEST_ROOT/model-input.json"
    setup_call --apply --config-input "$TEST_ROOT/model-input.json" --trust none
    expect_status 0
    assert_json "$HERDR_DISPATCHER_CONFIG" '.claude_model == "claude-haiku-5-5"'
    setup_call --dry-run --trust none
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.config.claude_model == "claude-haiku-5-5" and (.result.changes | length == 0)'
}
setup_invalid_claude_model() {
    setup_fixture
    local value
    while IFS= read -r value; do
        jq --argjson value "$value" '.claude_model=$value' "$TEST_ROOT/setup-input.json" > "$TEST_ROOT/model-input.json"
        setup_call --apply --config-input "$TEST_ROOT/model-input.json" --trust none
        expect_status 2
        [ ! -e "$HERDR_DISPATCHER_CONFIG" ] || fail 'invalid model wrote config'
    done < <(jq -cn '[null,"",true,[],{},"--bad","two words","x;touch /tmp/bad","line\nbreak","trailing\n",("x" * 129)][]')
}
preview_has_no_writes() {
    setup_fixture
    # Missing config is allowed only for setup's exact read-only endpoints.
    local status=0
    herdr agent list > "$TEST_ROOT/refused.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --dry-run --trust both
    expect_status 0
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
    assert_json "$TEST_ROOT/helper.json" '.result.changes | length > 0 and all(.[]; .applied == false)'
    [ ! -e "$HERDR_DISPATCHER_CONFIG" ]
}

apply_is_idempotent() {
    setup_fixture
    setup_call --apply --trust both --claude-writers-stopped
    expect_status 0
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --apply --trust both --claude-writers-stopped
    expect_status 0
    assert_json "$TEST_ROOT/helper.json" '.result.changes == [] and .result.backups == []'
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
    assert_equal "$TEST_ROOT/repo/skills/ask-dispatcher" "$(readlink "$HOME/.agents/skills/ask-dispatcher")"
    assert_equal "$HOME/.agents/skills/ask-dispatcher" "$(readlink "$HOME/.claude/skills/ask-dispatcher")"
    [ ! -e "$HOME/.pi/agent/skills/ask-dispatcher" ]
}

config_override_resolved() {
    setup_fixture
    mkdir "$HOME/alternate"
    ln -s "$HOME/alternate" "$HOME/config-alias"
    export HERDR_DISPATCHER_CONFIG="$HOME/config-alias/nested/dispatcher.json"
    setup_call --apply --config-input "$TEST_ROOT/setup-input.json"
    expect_status 0
    assert_equal "$HOME/alternate/nested/dispatcher.json" "$(jq -r .result.config_path "$TEST_ROOT/helper.json")"
    [ -f "$HOME/alternate/nested/dispatcher.json" ]
    [ ! -e "$HOME/.config/herdr-dispatcher/config.json" ]
}

conflicting_link_refused() {
    setup_fixture
    mkdir -p "$HOME/.agents/skills" "$HOME/other-skill"
    ln -s "$HOME/other-skill" "$HOME/.agents/skills/ask-dispatcher"
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --apply
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "setup_conflict" and (.result.conflicts | length > 0)'
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
}

invalid_trust_json_preserved() {
    setup_fixture
    local kind path
    for kind in pi claude; do
        if [ "$kind" = pi ]; then path="$HOME/.pi/agent/trust.json"; else path="$HOME/.claude.json"; fi
        printf '{ invalid JSON\n' > "$path"
        cp "$path" "$TEST_ROOT/invalid-original"
        setup_call --apply --trust "$kind" --claude-writers-stopped
        expect_status 2
        assert_json "$TEST_ROOT/helper.json" '.error.code == "invalid_trust_json"'
        cmp "$path" "$TEST_ROOT/invalid-original"
        [ ! -e "$HERDR_DISPATCHER_CONFIG" ]
    done
}

unrelated_trust_keys_preserved() {
    setup_fixture
    printf '{"/unrelated":false,"/nullable":null,"/allowed":true}\n' > "$HOME/.pi/agent/trust.json"
    printf '{"unrelated":{"keep":[1,"value"]},"projects":{"/unrelated":{"hasTrustDialogAccepted":false,"extra":42}}}\n' > "$HOME/.claude.json"
    chmod 640 "$HOME/.claude.json" "$HOME/.pi/agent/trust.json"
    setup_call --apply --trust both --claude-writers-stopped
    expect_status 0
    assert_json "$HOME/.pi/agent/trust.json" '.["/unrelated"] == false and .["/nullable"] == null and .["/allowed"] == true'
    assert_json "$HOME/.claude.json" '.unrelated.keep == [1,"value"] and .projects["/unrelated"] == {hasTrustDialogAccepted:false,extra:42}'
    local path
    for path in "$HOME/.claude.json" "$HOME/.pi/agent/trust.json"; do
        assert_equal 640 "$(/usr/bin/python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$path")"
    done
    assert_json "$TEST_ROOT/helper.json" '.result.backups | length == 2'
    local backup
    while IFS= read -r backup; do [ -f "$backup" ]; done < <(jq -r '.result.backups[].backup_path' "$TEST_ROOT/helper.json")
}

concurrent_trust_edit_refused() {
    setup_fixture
    printf '{"projects":{},"original":true}\n' > "$HOME/.claude.json"
    # First cover the real writer's final source check with syscall injection.
    setup_file_case test_concurrent_edit_before_rename
    mkdir "$TEST_ROOT/wrappers"
    # Also cover shell-to-helper validation: change the store after shell preview,
    # before the real Python helper reads it. No production injection hook is used.
    cat > "$TEST_ROOT/wrappers/python3" <<'WRAPPER'
#!/bin/bash
set -euo pipefail
if [ "$#" -eq 2 ] && [ "$1" = -I ] && [[ "$2" = */lib/setup-files.py ]]; then
    request=$(/usr/bin/python3 -c 'import sys; print(sys.stdin.read(), end="")')
    if printf '%s' "$request" | jq -e --arg path "$HOME/.claude.json" '.path == $path' >/dev/null; then
        printf '{"projects":{},"concurrent":"preserve me"}\n' > "$HOME/.claude.json"
        : > "$TEST_ROOT/edit-injected"
    fi
    printf '%s' "$request" | /usr/bin/python3 "$@"
    exit $?
fi
exec /usr/bin/python3 "$@"
WRAPPER
    chmod 700 "$TEST_ROOT/wrappers/python3"
    export PATH="$TEST_ROOT/wrappers:$PATH"
    setup_call --apply --trust claude --claude-writers-stopped
    [ -f "$TEST_ROOT/edit-injected" ] || fail 'concurrent edit was not injected'
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "source_changed"'
    assert_json "$HOME/.claude.json" '.concurrent == "preserve me" and .projects == {}'
}

native_pi_lock_respected() {
    setup_fixture
    printf '{"/saved":true}\n' > "$HOME/.pi/agent/trust.json"
    mkdir "$HOME/.pi/agent/trust.json.lock"
    printf 'native owner\n' > "$HOME/.pi/agent/trust.json.lock/owner"
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --apply --trust pi
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.result.conflicts | any(.[]; .path | endswith("trust.json.lock"))'
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
}

denied_child_trust_preserved() {
    setup_fixture
    local child="$HOME/Documents/private/denied"
    jq -n --arg child "$child" '{($child):false}' > "$HOME/.pi/agent/trust.json"
    jq -n --arg child "$child" '{projects:{($child):{hasTrustDialogAccepted:false,keep:1}}}' > "$HOME/.claude.json"
    setup_call --apply --trust both --claude-writers-stopped
    expect_status 0
    assert_json "$HOME/.pi/agent/trust.json" 'to_entries | any(.[]; (.key | endswith("/denied")) and .value == false)'
    assert_json "$HOME/.claude.json" '.projects | to_entries | any(.[]; (.key | endswith("/denied")) and .value == {hasTrustDialogAccepted:false,keep:1})'
    assert_json "$TEST_ROOT/helper.json" '.result.blocked_roots | length == 2'
    jq -e --arg root "$HOME/Documents/private" '.[$root] == true' "$HOME/.pi/agent/trust.json" >/dev/null
}

claude_writer_gate_required() {
    setup_fixture
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --apply --trust claude
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "setup_conflict" and (.result.conflicts | any(.[]; .reason | contains("--claude-writers-stopped")))'
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
    setup_call --apply --trust claude --claude-writers-stopped
    expect_status 0
    [ -f "$HOME/.claude.json" ]
}

trust_requires_explicit_apply() {
    setup_fixture
    setup_call --trust both
    expect_status 2
    [ ! -e "$HOME/.pi/agent/trust.json" ] && [ ! -e "$HOME/.claude.json" ]
    setup_call --dry-run --trust both
    expect_status 0
    [ ! -e "$HOME/.pi/agent/trust.json" ] && [ ! -e "$HOME/.claude.json" ]
    setup_call --apply
    expect_status 0
    [ ! -e "$HOME/.pi/agent/trust.json" ] && [ ! -e "$HOME/.claude.json" ]
}

generated_files_private() {
    setup_fixture
    # First create missing stores, then force a trust update to check backups too.
    setup_call --apply --trust both --claude-writers-stopped
    expect_status 0
    local path
    for path in "$HOME/.pi/agent/trust.json" "$HOME/.claude.json"; do
        assert_equal 600 "$(/usr/bin/python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$path")"
    done
    printf '{}\n' > "$HOME/.pi/agent/trust.json"
    printf '{}\n' > "$HOME/.claude.json"
    setup_call --apply --trust both --claude-writers-stopped
    expect_status 0
    /usr/bin/python3 - "$HOME" "$HERDR_DISPATCHER_CONFIG" "$TEST_ROOT/helper.json" <<'PY'
import json, os, stat, sys
home, config, response = sys.argv[1:]
with open(response) as source:
    result = json.load(source)["result"]
files = [config] + [entry["backup_path"] for entry in result["backups"]]
for path in files:
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600, path
for path in [home + "/.config", home + "/.config/herdr-dispatcher",
             home + "/.agents", home + "/.agents/skills",
             home + "/.claude", home + "/.claude/skills"]:
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o700, path
for parent, directories, names in os.walk(home):
    assert not any(".dispatcher-new." in name or ".dispatcher-owner." in name for name in names), parent
assert not os.path.exists(home + "/.pi/agent/trust.json.lock")
PY
}

unsupported_agent_dir_refused() {
    setup_fixture
    local override
    for override in PI_CODING_AGENT_DIR PI_PACKAGE_DIR CLAUDE_CONFIG_DIR; do
        export "$override=$TEST_ROOT/unsupported"
        setup_call --apply --trust both --claude-writers-stopped
        expect_status 2
        assert_json "$TEST_ROOT/helper.json" '.error.code == "unsupported_override"'
        unset "$override"
        [ ! -e "$HERDR_DISPATCHER_CONFIG" ]
    done
}

setup_file_case() {
    /usr/bin/python3 "$TEST_REPO/tests/fixtures/setup-files-safety.py" "Safety.$1"
}

backup_disk_full() { setup_file_case test_backup_disk_full; }
backup_partial_write() { setup_file_case test_backup_partial_write; }
backup_signal() { setup_file_case test_backup_signal; }
backup_fsync_failure() { setup_file_case test_backup_fsync_failure; }

bash_mutation_signal_case() {
    local tool=$1 path=$2 uncertain=${3:-false}
    setup_fixture
    mkdir "$TEST_ROOT/wrappers"
    cat > "$TEST_ROOT/wrappers/$tool" <<'WRAPPER'
#!/bin/bash
"/bin/$SETUP_TEST_TOOL" "$@" || exit $?
case "${!#}" in
    "$HOME/.agents"|"$HOME/.agents/skills/ask-dispatcher")
        [ "$SETUP_TEST_UNCERTAIN" = child-only ] || kill -TERM "$PPID"
        [ "$SETUP_TEST_UNCERTAIN" = false ] || exit 143 ;;
esac
WRAPPER
    chmod 700 "$TEST_ROOT/wrappers/$tool"
    export SETUP_TEST_TOOL="$tool" SETUP_TEST_UNCERTAIN="$uncertain"
    export PATH="$TEST_ROOT/wrappers:$PATH"
    setup_call --apply
    expect_status 5
    [ -e "$path" ] || [ -L "$path" ] || fail 'mutation did not complete'
    jq -e --arg path "$path" '.outcome == "uncertain" and any(.result.changes[]; .path == $path and .applied == true)' "$TEST_ROOT/helper.json" >/dev/null
}
python_preflight_rejected() {
    setup_fixture
    mkdir "$TEST_ROOT/wrappers"
    cat > "$TEST_ROOT/wrappers/python3" <<'WRAPPER'
#!/bin/bash
set -eu
if [ "$#" -eq 3 ] && [ "$1" = -I ] && [ "$2" = -c ]; then
    case "$SETUP_PYTHON_FAULT" in
        version) prefix='import sys; sys.version_info = (3, 7, 0)' ;;
        nofollow) prefix='import os; del os.O_NOFOLLOW' ;;
        directory) prefix='import os; del os.O_DIRECTORY' ;;
        signals) prefix='import signal; del signal.pthread_sigmask' ;;
        replace) prefix='import os; os.replace = lambda source, destination: None' ;;
        unsupported_replace) prefix='import os
def unsupported(source, destination, *, src_dir_fd=None, dst_dir_fd=None):
    raise NotImplementedError("dirfd unavailable")
os.replace = unsupported' ;;
    esac
    exec /usr/bin/python3 -I -c "$prefix
$3"
fi
exec /usr/bin/python3 "$@"
WRAPPER
    chmod 700 "$TEST_ROOT/wrappers/python3"
    export PATH="$TEST_ROOT/wrappers:$PATH"
    local fault
    for fault in version nofollow directory signals replace unsupported_replace; do
        export SETUP_PYTHON_FAULT="$fault"
        setup_snapshot > "$TEST_ROOT/before.json"
        setup_call --apply
        expect_status 6
        assert_json "$TEST_ROOT/helper.json" '.error.code == "unsupported_python" and .result.changes == []'
        setup_snapshot > "$TEST_ROOT/after.json"
        cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
    done
}

mkdir_signal_recorded() { bash_mutation_signal_case mkdir "$HOME/.agents"; }
ln_signal_recorded() { bash_mutation_signal_case ln "$HOME/.agents/skills/ask-dispatcher"; }
mkdir_uncertain_recorded() { bash_mutation_signal_case mkdir "$HOME/.agents" true; }
ln_uncertain_recorded() { bash_mutation_signal_case ln "$HOME/.agents/skills/ask-dispatcher" true; }
mkdir_child_uncertain_recorded() { bash_mutation_signal_case mkdir "$HOME/.agents" child-only; }
ln_child_uncertain_recorded() { bash_mutation_signal_case ln "$HOME/.agents/skills/ask-dispatcher" child-only; }

backup_edit_keeps_validated_baseline() { setup_file_case test_backup_edit_keeps_validated_baseline; }
directory_swap_before_rename() { setup_file_case test_directory_swap_before_rename; }
symlink_swap_before_rename() { setup_file_case test_symlink_swap_before_rename; }
parent_swap_before_rename() { setup_file_case test_parent_swap_before_rename; }
deadline_overrun_inside_inspection() { setup_file_case test_deadline_overrun_inside_inspection; }
native_lock_replacement_inside_inspection() { setup_file_case test_native_lock_replacement_inside_inspection; }
native_lock_replacement_before_rename() { setup_file_case test_native_lock_replacement_before_rename; }
deadline_overrun_at_final_destination_stat() { setup_file_case test_deadline_overrun_at_final_destination_stat; }
signal_retains_uncommitted_evidence() { setup_file_case test_signal_retains_uncommitted_evidence; }
signal_retains_committed_evidence() { setup_file_case test_signal_retains_committed_evidence; }

protected_root_ancestor_refused() {
    setup_fixture
    local root
    # Include an ancestor outside HOME, HOME itself, and Documents. All are
    # synthetic paths. Also move the protected test directory via a symlink.
    mkdir -p "$HOME/Documents/test" "$HOME/allowed-looking/test-area"
    rmdir "$HOME/Documents/test"
    ln -s "$HOME/allowed-looking/test-area" "$HOME/Documents/test"
    for root in "$TEST_ROOT" "$HOME" "$HOME/Documents" "$HOME/allowed-looking"; do
        jq --arg root "$root" '.trust_roots=[$root]' "$TEST_ROOT/setup-input.json" > "$TEST_ROOT/protected-input.json"
        setup_snapshot > "$TEST_ROOT/before.json"
        setup_call --apply --config-input "$TEST_ROOT/protected-input.json" --trust both --claude-writers-stopped
        expect_status 2
        assert_json "$TEST_ROOT/helper.json" '.error.code == "invalid_root"'
        setup_snapshot > "$TEST_ROOT/after.json"
        cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
    done
}

role_kind_default_requires_reporter() {
    setup_fixture
    /usr/bin/python3 - "$TEST_ROOT/repo/roles/review.md" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines(keepends=True)
metadata = json.loads(lines[1])
metadata["kind"] = "claude"
lines[1] = json.dumps(metadata) + "\n"
path.write_text("".join(lines))
PY
    jq 'del(.worker_kinds.review)' "$TEST_ROOT/setup-input.json" > "$TEST_ROOT/role-default-input.json"
    setup_read_rules 'pi: current (v1)
claude: missing'
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --apply --config-input "$TEST_ROOT/role-default-input.json"
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "reporter_not_current" and (.error.message | contains("claude"))'
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
}

missing_reporter_reported() {
    setup_fixture
    setup_read_rules 'pi: missing'
    setup_snapshot > "$TEST_ROOT/before.json"
    setup_call --apply
    expect_status 3
    assert_json "$TEST_ROOT/helper.json" '.error.code == "reporter_not_current" and (.error.message | contains("pi"))'
    setup_snapshot > "$TEST_ROOT/after.json"
    cmp "$TEST_ROOT/before.json" "$TEST_ROOT/after.json"
}
