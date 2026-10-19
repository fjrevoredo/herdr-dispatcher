# Exploration Output: herdr dispatcher

> Artifact type:
> [x] Proposal — a harness-agnostic "dispatcher" agent for herdr (description only)
> [x] Decision Record — direction decisions taken with the user
>
> This artifact contains NO implementation code. Only prose, diagrams, tables, and references.
> Status: exploration complete (2026-10-13). Next: an implementation plan in a new session.

## How to use this document (for the planning session)

1. Read **Summary**, then **Decisions**, then **Proposed Design**.
2. **Spike Results** hold the evidence behind the protocol rules. Do not repeat the spikes unless
   herdr or a harness version changes.
3. **Open for the Planning Session** lists the implementation-level questions that are still open.
4. **Session State** lists what exists on disk now, including side effects outside this repo.

## Summary

A personal repo (`github.com/fjrevoredo/herdr-dispatcher`) with a minimal, harness-agnostic setup.
Any coding agent started in this repo (pi, Claude Code, …) reads `AGENTS.md` and becomes the
**dispatcher** of the current herdr session:

- Other coding agents send it requests (for example "review this diff") through a shared client skill.
- The dispatcher picks a **role** (`review`, `explore`), reuses an idle worker of that role or spawns
  a new one in a dedicated `dispatch` workspace, and sends it a brief.
- The worker writes its result to a file and rings the dispatcher. The dispatcher relays the result
  path to the requester.
- The dispatcher is **event-driven**: it reacts to short doorbell messages, never blocks on a job,
  and rebuilds its whole view from files plus `herdr agent list` on every turn.

## Context

- **Why this exploration started**: the user wants a "herdr dispatcher" repo. The dispatcher must
  own the workflow (know which agents exist, what they do, where they are) but its own work must stay
  minimal: read definitions and status, dispatch, collect answers.
- **Date**: 2026-10-13
- **Sources consulted**:
  - Local herdr CLI 0.9.3: `herdr --help`, `herdr --skill`, `herdr agent|pane|api|integration --help`.
  - Live session state: `herdr agent list`, `herdr pane list`, `herdr api snapshot`,
    `herdr integration status` (state reporters installed for pi, claude, copilot, opencode).
  - Prior art: <https://github.com/cgint/pi-subagent-herdr> (master), cloned to `/tmp/pi-subagent-herdr`:
    `README.md`, `PROJECT_OVERVIEW.md`, `docs/findings.md`, `docs/20261006-idea-role-based-subagents.md`,
    `docs/multiplexer_compatibility.md`, `skills/subagent-handoff/SKILL.md`, `skills/subagent-firstmate/SKILL.md`.
  - `~/Documents/private/pi-extensions` (`AGENTS.md` § Setup, `.githooks/pre-commit`, local git config)
    as the pattern for the personal git identity.
  - `~/.claude.json` (`projects.<path>.hasTrustDialogAccepted`) for Claude folder trust.
  - Live spikes in throwaway herdr panes (see **Spike Results**).
  - The user (questions and answers below).

## Questions Asked and Answers

| # | Question | Answer |
|---|---|---|
| 1 | How do results get back to the requester? | **Event-driven relay** (recommended option). |
| 2 | Which agents can receive work? | **Managed pool only** (recommended option). |
| 3 | How much non-LLM tooling? | **Markdown + tiny POSIX scripts** (recommended option). |
| 4 | How do other agents learn the protocol? | **Shared client skill** (recommended option). |
| 5 | Where does `runs/` live? | User: a `runs/` subfolder in this repo, contents ignored by git. |
| 6 | How to avoid the Claude folder trust dialog? | User: a setup phase pre-trusts parent folders. Follow-up answer: a **configurable list** of folders (recommended option). |
| 7 | Where do new workers open? | **Dedicated `dispatch` workspace**, one tab per worker (recommended option). |
| 8 | What if no dispatcher is running? | User overrode the recommendation ("fail with a clear message"): the client skill **auto-starts** the dispatcher. |
| 9 | First roles? | **`review` + `explore`**, both readonly (recommended option). |
| 10 | What happens to a worker after its job? | User: keep it alive for a fixed idle period (example 15 minutes) for reuse, then close it; only if this is easy, otherwise always close. Assessed as easy (see Decision 7). |
| 11 | How long may the dispatcher wait for a busy requester? | **30 seconds**, then retry later (recommended option). |
| 12 | Git identity? | User: the repo is personal; commit only with the personal identity, set up the same way as `pi-extensions`; also add an identity check to the pre-commit hook. |

## Assumptions (challenge these)

- All participants (requesters, dispatcher, workers) run inside the same herdr server and can call
  the `herdr` CLI (`HERDR_ENV=1`). Cross-machine (`herdr --machine`) is out of scope.
- Every harness used can run shell commands and read/write files. This is the only "API" we rely on.
- There is exactly one dispatcher per herdr session, with the fixed live agent name `dispatcher`.
- A herdr state reporter is installed for every harness kind we spawn (check with
  `herdr integration status`). Without it, lifecycle state is screen-detected only and weaker.
- `bash` and `jq` are available on the machine.

## Findings

### herdr already provides every primitive the dispatcher needs

| Need | herdr primitive | Notes |
|---|---|---|
| Discover agents and status | `herdr agent list` | Per agent: `pane_id`, `agent` kind, `agent_status` (`idle/working/blocked/done/unknown`), `cwd`, `name`, `workspace_id`, `state_change_seq`. |
| Stable handle for an agent | `herdr agent start <name>` / `herdr agent rename` | Names match `[a-z][a-z0-9_-]{0,31}`, are unique among live agents, and are **cleared when the agent exits**. |
| Create a place for a worker | `herdr workspace create`, `herdr tab create`, `herdr pane split` | Creation responses return the new IDs as JSON (`.result.workspace`, `.result.tab`, `.result.root_pane`, `.result.pane`). |
| Start a worker | `herdr agent start <name> --kind <kind> --pane <id> [--timeout ms] [-- args]` | 24 kinds supported (pi, claude, codex, opencode, …). Returns only when the agent is ready for input. Pane must be at an interactive shell prompt. |
| Send work | `herdr agent prompt <target> "<text>" [--wait] [--until state] [--timeout ms]` | Rejects `blocked` targets with `agent_blocked`. `--wait` tracks lifecycle state, not a specific turn. |
| Wait / read | `herdr agent wait <target> [--until state]…`, `herdr agent read --source recent-unwrapped` | |
| Close | `herdr pane close <pane_id>` | `pane_not_found` means already gone. |
| Alert the human | `herdr notification show <title> --body …` | For `blocked` workers and failures. |

Consequence: the dispatcher needs no extension and no harness-specific API. Any agent that can run
bash can be the dispatcher. This is what makes "harness agnostic" realistic.

### Pane metadata is display-only

`herdr pane report-metadata` exists, but its tokens do not appear in `herdr api snapshot`. It cannot
serve as a readable registry. The role of a pool agent must come from its **name** (`<role>-<n>`).

### Claude folder trust is inherited from parent folders

Claude Code stores trust per path in `~/.claude.json` (`projects.<path>.hasTrustDialogAccepted`).
A Claude worker started two folders below a trusted folder showed no dialog. Claude still wrote an
entry for the subfolder with `hasTrustDialogAccepted=false`, so the check walks up to the parent.
pi showed no trust dialog.

### Skill installation pattern on this machine

`~/.claude/skills/*` are symlinks into `~/.agents/skills/`. A client skill kept in this repo can be
linked into `~/.agents/skills/` and from there into each harness's skills folder.

### Lessons from pi-subagent-herdr (taken with a grain of salt)

Adopt:

- **Deliver the task with `agent prompt` after `agent start` reports ready**, never as a launch
  argument. They observed that pi silently loses positional briefs in some modes (`docs/findings.md` §3.1).
- **A terminal state is not task completion.** `idle`/`done` only means "ready for input". The
  **result file on disk is the deliverable**; terminal output is a status peek (`docs/findings.md` §4, items 3, 4, 12).
- **No blind resend** after `timeout` or `agent_prompt_stalled`. Inspect with `agent get` / `agent read` first.
- **`esc` interrupts a turn; `ctrl+d` kills the agent** (and kills a bare shell, which can close the pane).
- `agent read` with history fails with `agent_not_idle` while the agent works. Use `--source visible` then.
- Their **handoff brief** and **work report** templates (`skills/subagent-handoff/SKILL.md`) are a good
  base for role brief templates and the `result.md` shape.

Do not adopt:

- The ~3k-line pi-only TypeScript extension. It solves supervision for one harness.
- Role injection via `--append-system-prompt`. It is pi-only, so not harness agnostic. Their own doc
  lists this as an open agent-neutrality problem. We inject role instructions through the first prompt.
- Their readonly mode (a pi tool allowlist). Not portable; see the readonly risk below.
- The heavy evidence/acceptance process and the "Firstmate" persona documents.

## Options Compared

### Reply model

| Option | How it works | Pros | Cons | Fit |
|---|---|---|---|---|
| **A. Event-driven relay** (chosen) | Worker writes `result.md`, rings dispatcher with `DONE <id>`. Dispatcher relays to requester. | Dispatcher stays responsive; owns all state; minimal turns. | Depends on doorbells; a silent worker is only found on the next dispatcher turn. | Best |
| B. Dispatcher blocks | Dispatcher runs `agent prompt --wait` per job. | Simplest. | Serializes all requests; dispatcher is useless while one job runs. | Poor |
| C. Worker replies directly | Dispatcher routes only; worker prompts the requester. | Fewest hops. | Dispatcher loses track of completion; no ownership. | Poor |

### Which agents receive work

| Option | Pros | Cons | Fit |
|---|---|---|---|
| **Managed pool only** (chosen) | Never interferes with the user's own sessions; role is known from the name. | Spawn cost for the first request of each role. | Best |
| Managed + opt-in panes | Reuse of existing context. | Needs a registration step; still risky. | Later, if needed |
| Any matching agent | No spawn cost. | Can hijack the user's active work. | Rejected |

### Implementation shape

| Option | Pros | Cons | Fit |
|---|---|---|---|
| **Markdown + tiny POSIX scripts** (chosen) | Deterministic steps (ids, locks, registry view, spawn, ring) are reliable and cheap in every harness. | Requires `bash` + `jq`. | Best |
| Markdown only | Zero code. | The LLM re-derives JSON parsing, locking and ID handling every turn; error-prone and token-expensive. | Fallback |

### Worker reuse

| Option | Pros | Cons | Fit |
|---|---|---|---|
| Always close after the job | Clean context; simplest. | Spawn cost (~5–10 s) every job. | Fallback |
| Per-role reuse flag, default close | Flexible. | Reused workers grow context without limit. | Superseded |
| **Idle TTL, default 15 min** (chosen) | Reuses warm workers while their prompt cache is likely valid; closes them before a cold, expensive reuse. | Reused worker carries the previous job's context. | Best |

## Spike Results (2026-10-13)

Setup: herdr 0.9.3, throwaway panes next to the exploration pane, cwd `~/Documents/test/herdr-spike`.
Agents: `spike-pi` (pi, gpt-6-luna) and `spike-claude` (Claude Code, Sonnet 5.5, auto mode).
All spike panes were closed afterwards.

### Spike 1: doorbell into a busy agent

| # | Test | pi | Claude Code |
|---|---|---|---|
| 1 | Doorbell during a text-only turn (no tools) | Accepted (`agent_prompted`). Handled after the turn: `ACK-42`. | Same: queued, `ACK-42` after the turn. |
| 2 | Two doorbells during a turn with tool calls; task said "handle other messages only after SECOND-DONE" | **Injected mid-turn as steering** (one after each tool call). The model chose to ignore them. Turn ended with `SECOND-DONE` only. **Both doorbells lost.** | **Queued.** After the turn: `SECOND-DONE`, `ACK-43`, `ACK-44` in one reply. |
| 3 | Sender first runs `agent wait <target> --until idle --until done`, then `agent prompt` (two concurrent senders) | Both doorbells handled after the task turn (`ACK-46`, then `ACK-45`). Order not kept: both senders woke at once; the second bell landed while the first was being handled. | Not tested (already behaves as a queue). |

Caveat: the loss in test 2 was provoked by the task text ("handle other messages only after…").
Without that wording pi may answer a steering message, but it then changes the running task.
Either way, a mid-turn doorbell to pi is unsafe.

### Spike 2: Claude trust inheritance

A Claude worker started in `~/Documents/test/herdr-spike/child-a/deeper` (two levels below the
trusted `~/Documents/test/herdr-spike`) showed no trust dialog. See Findings.

### Incidental findings

- `agent start` directly after `pane split` failed with `agent_pane_busy`: the new shell (nushell)
  was not at its prompt yet. A retry seconds later succeeded. Spawning needs a short retry loop.
- Claude Code blocks at its **folder trust dialog** in an untrusted cwd (`agent start` returns
  `agent_not_ready`). Answering it needs a human decision.
- `herdr agent prompt` returns `agent_prompted` in all cases. It never signals that the text was
  steered or queued. **Delivery receipt is not proof of handling.**

### Consequences for the protocol

1. **A doorbell is a wake-up hint, never the message itself.** All content lives in `runs/<id>/`.
   On each turn the dispatcher reconciles from files (`runs/*/status`, `result.md` presence), not
   from the doorbell text. A lost or reordered bell then costs latency, not correctness.
2. **Ring only an agent that is not working.** The `ring` helper waits for `idle`/`done` before
   `agent prompt`. This turns pi steering into a normal new turn and is harness agnostic.
3. **Serialize senders.** Concurrent ringers race (test 3). The `ring` helper takes a per-target lock
   (for example an `mkdir` lock under `runs/.locks/`), waits for not-working, prompts with
   `--wait --until working`, then releases the lock.
4. **Requesters are agents too.** The `RESULT` relay to a busy requester has the same risk, so the
   dispatcher uses the same `ring` helper with a 30-second limit (Decision 8).
5. **Spawn helper** retries `agent start` on `agent_pane_busy` and reports `agent_not_ready` (blocked
   at startup) to the human instead of answering dialogs itself.

## Decisions

1. **Reply model**: event-driven relay. The dispatcher never blocks on a job.
2. **Location of `runs/`**: a `runs/` subfolder in this repo. Git ignores its contents; a `.gitkeep`
   keeps the folder. Requesters and workers in other repos need the absolute path to this repo;
   setup records it where the client skill can read it.
3. **Worker placement**: one dedicated `dispatch` workspace; each worker gets its own tab.
4. **Dispatcher not running**: the client skill **auto-starts** the dispatcher in the `dispatch`
   workspace. The harness kind for the dispatcher is a setup value. herdr live-agent names are
   unique, so `agent start dispatcher` acts as a natural lock: if two requesters race, the second
   start fails and that requester uses the existing dispatcher.
5. **First roles**: `review` and `explore`, both readonly. Editing roles (and the worktree
   merge-back question) are out of scope for v1.
6. **Folder trust**: a **setup phase** pre-trusts a **configurable list** of parent folders for the
   worker harnesses (for this machine: `~/Documents/smec-dev`, `~/Documents/private`). Setup changes
   global harness config, so the user runs it explicitly; the dispatcher loop must never run it.
7. **Worker reuse**: **idle TTL**, default 15 minutes (a setup value, optionally per role). No timer
   is needed: the dispatcher records `idle_since` per worker when it relays that worker's result. On a
   new job it reuses an idle worker of that role only if `idle_since` is younger than the TTL;
   otherwise it closes that worker and spawns a fresh one. Each dispatcher turn also closes workers
   past the TTL. An idle pane costs no tokens, so lingering between dispatcher turns is harmless.
   Fallback if this proves complex: always close after the job.
8. **Relay wait**: `ring` waits up to **30 seconds** for a busy requester. After that, the run stays
   `done` and the relay is retried on a later dispatcher turn.
9. **Managed pool only**: the dispatcher sends work only to workers it spawned, named `<role>-<n>`.
10. **Implementation shape**: Markdown (`AGENTS.md`, roles, client skill) plus tiny POSIX scripts
    (`bash` + `jq`) for deterministic steps.
11. **Git identity**: this repo is personal. Commits must use only
    `Francisco J. Revoredo <fjrevoredo@gmail.com>`. Same pattern as `~/Documents/private/pi-extensions`
    (its `AGENTS.md` § Setup):
    - v1 `AGENTS.md` gets a **Setup** section with the per-clone commands
      `git config core.hooksPath .githooks`, `git config user.email fjrevoredo@gmail.com`,
      `git config user.name "Francisco J. Revoredo"`, and the reason: local config is not committed,
      and the global `~/.gitconfig` resolves to the work identity, so a fresh clone or worktree
      silently commits with the wrong author.
    - Agents verify with **`git var GIT_AUTHOR_IDENT`** (what `git commit` will record), not
      `git config user.email`, before each commit, and stop if it is not the personal address.
    - `.githooks/pre-commit` **rejects a commit whose author is not `fjrevoredo@gmail.com`** (beyond
      `pi-extensions`, whose hook only runs checks). The hook works only in clones where
      `core.hooksPath` is set, so the `AGENTS.md` rule stays necessary. `git commit --no-verify`
      bypasses it.
    - Done already: see **Session State**.

## Proposed Design

### Overview

```
 requester agent (any pane)                  herdr-dispatcher (dispatch workspace)
 ┌──────────────┐  1. write request file    ┌────────────────────────────┐
 │ claude / pi  │ ────────────────────────▶ │ runs/<id>/request.md       │
 │ (client      │  2. ring dispatcher       │                            │
 │  skill)      │     "NEW <id>"            │  DISPATCHER (any harness)  │
 └──────▲───────┘ ────────────────────────▶ │  reads: roles/*.md         │
        │         (auto-start if missing)   │         herdr agent list   │
        │                                   │         runs/*             │
        │ 6. ring requester                 └──────┬────────────▲────────┘
        │ "RESULT <id> <path>"                     │            │ 5. ring dispatcher
        │                          3. route: reuse │            │ "DONE <id>"
        │                             or spawn     ▼            │
        │                                   ┌────────────────────────────┐
        └────────────────────────────────── │ pool worker "review-1"     │
                                            │ (own tab, cwd = requester) │
                                            │ 4. writes                  │
                                            │ runs/<id>/result.md        │
                                            └────────────────────────────┘

 Every arrow labelled "ring" goes through bin/ring: per-target lock → wait until the
 target is idle/done → agent prompt --wait --until working → unlock.
```

### Repository layout (description, not final)

| Path | Purpose |
|---|---|
| `AGENTS.md` (+ `CLAUDE.md` symlink; other harness entry files as needed) | The dispatcher role: the loop, the rules, the protocol, and the **Setup** section (git identity, hook, setup script). Any harness opened here becomes the dispatcher. |
| `roles/review.md`, `roles/explore.md` | One role each. Frontmatter: `name`, `kind` (worker harness), `capabilities` / keywords, `max_instances`, `idle_ttl` (optional override). Body: role instructions and brief template. |
| `runs/` | Work state. Contents git-ignored; `.gitkeep` tracked. |
| `runs/<id>/request.md` | Written by the requester: `from_pane`, `cwd`, optional `role` hint, task, expected output. |
| `runs/<id>/status` | State (`new`, `dispatched`, `done`, `relayed`, `failed`) and the assigned worker. |
| `runs/<id>/result.md` | Written by the worker. Compact work-report shape. |
| `runs/.workers/<name>` | Per-worker record: role, pane id, `idle_since`. Needed for the idle TTL. |
| `runs/.locks/` | Per-target `ring` locks. |
| `bin/` | Tiny POSIX helpers: new run id, registry view (roles × live pool agents × runs), spawn worker, `ring`, setup. |
| `skills/ask-dispatcher/` | The client skill. Installed by symlink into `~/.agents/skills/` (and from there into each harness). |
| `.githooks/pre-commit` | Identity check (exists already). |
| `.gitignore` | Ignores `runs/*` except `.gitkeep`, and any local config file. |

### Registry

The registry is derived, not stored in a database:

- **Static**: `roles/*.md`.
- **Live**: `herdr agent list`, filtered to names that match `<role>-<n>` for a known role.
- **Work**: `runs/*/status` and `runs/.workers/*`.

If herdr restarts, pool names disappear and the dispatcher sees an empty pool, which is correct.
Stale `runs/.workers/*` records whose agent is gone are deleted on the next dispatcher turn.

### Dispatcher loop (one turn per doorbell)

Every turn starts with a **reconcile** step, independent of the doorbell text (doorbells can be lost):

- **New runs** (`status = new`): read `request.md` → choose a role (hint first, then capability
  match; if nothing matches, mark `failed` and tell the requester) → reuse an idle worker of that
  role if `idle_since` is younger than the TTL, else close it and spawn a new one if under
  `max_instances` (otherwise leave the run `new` as queued) → send the brief, which tells the worker
  to write `result.md` and then run `bin/ring dispatcher "DONE <id>"` → set `dispatched`.
- **Finished runs** (`dispatched` and `result.md` exists): set `done` → `bin/ring <from_pane>
  "RESULT <id> <absolute path>"` (30 s limit) → on success set `relayed` and record `idle_since`
  for the worker; on timeout keep `done` and retry on a later turn.
- **Stuck runs** (`dispatched`, no `result.md`): `blocked` worker → notify the human. Worker
  `idle`/`done` → read its output, nudge once, then mark `failed`. Worker gone → mark `failed` and
  tell the requester.
- **Idle workers past the TTL**: close the pane, delete the record.

### Spawning a worker

1. Make sure the `dispatch` workspace exists (create it on first use).
2. Create a tab in it for the worker, with `cwd` = the requester's cwd.
3. `herdr agent start <role>-<n> --kind <kind> --pane <id>`, retrying on `agent_pane_busy`.
   On `agent_not_ready` (for example a trust dialog), notify the human and mark the run `failed`.
4. Send the role instructions plus the brief through `herdr agent prompt` (harness-agnostic role
   injection; never as a launch argument).
5. Write `runs/.workers/<name>`.

### Client skill (requester side)

1. Find the dispatcher repo path (recorded by setup).
2. Create `runs/<id>/request.md` (with `from_pane=$HERDR_PANE_ID` and `cwd`).
3. If no live agent named `dispatcher` exists, auto-start it in the `dispatch` workspace with the
   configured harness kind and the dispatcher repo as cwd. If the start fails because the name is
   taken, another requester won the race; continue.
4. `bin/ring dispatcher "NEW <id>"`.
5. Tell its agent: continue working; a later message `RESULT <id> <path>` delivers the result file.

### Setup (run once by the user)

- Per-clone git config (identity and hook), documented in `AGENTS.md` § Setup.
- Pre-trust the configured parent folders for each worker harness that has a trust dialog.
- Record: the repo path, the dispatcher harness kind, the default idle TTL, the trust roots.
- Install the client skill symlinks.
- Check `herdr integration status` for each harness kind used.

## Risks & Unknowns

- **Readonly is only an instruction.** The `review` and `explore` roles are "readonly" by brief
  text only. A harness-agnostic setup cannot enforce a tool allowlist the same way in every harness
  (pi-subagent-herdr's allowlist is pi-only). A worker could still edit the requester's repo.
  Mitigation options for the plan: per-harness launch args in the role file, or accept the risk for v1.
- **Untrusted cwd.** Workers run in the requester's cwd. If that cwd is outside the configured trust
  roots, a Claude worker blocks at the trust dialog; the dispatcher reports it to the human.
- **Silent workers.** If a worker never rings `DONE`, the dispatcher notices only on its next turn.
  A true watchdog needs a long-running process, which an LLM dispatcher cannot be. Accept for v1,
  or later add an optional `bin/` watcher that rings the dispatcher on worker state changes.
- **`ring` blocks its caller.** A worker's final `ring` waits until the dispatcher is not working;
  the dispatcher's `RESULT` ring waits up to 30 s for the requester. Dispatcher turns must stay short.
- **Auto-start side effects.** The client skill creates a workspace and starts an agent without a
  human in the loop. A wrong harness kind or path in the setup values spawns a broken dispatcher.
- **Reused worker context.** A reused worker carries the previous job's context (accepted with the TTL).
- **Edit conflicts.** Not relevant in v1 (readonly roles). Editing roles will need `herdr worktree`
  and a merge-back design.
- **Context growth of the dispatcher.** Mitigated because all state is on disk: the dispatcher can be
  restarted at any time and rebuild its view from files + `agent list`.
- **Prompt injection between agents.** Requests are free text from other agents; the dispatcher must
  only route, never execute request content itself.
- **Requester gone.** If the requester pane closed, the result stays in `runs/<id>/` and the
  dispatcher notifies the human.
- **Version drift.** Spike results are for herdr 0.9.3 and the pi / Claude Code versions of
  2026-10-13. Repeat spike 1 after an upgrade that changes input handling.

## Open for the Planning Session

These are implementation-level questions. They do not change the direction.

1. **Local config**: format and location of the setup values (repo path, dispatcher kind, TTL, trust
   roots). For example a git-ignored file in the repo plus an environment variable or a fixed file
   under `~` so the client skill can find the repo.
2. **Default harness kinds**: which kind runs the dispatcher, and which kind each role uses.
3. **Run id format**: for example a timestamp plus a short random suffix.
4. **Readonly enforcement**: accept instruction-only for v1, or add per-harness launch args.
5. **Trust setup per harness**: Claude is known (`~/.claude.json`). Check other harnesses that will be
   used as workers (for example codex) for a similar dialog.
6. **Client skill installation**: exact symlink targets for each harness (`~/.agents/skills/`,
   `~/.claude/skills/`, pi's skills path).
7. **`max_instances` default** per role.
8. **Verification approach** for v1: an end-to-end smoke test in throwaway panes (requester → dispatcher →
   worker → result relayed), like the spikes.

## Session State (end of 2026-10-13)

In this repo (nothing committed yet; branch `master` has no commits):

- `docs/explorations/herdr-dispatcher.md` — this document (untracked).
- `.githooks/pre-commit` — identity check, executable, tested (personal author passes, work author
  is rejected), `shellcheck` clean (untracked). Its error message points to `AGENTS.md`, which v1 adds.
- Local `.git/config`: `user.name=Francisco J. Revoredo`, `user.email=fjrevoredo@gmail.com`,
  `core.hooksPath=.githooks`. Remote: `https://github.com/fjrevoredo/herdr-dispatcher`.

Outside this repo (side effects of the spikes):

- `~/Documents/test/herdr-spike/` (with `child-a/deeper/`) — empty scratch folders. Safe to delete.
- `~/.claude.json` — new trust entries: `~/Documents/test/herdr-spike` (trusted, approved by the
  user) and `.../child-a/deeper` (written by Claude as `false`).
- `/tmp/pi-subagent-herdr` — clone of the prior-art repo.
- All spike panes are closed; no spike agents are running.

## Recommended Direction

Build a small repo where `AGENTS.md` turns any harness into an event-driven router. Role definitions
are Markdown files, live state comes from the herdr CLI, and all work state lives in `runs/` files.
The dispatcher reconciles from files on every turn, reacts to short doorbells (`NEW`, `DONE`), never
blocks on a job, and only sends work to its own named pool. All doorbells go through one `ring`
helper that waits for the target to be idle and serializes senders. This keeps the dispatcher
minimal, restartable, and free of harness-specific code.

## Next Steps

- [x] Run the doorbell-while-busy spike and record the result.
- [x] Verify Claude trust inheritance.
- [x] Decide the direction-level open points.
- [x] Set up the personal git identity and the identity pre-commit hook.
- [ ] New session: create an implementation plan for v1 (resolve **Open for the Planning Session** first).
- [ ] Implement v1: `AGENTS.md` (with Setup), roles `review` + `explore`, `bin/` helpers (`ring`,
  spawn, registry view, new run id, setup), `.gitignore`, client skill with auto-start.
- [ ] End-to-end smoke test in throwaway panes.
- [ ] First commit (check `git var GIT_AUTHOR_IDENT` first).
