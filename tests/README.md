# Offline shell tests

Run `bash tests/run.sh` for all tests. Pass test names or groups (`runner`,
`shell`, `fake`, `state`, `ring`, `spawn`, `blockers`) to select tests. Unknown or empty selections exit 2. A failed
case exits 1. The deliberate failure is available only to the inner runner
self-test, never to the default suite.

Run `bash tests/lint.sh` for Bash syntax and ShellCheck on all shipped shell
files, including the hook and the fake CLI. Bash 3.2, jq, and standard system
utilities run the tests. ShellCheck is an additional lint dependency.

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

Queued mutations can update persistent agent/workspace inventories through
`after_agent_list` and `after_workspace_list`. Repeated queued commands are
consumed in order. Persistent reads still require a unique match.

Startup reuse fixtures use the current UTC time. Expiry fixtures use old
saved timestamps. The production clock has one-second precision, so retry
budgets must not increase, but need not decrease on every call. These tests
do not prove live agent readiness, trust behavior, or model actions.
