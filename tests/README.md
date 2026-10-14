# Offline shell tests

Run `bash tests/run.sh` for all tests. Pass test names or groups (`runner`,
`shell`, `fake`) to select tests. Unknown or empty selections exit 2. A failed
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
options are refused. Use separate queue files for concurrent callers; the
queue does not implement a concurrent state server.

`TEST_NOW` and `advance_time` provide a test-owned clock value for later TTL
cases. They do not alter the system clock or define a production clock API.
Use short real child delays for process deadline checks.

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
