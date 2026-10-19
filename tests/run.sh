#!/bin/bash
set -euo pipefail
TEST_REPO=$(cd "$(dirname "$0")/.." && pwd -P)
export TEST_REPO
# The absolute checkout path is resolved at runtime.
# shellcheck disable=SC1091
source "$TEST_REPO/tests/helpers.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/state.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/ring.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/spawn.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/blockers.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/client.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/setup.sh"
# shellcheck disable=SC1091
source "$TEST_REPO/tests/flow.sh"

runner_self_test() {
    local status=0
    TEST_RUNNER_INNER=1 /bin/bash "$TEST_REPO/tests/run.sh" --inner-failure > "$TEST_ROOT/inner.out" 2>&1 || status=$?
    assert_equal 1 "$status"
    grep -Fx 'FAIL: intentional inner failure' "$TEST_ROOT/inner.out" >/dev/null
    grep -Fx 'not ok - intentional_failure' "$TEST_ROOT/inner.out" >/dev/null
}

no_test_selector_rejected() {
    local selector status
    for selector in unknown-test --inner-empty; do
        status=0
        TEST_RUNNER_INNER=1 /bin/bash "$TEST_REPO/tests/run.sh" "$selector" > "$TEST_ROOT/selector.out" 2>&1 || status=$?
        assert_equal 2 "$status"
        case "$selector" in
            unknown-test) grep -Fx 'unknown selector: unknown-test' "$TEST_ROOT/selector.out" >/dev/null ;;
            --inner-empty) grep -Fx 'no tests for selector: --inner-empty' "$TEST_ROOT/selector.out" >/dev/null ;;
        esac
    done
}

shell_files() {
    local file
    for file in tests/run.sh tests/lint.sh tests/helpers.sh tests/flow.sh tests/state.sh tests/spawn.sh tests/client.sh tests/setup.sh tests/fake-bin/herdr tests/fixtures/collision-date tests/fixtures/collision-od .githooks/pre-commit; do
        [ -x "$TEST_REPO/$file" ] || fail "not executable: $file"
        /bin/bash -n "$TEST_REPO/$file"
    done
    if [ -d "$TEST_REPO/bin" ]; then
        while IFS= read -r -d '' file; do
            [ -x "$file" ] || fail "not executable: $file"
            /bin/bash -n "$file"
        done < <(find "$TEST_REPO/bin" -type f -print0)
    fi
}

fake_cli() {
    local response status=0
    assert_equal "$TEST_REPO/tests/fake-bin/herdr" "$(command -v herdr)"
    response=$(fixture agent_list)
    scenario "$(jq -cn --argjson response "$response" '[{argv:["agent","list"],status:0,stdout:$response,stderr:null}]')"
    herdr agent list > "$TEST_ROOT/list.json"
    assert_json "$TEST_ROOT/list.json" '.result.type == "agent_list" and (.result.agents[0] | has("name") | not)'
    assert_json "$FAKE_HERDR_LOG" '.cli == "fake-herdr" and .argv == ["agent","list"]'
    response=$(fixture agent_blocked)
    scenario "$(jq -cn --argjson response "$response" '[{argv:["agent","prompt","wTest:p1","test"],status:1,stdout:null,stderr:$response}]')"
    herdr agent prompt wTest:p1 test > "$TEST_ROOT/prompt.out" 2> "$TEST_ROOT/prompt.err" || status=$?
    assert_equal 1 "$status"
    [ ! -s "$TEST_ROOT/prompt.out" ] || fail 'server error on stdout'
    assert_json "$TEST_ROOT/prompt.err" '.error.code == "agent_blocked"'
    assert_equal 'wTest:p1' "$(jq -r 'select(.argv[1] == "prompt") | .target' "$FAKE_HERDR_LOG")"
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 0'
    status=0
    herdr agent list > "$TEST_ROOT/unscripted.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    jq -se 'all(.[]; .cli == "fake-herdr") and length == 3' "$FAKE_HERDR_LOG" >/dev/null
}

fake_safety() {
    local status=0
    (cd /; herdr agent list) > "$TEST_ROOT/outside.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    HOME=/ herdr agent list > "$TEST_ROOT/home.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    TEST_ROOT='' herdr agent list > "$TEST_ROOT/root.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    herdr workspace create --cwd / > "$TEST_ROOT/cwd.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    status=0
    herdr agent list --remote example > "$TEST_ROOT/remote.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    [ ! -s "$FAKE_HERDR_LOG" ] || fail 'unsafe call was logged'
}

fixture_shapes() {
    local fixtures="$TEST_REPO/tests/fixtures/herdr.json"
    assert_json "$fixtures" '.process_info.result.process_info | .foreground_process_group_id > 0 and (.foreground_processes | length > 0)'
    assert_json "$fixtures" '.pane_current.result.pane.agent_session == .agent_list.result.agents[0].agent_session'
    assert_json "$fixtures" '.workspace_create.result | .workspace.workspace_id == .root_pane.workspace_id and .tab.tab_id == .root_pane.tab_id'
    assert_json "$fixtures" '.tab_create.result | .tab.tab_id == .root_pane.tab_id'
    printf '%s\n' '{"schema_version":1,"ok":true,"outcome":"ok","result":{},"error":null}' > "$TEST_ROOT/envelope.json"
    assert_envelope "$TEST_ROOT/envelope.json"
    advance_time '2026-10-14T14:15:00Z'
    assert_equal '2026-10-14T14:15:00Z' "$TEST_NOW"
    state_setup
    owned_worker
    assigned_run
    valid_report
    # Validate all synthetic records with the production schema, in a child so
    # lib.sh cleanup traps cannot replace this test's sandbox cleanup trap.
    /bin/bash -c '
        set -eu
        source "$1/bin/lib.sh"
        hd_json_validate role "$2/repo/roles/review.md"
        hd_json_validate request "$2/repo/runs/$3/request.md"
        hd_json_validate status "$2/repo/runs/$3/status"
        hd_json_validate result "$2/repo/runs/$3/result.md"
        hd_json_validate worker "$2/repo/runs/.workers/review-1"
        hd_json_validate workspace "$2/repo/runs/.workspace.json"
        hd_json_validate launch "$2/repo/runs/.launches/11111111111111111111111111111111.json"
        hd_json_validate launch "$2/repo/runs/.launches/22222222222222222222222222222222.json"
    ' _ "$TEST_REPO" "$TEST_ROOT" "$RUN_ID"
}

fake_persistent_reads() {
    local response status=0 a b
    response=$(fixture agent_list)
    scenario "$(jq -cn --argjson response "$response" '[{persistent:true,argv:["agent","list"],status:0,stdout:$response,stderr:null}]')"
    herdr agent list > "$TEST_ROOT/a.json" & a=$!
    herdr agent list > "$TEST_ROOT/b.json" & b=$!
    wait "$a"
    wait "$b"
    assert_json "$TEST_ROOT/a.json" '.result.type == "agent_list"'
    assert_json "$TEST_ROOT/b.json" '.result.type == "agent_list"'
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 1'
    jq -se 'length == 2 and all(.[]; .argv == ["agent","list"])' "$FAKE_HERDR_LOG" >/dev/null
    herdr agent get wTest:p1 > "$TEST_ROOT/unexpected.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    scenario '[{"persistent":true,"argv":["pane","close","wTest:p1"],"status":0,"stdout":{},"stderr":null}]'
    status=0
    herdr pane close wTest:p1 > "$TEST_ROOT/mutation.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 1'
    scenario '[{"argv":["agent","prompt","wTest:p1","synthetic","--timeout",{"timeout_ms":true}],"status":0,"stdout":{},"stderr":null}]'
    status=0
    herdr agent prompt wTest:p1 synthetic --timeout 300001 > "$TEST_ROOT/bounds.out" 2>&1 || status=$?
    assert_equal 2 "$status"
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 1'
    herdr agent prompt wTest:p1 synthetic --timeout 2000 > "$TEST_ROOT/bounded.json"
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 0'
}

fake_concurrent_queue() {
    local a b
    scenario '[{"argv":["agent","list"],"status":0,"stdout":{"id":"first"},"stderr":null},{"argv":["agent","list"],"status":0,"stdout":{"id":"second"},"stderr":null}]'
    herdr agent list > "$TEST_ROOT/a.json" & a=$!
    herdr agent list > "$TEST_ROOT/b.json" & b=$!
    wait "$a"
    wait "$b"
    jq -se 'map(.id) | sort == ["first","second"]' "$TEST_ROOT/a.json" "$TEST_ROOT/b.json" >/dev/null
    assert_json "$FAKE_HERDR_SCENARIO" 'length == 0'
    jq -se 'length == 2 and all(.[]; .cli == "fake-herdr")' "$FAKE_HERDR_LOG" >/dev/null
}

names=(runner_self_test no_test_selector_rejected shell_files fake_cli fake_safety fixture_shapes fake_persistent_reads fake_concurrent_queue)
groups=(runner runner shell fake fake fake fake fake)
state_names=(gone_worker_sync_recovers_crash_gaps gone_worker_sync_closes_journal notice_retries_remain_valid live_identity_gaps_retained stale_nonempty_idle_recovered malformed_release_blocks_assignment status_cross_fields_validated concurrent_run_ids existing_run_never_overwritten unpublished_run_ignored partial_result_ignored wrong_run_result_rejected wrong_worker_result_rejected invalid_transition_rejected malformed_metadata_reported path_escape_rejected unrelated_named_agent_excluded missing_identity_quarantined stale_worker_reported failure_relay_retained duplicate_worker_assignment_rejected crash_between_state_files)
for name in "${state_names[@]}"; do names+=("$name"); groups+=(state); done
ring_names=(ring_success_literal busy_target_not_prompted concurrent_ringers_serialized alias_lock_shared blocked_target_not_typed total_deadline_bounded signal_releases_own_lock live_lock_not_stolen dead_lock_recovered ambiguous_delivery_not_resent replaced_target_under_lock_not_prompted self_target_rejected hung_query_deadline_bounded ring_ownership_required ring_expected_required released_dead_owner_retried worker_record_disappears_while_waiting requester_result_input_accepted registered_dispatcher_reconcile ring_common_options working_ack_identity_required)
for name in "${ring_names[@]}"; do names+=("$name"); groups+=(ring); done
spawn_names=(spawn_claude_worker_model spawn_claude_dispatcher_model spawn_claude_default_model spawn_pi_model_isolation spawn_invalid_claude_model spawn_startup_success spawn_dispatcher_success busy_shell_retry_bounded spawn_busy_deadline trust_dialog_not_answered create_response_lost_not_repeated config_override_propagated unregistered_dispatcher_refused same_cwd_reuse worker_capacity_reserved different_cwd_replaced expired_worker_replaced wrong_named_agent_refused concurrent_dispatcher_start startup_timeout_preserves_evidence startup_lock_deadline_bounded unrelated_pane_never_closed ready_journal_missing_registration_recovered ambiguous_created_recovery_refuses_start fresh_worker_retirement_refused ambiguous_idle_retirement_refused public_retirement_eligibility replaced_occupant_retirement_refused explicit_dispatcher_registration_reused)
for name in "${spawn_names[@]}"; do names+=("$name"); groups+=(spawn); done
blocker_names=(closed_worker_workspace_replacement retired_worker_historical_launch_required nonterminal_worker_workspace_proof_required registration_journal_gap_uncertain registration_journal_gap_observed registration_journal_gap_mismatch_refused ring_worker_created_workspace_dispatcher)
for name in "${blocker_names[@]}"; do names+=("$name"); groups+=(blockers); done
client_names=(missing_context missing_config moved_caller_resolved managed_requester_rejected foreign_result_path_rejected failure_path_validated preserved_run_after_ring_timeout client_role_fixtures)
for name in "${client_names[@]}"; do names+=("$name"); groups+=(client_contract); done
setup_names=(herdr_093_legacy_status_supported herdr_095_pair_supported herdr_mixed_pair_refused herdr_unknown_version_refused herdr_wrong_protocol_refused pi_13_trust_adapter_supported pi_unknown_trust_adapter_refused setup_claude_model_preserved setup_invalid_claude_model mkdir_child_uncertain_recorded ln_child_uncertain_recorded python_preflight_rejected backup_disk_full backup_partial_write backup_signal backup_fsync_failure mkdir_signal_recorded ln_signal_recorded mkdir_uncertain_recorded ln_uncertain_recorded preview_has_no_writes apply_is_idempotent config_override_resolved conflicting_link_refused invalid_trust_json_preserved unrelated_trust_keys_preserved concurrent_trust_edit_refused native_pi_lock_respected denied_child_trust_preserved claude_writer_gate_required trust_requires_explicit_apply generated_files_private unsupported_agent_dir_refused missing_reporter_reported backup_edit_keeps_validated_baseline directory_swap_before_rename symlink_swap_before_rename parent_swap_before_rename deadline_overrun_inside_inspection native_lock_replacement_inside_inspection native_lock_replacement_before_rename deadline_overrun_at_final_destination_stat signal_retains_uncommitted_evidence signal_retains_committed_evidence protected_root_ancestor_refused role_kind_default_requires_reporter)
for name in "${setup_names[@]}"; do names+=("$name"); groups+=(setup); done
flow_names=(review_round_trip explore_round_trip restart_after_send lost_bell_then_reconcile role_queue_preserved result_before_worker_idle busy_requester_relay_deferred replaced_requester_not_prompted nudge_only_once completed_result_survives_worker_exit ttl_cleanup_only_owned_idle relayed_worker_released_on_later_turn gone_requester_does_not_hold_capacity failed_worker_retired_only_when_settled unknown_worker_not_reassigned failed_notice_retry_fair failed_late_result_preserved nudge_timeout_not_resent uncertain_nudge_blocks_retry_and_failure missing_report_failure_relayed_to_saved_requester blocked_assigned_worker_quarantined malformed_run_inventory_blocks_assignment worker_launch_ownership_mismatch_blocks_assignment_and_reuse held_worker_cannot_be_claimed_by_second_run direct_cas_cannot_mutate_assignment_snapshot)
for name in "${flow_names[@]}"; do names+=("$name"); groups+=(whole_flow); done
group_names=(runner shell fake state ring spawn blockers client_contract setup whole_flow)
if [ "${TEST_RUNNER_INNER:-0}" = 1 ]; then group_names+=(--inner-empty); fi
selectors=("$@")
if [ "$#" -eq 0 ]; then selectors=(all); fi
selected=' '
for selector in "${selectors[@]}"; do
    known=0
    matched=0
    for group in "${group_names[@]}"; do
        if [ "$selector" = "$group" ]; then known=1; fi
    done
    for ((i=0; i<${#names[@]}; i++)); do
        if [ "$selector" = all ] || [ "$selector" = "${names[$i]}" ] || [ "$selector" = "${groups[$i]}" ]; then
            known=1
            matched=1
            case "$selected" in *" ${names[$i]} "*) ;; *) selected="$selected${names[$i]} " ;; esac
        fi
    done
    if [ "${TEST_RUNNER_INNER:-0}" = 1 ] && [ "$selector" = --inner-failure ]; then
        known=1
        matched=1
        selected=' intentional_failure '
    fi
    if [ "$known" -eq 0 ]; then
        printf 'unknown selector: %s\n' "$selector" >&2
        exit 2
    fi
    if [ "$matched" -eq 0 ]; then
        printf 'no tests for selector: %s\n' "$selector" >&2
        exit 2
    fi
done
intentional_failure() { fail 'intentional inner failure'; }
passed=0
failed=0
for name in $selected; do
    # Do not put the case in an if-condition: Bash would disable errexit inside it.
    set +e
    (set -e; sandbox; "$name")
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        printf 'ok - %s\n' "$name"
        passed=$((passed + 1))
    else
        printf 'not ok - %s\n' "$name"
        failed=$((failed + 1))
    fi
done
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
