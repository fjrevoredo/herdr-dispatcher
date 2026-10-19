# Offline shell tests

Run `bash "tests/run.sh"` for all tests. Pass test names or groups (`runner`,
`shell`, `fake`, `state`, `ring`, `spawn`, `blockers`, `client_contract`, `setup`, `whole_flow`) to select tests. Unknown or empty selections exit 2. A failed
case exits 1. The deliberate failure is available only to the inner runner
self-test, never to the default suite.

Run `bash tests/lint.sh` for Bash syntax and ShellCheck on all shipped shell
files, including the hook and the fake CLI. Bash 3.2, jq, and standard system
utilities run the runtime tests. Setup tests also need Python3 for the setup-only standard-library
file writer. Python is not a runtime dependency. ShellCheck is an additional lint dependency.
Do not install packages or run `pi --version` to validate this documentation; the latter can
mutate installation cleanup.

Each case gets a private temporary root, HOME, config, run directory, and
PATH-selected fake CLI. The runner removes only its marked temporary root on
exit. It does not call the installed herdr or use the network. Tests must use
sanitized data. Call logs can contain the test arguments.

## Script a CLI response

`scenario` writes a JSON array to `$FAKE_HERDR_SCENARIO`. Each entry contains:

- `argv`: the exact argument array, without the executable name.
- `status`: the exit code from 0 to 255.
- `stdout` and `stderr`: a JSON value, text, or null for no output.
- `delay_seconds`: optional delay from 0 to 2 seconds for short budget tests.
- `persistent: true`: optional stable read rule. It is not consumed.

All argv tokens match exactly except the explicit object `{"timeout_ms":true}`.
That object matches a decimal integer from 1 to 300000 only after `--timeout`.
It is useful in queued prompt responses where the helper computes a deadline.
There are no general wildcards. Persistent rules permit only `agent list/get/read`,
`pane current/process-info`, and `workspace list` or `tab list`. Each argv must
match exactly one persistent rule. Persistent mutation rules are refused.

For example:

```bash
response=$(fixture agent_list)
scenario "$(jq -cn --argjson response "$response" \
  '[{argv:["agent","list"],status:0,stdout:$response,stderr:null}]')"
herdr agent list > "$TEST_ROOT/list.json"
```

The fake consumes one matching entry per call. An unexpected or unscripted call
exits 2. It never falls back to the real CLI. It logs JSON lines to
`$FAKE_HERDR_LOG` with `cli`, `argv`, `target`, and `cwd`. File paths, HOME,
and cwd must remain in the marked temporary root. Remote and session override
options are refused. A private mkdir lock serializes queue consumption and
logging. Concurrent callers can share stable read rules or an ordered queue.
The fake releases the lock before a scripted delay. Rewrite a scenario only
when no CLI call is active. This is not a live state server. A missing response,
ambiguous rule, or abandoned fake lock stops the call; there is no real fallback.

`TEST_NOW` and `advance_time` provide a test-owned clock value for later TTL
cases. They do not alter the system clock or define a production clock API.
Use short real child delays for process deadline checks. Runtime temp files
also use a private `TMPDIR` below the test root.

## Fixture source and limits

`fixtures/herdr.json` contains the minimal herdr 0.9.3 adapter shapes recorded
in `docs/protocol.md` sections 4 and 4.1. IDs, process numbers, paths, and error
messages are synthetic. The agent is intentionally unnamed. Its foreground
process PID differs from the process-group ID. Do not infer either identity
field from the other.

Creation fixtures contain only the documented returned object locations and
IDs. The source inspection did not create a live workspace or tab. These are
contract fixtures, not evidence of a live creation check. This task makes no
live calls. Helper envelopes use a separate shape; `assert_envelope` checks
that shape, while `assert_json` checks command-specific data.

## State contract group

Run `/bin/bash tests/run.sh state` for Task 2.1. The tests call the real
`new-run`, `registry`, and `run-state` helpers. `fixtures/state.jq` creates
synthetic request, status, report, worker, workspace, and launch records with
sandbox-owned paths. Matching launch journals prove worker ownership.
`collision-date` and `collision-od` are installed only in one test's private
PATH. They force the first publication ID to collide, then use real randomness.
They do not change the system clock.

The state cases are:

- `concurrent_run_ids`
- `existing_run_never_overwritten`
- `unpublished_run_ignored`
- `partial_result_ignored`
- `wrong_run_result_rejected`
- `wrong_worker_result_rejected`
- `invalid_transition_rejected`
- `malformed_metadata_reported`
- `path_escape_rejected`
- `unrelated_named_agent_excluded`
- `missing_identity_quarantined`
- `stale_worker_reported`
- `failure_relay_retained`
- `duplicate_worker_assignment_rejected`
- `crash_between_state_files`

Crash tests create the files left at the two documented write boundaries.
They call real `worker-sync` to repair the derived cache. They do not claim
power-loss durability or test an actual killed process. The release test
checks that later scans preserve the first observation time.

These are contract assertions, not expected-failure tests. An `unimplemented`
response must not satisfy a valid assignment. Assignment and concurrent
publication pass after the state and lock fixes. The fake tests separately
check shared queue safety and bounded arguments.

## Ring and startup groups

Run `bash tests/run.sh ring` for input ownership, shared target locks, bounded
queries, and uncertain delivery. Run `bash tests/run.sh spawn` for startup,
role capacity, reuse, replacement, explicit registration, and retained launch
records. Run `bash tests/run.sh blockers` for historical workspace ownership,
registration crash gaps, and dispatcher input in a worker-created workspace.
These groups use the real helpers with the fake CLI only.

The model cases `spawn_claude_worker_model`, `spawn_claude_dispatcher_model`,
`spawn_claude_default_model`, `spawn_pi_model_isolation`, and `spawn_invalid_claude_model`
check exact Claude launch arguments, unchanged defaults/Pi startup, and invalid config rejection
before any CLI call. `setup_claude_model_preserved` and `setup_invalid_claude_model` check the
same optional config field through setup. Invalid cases include trailing newlines and oversized
values. Fake launch arguments do not prove which model a live Claude session uses.

Queued mutations can update persistent agent/workspace inventories through
`after_agent_list` and `after_workspace_list`. Repeated queued commands are
consumed in order. Persistent reads still require a unique match.

Startup reuse fixtures use the current UTC time. Expiry fixtures use old
saved timestamps. The production clock has one-second precision, so retry
budgets must not increase, but need not decrease on every call. These tests
do not prove live agent readiness, trust behavior, or model actions.

## Requester contracts

Run `bash tests/run.sh client_contract` for caller context, moved-pane identity,
managed-requester denial, exact RESULT/FAILED paths, and request retention after
an uncertain wake. Example body files under `fixtures/requests/` and report
bodies under `fixtures/reports/` cover both roles. Tests generate matching
frontmatter from sandbox records and validate reports through the real helper.
They do not prove skill discovery, model routing, or repeated-notice handling.
Those checks need separate approved live pi/Claude sessions.

## Whole-flow simulations

Run `bash tests/run.sh whole_flow` for Task 4.2. Select an exact case name for a
shorter check. `tests/flow.sh` composes real publication, registry, assignment,
CAS, ring, worker synchronization, reuse, and retirement calls. Each scenario
uses private fake CLI state. Calls have finite budgets. The shell-heavy group
can take several minutes; running many cases in parallel can exhaust query budgets.

The 25 cases are:

- `review_round_trip`
- `explore_round_trip`
- `restart_after_send`
- `lost_bell_then_reconcile`
- `role_queue_preserved`
- `result_before_worker_idle`
- `busy_requester_relay_deferred`
- `replaced_requester_not_prompted`
- `nudge_only_once`
- `completed_result_survives_worker_exit`
- `ttl_cleanup_only_owned_idle`
- `relayed_worker_released_on_later_turn`
- `gone_requester_does_not_hold_capacity`
- `failed_worker_retired_only_when_settled`
- `unknown_worker_not_reassigned`
- `failed_notice_retry_fair`
- `failed_late_result_preserved`
- `nudge_timeout_not_resent`
- `uncertain_nudge_blocks_retry_and_failure`
- `missing_report_failure_relayed_to_saved_requester`
- `blocked_assigned_worker_quarantined`
- `malformed_run_inventory_blocks_assignment`
- `worker_launch_ownership_mismatch_blocks_assignment_and_reuse`
- `held_worker_cannot_be_claimed_by_second_run`
- `direct_cas_cannot_mutate_assignment_snapshot`

Both role round trips publish a real request, reuse a fixture-owned worker,
assign it, observe fake working activity after ring, save sent delivery, publish
an atomic report, send DONE, mark done/pending, relay RESULT, and release/reuse
only after a later settled observation. Initial ownership and live topology are
synthetic fixtures, not a live startup check. Reports use saved assignment tokens.
The temporary report is scanned before rename and must not count as completion.

The test code explicitly makes the dispatcher decisions. Restart cases stop at
durable boundaries; they do not kill a dispatcher or execute a model algorithm.
An unresolved `sending` attempt rejects a fresh attempt token, but this does not
prove that a model will choose not to ring it again. Lost bells are omitted, then
a fresh scan discovers the report. The fair retry case sorts saved notices and
rings them in that order. These checks do not prove agent routing, model
deduplication, report quality, or requester handling. Further cases require a
later settled observation before `missing_report`, relay FAILED to the saved
requester, reject retry/failure after uncertain nudges, and check blocked,
malformed, stale-ownership, duplicate-assignment, and immutable-assignment paths.
Final guards compare retained request/report bytes and reject non-read-only CLI
calls in quarantine cases. They reject prompts to unrelated panes or closes
outside checked retirement. No offline test grants setup or live-operation
approval.

## Setup contracts and limits

Run `bash "tests/run.sh" setup` for Task 4.1 and `bash "tests/lint.sh"` for shell checks.
The setup group calls the real preview/apply helper with sandbox config, HOME, fake herdr,
and synthetic installed-agent metadata. It does not write real skill links or trust stores.
It does not grant user setup or live-operation approval.

Cases cover write-free preview, idempotent apply, config selection/replacement, link conflicts,
invalid JSON, preserved unrelated trust keys and denied children, explicit trust selection,
Claude's stopped-writer gate, private generated files, unsupported overrides, missing reporters,
protected root ancestors, supported Herdr 0.9.5, and rejected mixed, unknown, or wrong-protocol
Herdr versions. Further cases cover backup/source changes, destination directory and symlink swaps,
parent replacement, native lock replacement, expired transaction checks,
and retained evidence for signals before and after commit.

The managed Pi fixtures represent filesystem metadata for Pi 1.2.0 and 1.3.0 with
proper-lockfile 4.1.2, a 10000-ms stale interval, and a 5000-ms update interval. Tests reject
other Pi versions. The setup-only Python writer holds an empty
native lock plus a private sibling sidecar. It checks a 2000-ms cap with monotonic and wall clocks,
parent-chain and inode identity, and source snapshots. It never steals or heartbeats the lock.
Parent-fd atomic replacement cannot be redirected into a newly substituted parent directory.
Uncertain evidence remains for inspection. Tests do not prove a hard real-time bound, power-loss
durability, or immunity to malicious external writers. Claude's declaration and final source
comparison cannot prevent an unsynchronized external write after that check. Real Claude config
writers must be stopped by the user before separately approved trust apply.

Fake metadata and controlled file-change cases do not prove compatibility with a future installed
agent version, live native locking under all scheduling conditions, skill discovery, or model
handling. Do not trust all Documents or Documents/test for these checks. Fixture trust and live
panes require separate explicit approval; offline tests are not that approval.
