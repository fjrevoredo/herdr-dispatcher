# Herdr Dispatcher

Route read-only review and exploration requests to owned pi or Claude workers in one local
herdr server. Requests, status, and reports stay in this checkout. The dispatcher routes tasks;
it does not execute them. Read-only roles use instructions, not an enforced security boundary.

## Requirements and approval

Runtime needs Bash 3.2, jq, standard system tools, a matching Herdr 0.9.3 or 0.9.5 client/server
pair, and current reporters for each selected agent kind. Setup also needs Python 3.8 or later with
POSIX directory-file-descriptor and signal support for the internal standard-library file writer.
Setup checks these capabilities before writes. Python is for explicit user-approved setup only.
Setup does not install packages, upgrade agents, or change credentials. Missing dependencies,
permission errors, unsupported versions, and conflicting paths stop setup.

Maintenance or plan approval does not approve setup. Francisco must approve the exact config,
skill-link, and trust changes. Only the user runs apply. A separate approval is necessary for
live panes and model turns. Do not answer permission or trust dialogs. Keep the inherited local
server context. Do not add remote, machine, or session overrides.

## Preview and user-run setup

Run these examples in Bash. Select the physical checkout and an absolute config destination:

```bash
repo="/absolute/herdr-dispatcher"
export HERDR_DISPATCHER_CONFIG="$HOME/.config/herdr-dispatcher/config.json"
"$repo/bin/setup" --dry-run --trust none
```

The default destination is `"$HOME/.config/herdr-dispatcher/config.json"`. An existing valid config
is reused. Without one, defaults select this physical checkout, pi for dispatcher and both roles,
a 900-second idle TTL, 30000-ms ring/startup budgets, and exactly two existing physical roots:
`"$HOME/Documents/smec-dev"` and `"$HOME/Documents/private"`. Missing roots need a complete input
config. See [the config schema](docs/protocol.md#3-config-and-roles).

For a session-only Claude model, add `"claude_model":"claude-haiku-5-5"` to a complete config.
Spawn forwards it as `-- --model claude-haiku-5-5` for new Claude workers and dispatchers only.
Omit it to use the harness model. It does not change global settings or existing sessions.
Keep the model selection stable while its agents exist. Settle and retire the old owned agents before
changing this value. Confirm the model on the Claude startup screen before sending a test task.
An external requester needs its own explicit launch model; this config does not control it.

Preview creates no files, directories, links, backups, panes, or agents. Read its exit status
and JSON envelope. Review `checks`, `changes`, `conflicts`, and `blocked_roots`. Do not publish
global JSON or task contents. Setup checks agent availability without executing agent CLIs.
It must not run `pi --version`; that command can mutate installation cleanup.

Use a complete JSON config, not a partial patch:

```bash
"$repo/bin/setup" --dry-run --config-input "/absolute/selected-config.json" --trust none
"$repo/bin/setup" --dry-run --config-input "/absolute/selected-config.json" --replace-config --trust none
```

A different existing config needs `--replace-config`. Without `--config-input`, replacement
changes only its repo_path to this checkout. With input, it permits the complete selected
replacement. Preview shows the difference. Matching config and links are preserved. Conflicting
files or links are refused; setup does not overwrite them.

After approval of the exact preview, the user runs the matching command with `--apply`:

```bash
"$repo/bin/setup" --apply --trust none
```

`--trust none` is the default. Config and skill links do not grant trust. Trust selections are
`none`, `pi`, `claude`, or `both`. Preview and apply must use the approved selection and config:

```bash
"$repo/bin/setup" --dry-run --trust pi
"$repo/bin/setup" --apply --trust pi
"$repo/bin/setup" --dry-run --trust claude
"$repo/bin/setup" --apply --trust claude --claude-writers-stopped
"$repo/bin/setup" --dry-run --trust both
"$repo/bin/setup" --apply --trust both --claude-writers-stopped
```

Before either Claude apply example, stop all Claude config writers. The flag declares that
condition; it does not enforce it. A source comparison cannot prevent an external writer after
the final check. Never run an apply example without its separate user approval.

Pi trust supports filesystem-verified managed Pi 1.2.0 and 1.3.0 installations
with proper-lockfile 4.1.2 only. Native stale/update intervals are 10/5 seconds. Setup holds an empty native lock
with a separate private ownership sidecar. A two-second monotonic and wall-clock cap, inode,
sidecar, and physical parent checks protect the transaction. There is no steal or heartbeat.
Uncertain locks and evidence stay for human inspection. These checks are not a hard real-time
guarantee or protection against all external malicious writes. Parent-fd atomic replacement
prevents a directory replacement from redirecting the write. See [setup details](docs/protocol.md#126-binsetup).

Saved denied children stay denied and appear as blocked roots. A denied selected root is a
conflict. Unrelated trust entries remain unchanged. Do not remove denies or enable always-trust.
Do not trust all Documents or Documents/test. A specific smoke-test fixture needs separate
approval. Agent directory overrides (`PI_CODING_AGENT_DIR`, `PI_PACKAGE_DIR`,
`CLAUDE_CONFIG_DIR`) are unsupported, even when empty.

## Skill discovery and roles

Setup installs `"$HOME/.agents/skills/ask-dispatcher"` pointing to this checkout's
`"skills/ask-dispatcher"`. Pi 1.2.0 and 1.3.0 discover this shared location directly. There is no
duplicate pi link. `"$HOME/.claude/skills/ask-dispatcher"` points to that shared link. Actual model skill
loading needs a separately approved live check; an installed link alone does not prove it.

`roles/review.md` covers reviews, diffs, and changes. `roles/explore.md` covers exploration,
explanation, and investigation. Each starts with capacity one. Config can select pi or Claude
per role. An explicit invalid role fails without fallback. Without a hint, the dispatcher uses
task meaning and valid capabilities; lexical order breaks ties. Workers cannot delegate.

## Readiness before use

A valid config and an installed skill do not prove that a dispatcher is live or that a model loads
the skill. Use one canonical `HERDR_DISPATCHER_CONFIG` path for every requester, dispatcher,
worker, and helper.

All saved state lives under `<repo_path>/runs`. Two config files with the same `repo_path` share
that state. Saved records also store their canonical `config_path`. If a saved path differs from
the active config, or the registry reports ownership conflicts, quarantine, or uncertainty, stop.
Do not switch configs to adopt those records. Do not copy or delete them to clear the conflict.
Resolve the records from their saved ownership evidence and the protocol.

After approved setup and separate live-operation approval, run a bounded, read-only inventory:

```bash
"$repo/bin/registry" --timeout-ms 30000
```

This command contacts the local Herdr server and checks live inventory. It does not start agents
or send prompts. Check its exit status and JSON envelope. Review `config_path`, `roles`, saved
records, `issues`, queued runs, pending notices, and human-attention flags. A saved `ready` or
`idle` value does not prove current live identity. Resolve mismatches, quarantine, and uncertain
state before routing work. The current adapter is verified for the Herdr version listed under
Requirements. A matching protocol number alone does not prove support for a different Herdr version.

## Submit after setup and live approval

Use the ask-dispatcher skill from a requester inside local herdr. The requester needs
`HERDR_ENV=1` and a nonempty inherited `HERDR_PANE_ID`. Prepare a regular body file with nonempty
`## Task` and `## Expected output` sections. Use a physical project cwd. The following commands
show the helper sequence; check each exit status and JSON envelope before continuing. Select an
existing private output directory. Do not repeat new-run to retry a bell.

```bash
umask 077
export HERDR_DISPATCHER_CONFIG="/absolute/config.json"
repo=$(jq -er '.repo_path' "$HERDR_DISPATCHER_CONFIG")
private="/absolute/private-output"
"$repo/bin/new-run" --cwd "/absolute/project" --role review --body-file "/absolute/request-body.md" --timeout-ms 30000 > "$private/new-run.json"
run_id=$(jq -er '.result.run_id' "$private/new-run.json")
"$repo/bin/spawn" dispatcher --timeout-ms 30000 > "$private/dispatcher.json"
expected=$(jq -ce '.result.identity' "$private/dispatcher.json")
"$repo/bin/ring" dispatcher "NEW $run_id" --expected-session "$expected" --timeout-ms 30000
```

Save the returned run ID, absolute paths, config, and requester occupant. Input acceptance proves
observed activity, not completion. Continue other work. Do not poll or add a watcher.

## Lifecycle, notices, and recovery

Runs move from new to dispatched, done, and relayed, or failed. One assignment reserves worker
capacity until verified release. A valid report survives worker exit and requester loss. Report
publication alone does not release a still-working worker. The same settled worker can be reused;
its first settled result observation starts idle TTL, independent of relay. Later scans do not
reset TTL. Expiry is checked only on an event or manual reconcile; there is no timer or watcher.
Only verified owned settled workers can be closed. Failed workers are not reused.

Reports, requests, failed statuses, retired names, and launch journals remain. There is no
automatic run deletion. Temporary reports are not completion. Uncertain input, startup, identity,
or lock evidence needs inspection; it does not permit a replacement job. A late valid report
on a failed run stays as evidence and does not reverse failure.

A requester receives `RESULT ID ABS_RESULT_PATH` or `FAILED ID ABS_STATUS_PATH`. A busy requester
can defer relay. Before reading the path, validate the matching notice with the saved config:

```bash
"$repo/bin/run-state" check-notice "$run_id" RESULT "$repo/runs/$run_id/result.md" --timeout-ms 30000
"$repo/bin/run-state" check-notice "$run_id" FAILED "$repo/runs/$run_id/status" --timeout-ms 30000
```

Run only the check for the received notice. Read only the validated file as data. Failure notices
retain the saved reason. Handle a repeated validated notice once in the current conversation;
this is not durable deduplication across context loss. A missing requester does not destroy a
valid report. Read-only recovery and the user-requested bounded manual bell are:

```bash
"$repo/bin/registry" --timeout-ms 30000
"$repo/bin/run-state" get run "$run_id" --timeout-ms 30000
"$repo/bin/ring" dispatcher 'RECONCILE' --timeout-ms 30000
```

Only this exact manual RECONCILE bell may omit expected-session. Inspect original publication
and launch evidence before retry. Never blindly resubmit, close by name, or delete a lock to
force progress. See [crash recovery](docs/protocol.md#14-crash-walkthroughs-and-required-next-actions).

## Backups and safe rollback

Apply uses umask 077. New files and backups are private. Existing destination permissions remain.
The JSON response lists byte-exact backups and applied changes. File writes are atomic per file,
not one global transaction. Inspect applied changes and evidence on every failure; an earlier
step can have succeeded before a later conflict. Exit 5 or an interrupted response requires
inspection, not automatic rollback or another apply. Retained staging, sidecar, or native-lock
paths are evidence. An incomplete backup is retained evidence, not a valid rollback backup.

For rollback, stop runtime work and all affected store writers first. Get explicit user approval
for each path. Compare the current destination, its reported backup, permissions, and any later
changes locally without exposing secrets. Restore only the selected known backup after that
comparison; do not overwrite newer decisions blindly. Remove a skill link only after its exact
target matches the approved setup link. Remove a newly created config only after confirming it
has no later changes or active users. Keep uncertain locks and journals until ownership and
commit state are resolved. Do not use blanket recursive removal. Setup has no rollback command.

## Personal identity and checks

These separately approved per-clone commands preserve the personal hook and identity:

```bash
git config core.hooksPath '.githooks'
git config user.email 'fjrevoredo@gmail.com'
git config user.name 'Francisco J. Revoredo'
git var GIT_AUTHOR_IDENT
```

Before each separately approved commit, require effective author
`Francisco J. Revoredo <fjrevoredo@gmail.com>`. Stop otherwise. Never bypass the hook.
Setup grants no staging, commit, push, or live-operation permission.

Offline checks use fake herdr and isolated HOME, not installed agents:

```bash
bash "tests/run.sh" setup
bash "tests/lint.sh"
```

See [test limits](tests/README.md). Offline checks cannot prove live skill discovery, model
behavior, or trust-dialog handling. The [protocol](docs/protocol.md) defines authoritative schemas.
