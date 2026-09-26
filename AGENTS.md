# AGENTS.md — AI Programming Guidance

This file governs how AI coding agents operate in this repository. It is a
synthesis of five proven, openly published approaches, each contributing a
distinct, complementary discipline:

| Source | What it contributes | Core idea |
| --- | --- | --- |
| [OthmanAdi/planning-with-files](https://github.com/OthmanAdi/planning-with-files) | **State persistence** | Treat the filesystem as durable memory; plan in files so goals survive `/clear`, crashes, and context compaction. |
| [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) | **Output discipline** | Write the minimum that works; reuse before you write; never cut safety (§2). |
| [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) | **Architecture & verification** | Build everything as a swappable plugin ("capability seam"); verify before you declare done; record decisions as ADRs. |
| [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) | **Reply shaping** | Lead with the next action; number multi-step work; end with one concrete next step; no preamble, no closer (§5). |
| [PrimeIntellect-ai/prime-agent](https://github.com/PrimeIntellect-ai/prime-agent) | **Durable harness & safety** | Harness state outlives the chat; refine it with small evidence-backed updates; hard git safety when agents share a worktree (§6). |

These are not in tension. A minimal solution that is planned on disk, composed
from plugins, proven by tests, and explained in a reply the reader can act on
immediately is the target state for every task.

---

## 0. Core Operating Principles

Hold these eight rules in mind on every turn. They are elaborated in the sections below.

1. **Disk is memory; context is RAM.** Anything important is written to a file, not only kept in the conversation.
2. **Plan before you build.** No task of 3+ steps or 5+ tool calls starts without a plan file.
3. **Write the minimum that works.** Reuse before you write; the best code is the code you never shipped.
4. **Compose with plugins, not edits.** Behavior changes by swapping a provider, not by rewriting call sites.
5. **Verify before you claim done.** Run the repo's gates (§4.1); never repeat a failure you already logged.
6. **Safety is non-negotiable.** Trust-boundary validation, data-loss handling, security, and accessibility are never on the chopping block.
7. **Shape replies to be acted on.** Lead with the action, number the steps, end with one concrete next step — never bury the answer (§5).
8. **Harness state outlives the chat.** Improve durable guidance only with small, evidence-backed updates, and stay safe when other agents share the worktree (§6).

---

## 1. Plan in Files, Not in Context

Adopt the Manus-style context-engineering model from *planning-with-files*:
the **context window is volatile and limited (RAM)**, the **filesystem is
durable and effectively unlimited (disk)**. Persist execution state to files so
a `/clear`, a crash, or a compaction cannot lose the plan.

### 1.1 The 3-file pattern

For any multi-step task, maintain three files **inside `.ai-memory/`** (templates
in `.ai-agents/planning-template.md`). Never in the repo root: the root is product
code (`src/`, `build.sh`, `tests/`).

| File | Purpose |
| --- | --- |
| `.ai-memory/task_plan.md` | Phases, checkboxes, and the resume point after a reset. |
| `.ai-memory/findings.md` | Research, decisions, and things learned along the way. |
| `.ai-memory/progress.md` | A session log: commands run, outputs, test results, errors. |

One task = one plan file. Either keep the three names above, or consolidate into a
single `<phase-slug>.md` (e.g. `p2-runtime-skeleton.md`, `p3-acl.md`) as long as
the three concerns stay distinguishable by heading — the P2 plan is the
consolidated form (`Context` / `已验证的事实` / `关键设计决策` / `分步实施计划` /
`验证方式` / `风险与不确定性`). Do not create `task_plan-2.md`-style variants.

`.ai-memory/` is **working memory, not product**: never `git add` or commit it
(if it shows up staged, unstage it). `.trae/documents/` holds a mirror copy for
external tooling; when the two disagree, `.ai-memory/` wins (§9).

### 1.2 When to create them (ladder)

Stop at the first applicable rung:

1. Task needs 3+ steps or 5+ tool calls? → **create the three files first.**
2. Learned a fact, made a decision, or hit an error? → **append it to `findings.md`** (at least once every ~2 read/search operations).
3. Ran a command or a gate? → **log it in `progress.md`** with its exit status.
4. A phase finished? → **check it off in `task_plan.md`.**
5. Context died (`/clear`, crash, compaction)? → **re-read the plan from disk and resume.**
6. Every phase complete? → **only then is the task done.**

### 1.3 Key rules

- **Create the plan first.** Never start a non-trivial task without `task_plan.md`.
- **The 2-action rule.** After every ~2 read/search/browse operations, save what you learned to `findings.md`.
- **Log ALL errors.** Failed commands go in `progress.md`; they prevent repeating the same mistake.
- **Never repeat failures.** Track each attempt; if an approach failed, mutate the approach before retrying.

### 1.4 Plan recitation and recovery

At the start of each turn that continues existing work, re-read the active plan
file under `.ai-memory/` before choosing the next action. A one-off question with
no plan file needs no recitation. If no plan file exists yet, create one before
the first code change (§1.2).

If the conversation was reset, the plan files on disk are the source of truth —
recover from them without asking the user to restate the goal.

---

## 2. Write the Minimum That Works (Ponytail)

Be the "lazy senior dev": ruthless about avoiding unnecessary code, meticulous
about correctness. Apply the **reuse ladder** *after* you understand the problem,
never instead of understanding it — lazy about the solution, never about reading.

### 2.1 The reuse ladder

Before writing code, stop at the first rung that holds:

1. **Does it need to exist?** — No → skip it (YAGNI).
2. **Already in this codebase?** — Yes → reuse it, don't rewrite.
3. **Stdlib does it?** — Yes → use the standard library.
4. **Native platform feature?** — Yes (e.g. `<input type="date">`, `fetch`) → use it.
5. **Installed dependency?** — Yes → use it; don't reinvent it.
6. **One line?** — Yes → write one line.
7. **Only then** → write the minimum that actually works.

In molly: rung 3 means `core:net` / `core:encoding/json` / `core:os` (Odin has no
HTTP library — that layer is hand-written by design); rung 5 means the OpenWrt
`.so` libraries, and they are reachable **only** through `src/backend/` (§3.2).
Adding a new dependency is an ADR-level decision (§7.1).

### 2.2 Safety is non-negotiable

The ladder compresses *code*, never *correctness*. Never cut:

- **Trust-boundary validation** — sanitize and verify untrusted input.
- **Data-loss handling** — guard destructive operations; confirm before irreversible writes.
- **Security** — no secrets in code, no unsafe eval, no exposed surfaces.
- **Accessibility** — semantic markup, labels, and contrast are part of "working."

### 2.3 The `ponytail:` marker convention

When you deliberately cut a real corner with a known ceiling, mark it inline so
it is greppable and reviewable:

```ts
// ponytail: browser has <input type="date">; skip the flatpickr wrapper
```

Use this only for trivial, bounded simplifications — not as a license to ship
unsafe code. Run a debt review (`grep -rn 'ponytail:' src tests build.sh`)
whenever a task touches a file that carries a marker, and confirm the ceiling
still holds.

Full ladder and marker rules: `.ai-agents/ponytail-ladder.md`.

---

## 3. Build Everything as a Plugin (Capability Seams)

From *deepseek-harness*: **everything is a plugin.** Behavior is composed from
swappable capabilities, not hardcoded decisions. This keeps the runtime closure
tight and makes the system testable and replaceable.

### 3.1 The Capability Seam

A *seam* is a swappable capability defined by three roles:

| Role | Responsibility | Example |
| --- | --- | --- |
| **Service Definition** | Declares the interface (the seam). | `ctx.llm`, `ctx.fs`, `ctx.shell` |
| **Service Provider** | Implements the interface. | `llm-deepseek`, `fs-local`, `fs-sandbox` |
| **Consumer** | Uses the capability, often a tool. | `tool-bash` consuming the shell capability |

Change behavior by swapping a **provider** — e.g. move from a local filesystem to
a sandboxed one — without touching the **consumer** call sites.

### 3.2 The seam in this repo (concrete)

`src/backend/` is molly's one capability seam. New platform support goes there;
do not add an indirection layer elsewhere without an ADR (§7).

| Role | In molly |
| --- | --- |
| Service Definition | `src/backend/backend.odin` — shared types plus the proc contract (`list_objects`, `call_object`, `ubus_error_message`). |
| Service Provider | `src/backend/linux.odin` (`#+build linux`; real libuci / libubus / libblobmsg_json) and `src/backend/darwin.odin` (`#+build darwin`; canned JSON). |
| Consumer | `src/handlers/ubus_http.odin` — talks to the backend contract, never to a C library directly. |

Rules that follow:

- Add a platform by adding a provider file with **same-name, same-signature**
  procs; signature drift then fails at compile time on that platform.
- Keep platform branches (`#+build`) out of shared code: `src/main.odin`,
  `src/http/`, `src/handlers/`.
- `src/backend/bindings/*.odin` is `#+build linux` only, so a mistake there is
  invisible to `./build.sh --host` — also run `./build.sh --target` (§4.1).
- The `ctx.llm` / `vendor/Cordis` / event-bus examples in the table above come
  from the source project (deepseek-harness). molly has **no** Cordis and no
  plugin host; only the principle — *swap a provider, never a call site* —
  carries over.

### 3.3 Rules

- **Define the seam before the implementation.** Interface first; providers are interchangeable.
- **Keep the runtime closure closed.** Don't let capability providers pull in unbounded transitive deps.
- **Compose via an event bus / plugin host** (Cordis-style) rather than direct wiring.
- **Prefer configuration over forking.** A new behavior is a new plugin, not a branch in core logic.

Capability-seam pattern and provider checklist: `.ai-agents/capability-seams.md`.

---

## 4. Verify Before You Claim Done

From *deepseek-harness*: an agent may not declare a task complete until it has
passed the repo's quality gates. Guessing "it probably works" is not verification.

### 4.1 The gates for this repo

molly is Odin + bash. There is **no** `package.json`, no npm, and none of the
`lint` / `typecheck` / `knip` / `hygiene` scripts the source projects use. The
gates are unit + build + smoke, run in this order from the repo root:

```bash
./tests/unit.sh          # required: odin test over src/{http,luci,backend,handlers}
./build.sh --host        # required: builds build/molly-host (macOS native)
./tests/http_smoke.sh    # required: dispatcher-mode acceptance suite; must print "失败 0"
./tests/cgi_smoke.sh     # required: /cgi-bin/luci subprocess bridge (ADR 0003 T1)
./build.sh --target      # required when you touched #+build linux code,
                         # src/backend/bindings/, link flags, or build.sh
```

- `./tests/unit.sh` is the unit tier (pure functions: URI normalization, MIME,
  `depends` evaluation, tree resolution, CGI env/response translation). There is no
  `lint`: the compiler is the linter. Layers, coverage and acceptance criteria:
  `docs/testing.md`.
- `./tests/cgi_smoke.sh` covers the CGI bridge with stub scripts, so it runs on macOS
  without `ucode`; the same bridge is verified against the device's ucode dispatcher
  by swapping `--luci-cgi`.
- `./build.sh --host` is also the **compile check**: it type-checks every package
  that is not `#+build linux`, **including `@(test)` procedures** — a broken test
  fails the build, not just `odin test`.
- `./tests/http_smoke.sh` starts its own server on port 18080 and needs
  `build/molly-host` to exist first. It exits non-zero if any assertion failed;
  the `FAIL` lines carry expected vs. actual.
- `./build.sh --target` needs `$OPENWRT_SYSROOT` (`toolchain/setup.sh` creates it)
  and links with `zig cc`. Linux-only errors are invisible to `--host`.
- Do not invent gate commands that are not listed here.

### 4.2 Discipline

- **Re-run after every change.** A green run before an edit proves nothing after it.
- **Never skip verification** to "save time." An unverified claim is a bug waiting to ship.
- **Log the run** in the progress section of the active plan file
  (`.ai-memory/<slug>.md`) with the command, its exit status, and the pass/fail
  count (`通过 N，失败 M`).
- **Measure when possible.** `build.sh` already prints binary size; the smoke suite
  prints pass/fail counts. Record both when they change, plus LOC and time, so
  improvements stay observable (ponytail's benchmark discipline).

---

## 5. Shape Replies So They Can Be Acted On (i-have-adhd)

From *i-have-adhd*: the reader must never have to dig for the answer. These rules
apply to **every** reply for the whole session, not only the turn where they were
invoked. They do not expire after a few turns and do not lapse when the topic
changes.

### 5.1 The 10 rules

1. **Lead with the next action.** The first line is something to *do* — a command,
   a path, a snippet. If the answer is a command or snippet, it goes first; prose
   comes after, if at all.
2. **Number multi-step tasks.** Each step is one bounded action; no step contains
   "and then" twice. Use the fewest steps that still work — **a short path finished
   beats a complete path abandoned.**
3. **End with one concrete next action** if anything is left open. It must be
   doable in under two minutes; "open the file" counts.
4. **Suppress tangents.** Finish the first issue, then offer the second as a
   separate question. A question that arises mid-work is not a tangent: answer it
   yourself and fold the result in; if it truly needs the reader, surface it once,
   at the end.
5. **Restate state every turn.** "Step 3 of 5 done: schema updated. Next: backfill
   the column. Run the script?" The reader cannot hold "we are on step 3" between
   messages. Use the task/plan tool for multi-step work — the checklist does the
   restating, so don't also narrate the whole plan as prose.
6. **Give specific estimates when planning, or when a step may cross a session.**
   Use minutes/hours and name the assumption: "~15 minutes if `http_smoke.sh`
   already covers it; an afternoon if it needs new cases." An unprompted estimate
   on a one-line change is noise, not information.
7. **Make completed work visible.** State what now works in concrete, checkable
   terms ("Login works with magic links — run `npm run dev`, open `/login`").
8. **Matter-of-fact tone for errors.** Cause and fix, never "Uh oh" / "Oh no" /
   "there seems to be a problem".
9. **Cap lists at 5 items.** Past five, split into "do now" vs "later" or "must"
   vs "nice to have". Five ranked beats ten unranked.
10. **No preamble, no recap, no closing pleasantries.** Forbidden openers: "Great
    question", "Let me…", "I'll…", "Sure!", "Looking at your…". Forbidden recaps
    after a finished task. Forbidden closers: "Hope this helps", "Let me know if
    you need anything else", "Feel free to ask".

### 5.2 Pre-send check

Before sending, delete:

1. The first sentence, if it announces what you are about to do.
2. The last sentence, if it recaps what just happened or asks "anything else?".
3. Any "by the way" sidebar.
4. Any hedging adverb that adds no information ("perhaps", "might", "could
   possibly"). **Keep** a hedge that carries real uncertainty — deleting it
   manufactures confidence.
5. Any idiom or figurative phrase ("circle back", "get the ball rolling"). Replace
   with the literal action.

Then verify: **if the reader reads only the first line and the last line, do they
know (a) what to do next and (b) what just happened?** If yes, send.

### 5.3 When brevity yields

These override the defaults, in this order:

1. **Safety.** Destructive action ahead (`rm -rf`, force push, schema migration,
   dropping a table) → confirm before acting. Safety wins over brevity.
2. **A rule would delete the answer.** "What are my options?" gets 2–4 ranked
   options with one-line trade-offs, recommendation first. The options *are* the
   answer.
3. **Debug spiral.** Three turns of "still broken" → stop iterating on code, name
   the assumption that might be wrong, ask one diagnostic question.
4. **Real ambiguity.** One short clarifying question beats guessing and rewriting.
5. **Explain/explore requests.** Explain fully — still no preamble and no closer,
   but the body may run as long as the topic needs; add headers so the reader can
   skim back.

---

## 6. Durable Harness and Long-Running Work (prime-agent)

From *PrimeIntellect-ai/prime-agent*: working context should outlive a single chat
window, and an agent must be safe to run alongside other agents.

### 6.1 Harness state outlives the chat

- Treat supplemental prompts, memories, skill descriptions, and reusable
  subagent/workflow specs as **durable state** — in this repo: `AGENTS.md`,
  `.ai-agents/`, and `.ai-memory/`. Not chat context.
- Improve that state only by **small, evidence-backed updates**: a lesson is
  recorded when something actually happened (a failed command, a wrong assumption,
  a measured result). Never rewrite the base guidance wholesale; keep history or
  snapshots so an update can be rolled back.
- **Skills are executable.** A workflow repeated by hand more than once should
  become a script, not a longer paragraph of instructions.
- **Context as variables, tools as calls.** For large or repetitive work, drive it
  from code (a script/REPL) instead of re-prompting: pass data as variables, call
  sub-steps as functions, keep the results inspectable.
- **Persistent goals.** A long objective stays active across turns until it is
  done, paused, or cleared — it is not re-derived from scratch each turn.

### 6.2 Autonomy has budgets; a gate is not a proof

- Run bounded autonomy within explicit budgets. If the user gave none, the default
  here is **one plan phase per turn**: finish the phase, run its acceptance step
  (§4.1), report, then re-read the plan before starting the next. Stop and ask when
  the phase's acceptance criterion cannot be met or a listed risk fires.
- **A passed quality gate checks only what that gate verifies.** Green lint +
  green build + green tests does not prove the feature is correct or complete, and
  reaching a budget limit does not imply success. Always say what was *actually*
  verified (see §4).
- Generated code runs with your permissions and is **not** a sandbox. Review
  changes; run untrusted code or instructions only in an external sandbox.

### 6.3 Git safety when agents share a worktree

Hard rules, because another agent's uncommitted work is invisible to you:

- Commit **only files you changed in this session**. Never `git add -A` or
  `git add .` — they sweep up other agents' work. Use `git add <specific-paths>`
  and verify with `git status` first.
- **Never** run `git reset --hard`, `git checkout .`, `git clean -fd`,
  `git stash`, `git commit --no-verify`, or force push. Each can destroy another
  agent's work irreversibly.
- On rebase conflicts, resolve **only your own files**; if a conflict is in a file
  you did not modify, abort and ask.
- Never commit unless the user explicitly asks.

### 6.4 Reading and changing code

- **Read files in full** before wide-ranging changes, before editing a file you
  have not fully inspected, and whenever asked to investigate or audit. Do not
  rely on search snippets alone.
- Comment only where there is genuine ambiguity; do not narrate the code.
- Never remove or downgrade working code to silence a type/compile error from an
  outdated dependency — upgrade the dependency instead.
- Ask before removing functionality that looks intentional.
- Don't preserve backward compatibility unless it was explicitly requested.
- If you create or modify a test, **run that test and iterate until it passes**.

---

## 7. Decide With ADRs

Significant architectural or behavioral choices are recorded as **Architecture
Decision Records** so future agents (and humans) understand *why*, not just *what*.

### 7.1 When to write an ADR

Write one when you introduce or change a **capability seam** (a new
`src/backend/` provider, a new platform), change a **public interface** or a
**protocol contract** (e.g. the `/ubus` response shape), or accept a trade-off
with a lasting ceiling (e.g. one-connection-one-thread vs. a uloop event thread —
risk R4 of the P2 plan).

Do **not** open an ADR for per-file implementation choices; those belong in the
`关键设计决策` / `实现决策` sections of the plan file.

### 7.2 Format

Store ADRs in **one** place: `.ai-agents/adr/NNNN-kebab-slug.md`, numbered
sequentially (create the directory with the first ADR). This repo has no
`docs/adr/` variant.

```md
# ADR 000N: <Title>

## Status
Proposed | Accepted | Deprecated | Superseded by ADR 000M

## Context
What problem are we solving, and why now?

## Decision
What we chose, in one sentence.

## Options considered
- Option A: <pros/cons> → <why rejected/accepted>

## Consequences
What gets easier, what gets harder, and what ceilings we accept.

## Follow-ups
- [ ] <action> (owner / by when)
```

Template: `.ai-agents/0000-template.md` — copy it into `adr/` and rename to
`NNNN-kebab-slug.md`.

---

## 8. Documentation Discipline

- **Language.** `AGENTS.md` and `.ai-agents/` are written in **English**; project
  docs (`README.md`, `docs/`, `.ai-memory/`), code comments, and `build.sh` are
  written in **Chinese**. Match the file you are editing; do not mix the two inside
  one document.
- **Two doc surfaces, two audiences.** `.ai-memory/` is *working* memory for the
  current task (§1); `README.md` + `docs/` are the *durable, human-facing* doc set —
  `README.md` holds the stage-status table and quickstart, `docs/` holds the
  environment and build detail. When `build.sh` or `toolchain/setup.sh` changes,
  update the matching `docs/` page in the same change; a command in `docs/` that no
  longer runs is a bug.
- **Bilingual doc sets** (`name.md` + `name.zh.md` + `name.i18n.yaml`) are the
  deepseek-harness convention and are **not required here** — this repo ships no
  translated doc set. Adopt it only for a new user-facing doc set, and record that
  choice in an ADR.
- **Safety notices for experimental features.** Mark experimental/unsafe surfaces
  explicitly, in the style of the harness `SAFETY.md` notice (this repo's example:
  the transitional-mode `WARN` line and the "ACL 未实施" banner from the P2 plan).
- **Keep `AGENTS.md` and the docs consistent.** If you change agent behavior,
  update `AGENTS.md`; if you change architecture, update `.ai-memory/` and the
  relevant ADR in `.ai-agents/adr/`. A stale section number or path is a bug:
  `grep -rn '§' AGENTS.md .ai-agents/` before you finish and fix what you broke.
- **Line endings and final newlines.** No `.gitattributes` or `.editorconfig`
  exists yet; the repo is LF-only by convention. Add those files if a CRLF or a
  missing final newline ever shows up in a diff.

---

## 9. Memory Layout

This repository keeps agent-facing knowledge in three tiers:

- **`AGENTS.md`** (this file, tracked) — the single source of truth for *how to operate*.
- **`.ai-agents/`** (tracked) — supporting detail the agent reads on demand.
- **`.ai-memory/`** (never committed) — durable *working* memory for the current task (§1).

| Path | Contents |
| --- | --- |
| `.ai-agents/references.md` | Summaries of the five source projects and where their ideas live. |
| `.ai-agents/planning-template.md` | Copy-ready `task_plan.md` / `findings.md` / `progress.md` templates. |
| `.ai-agents/ponytail-ladder.md` | The reuse ladder and `ponytail:` marker rules, in full. |
| `.ai-agents/capability-seams.md` | The Capability Seam pattern and a provider checklist. |
| `.ai-agents/safety-checklist.md` | The non-negotiable safety items, as a review checklist. |
| `.ai-agents/0000-template.md` | The ADR template; copy it to `.ai-agents/adr/NNNN-slug.md` (see §7). |
| `.ai-agents/adr/` | Accepted ADRs (see §7); created with the first ADR. |

`.trae/documents/` holds a **mirror** of `.ai-memory/*.md` for external tooling.
`.ai-memory/` is authoritative; when the two disagree, trust `.ai-memory/`.

Treat `.ai-memory/` as **durable working memory**: read it at the start of a
task, update it as you learn, and rely on it to resume after a reset (§1.4).
Never commit it (§6.3).

---

## 10. Quick Reference (cheat sheet)

On every turn, in order:

1. **Plan on disk** — 3 sections under `.ai-memory/` if the task is non-trivial (§1).
2. **Understand first** — read files in full; trace real code before simplifying (§2, §6.4).
3. **Reuse ladder** — YAGNI → reuse → stdlib → native → dep → one line → minimum (§2.1).
4. **Swap, don't rewrite** — express new behavior as a `src/backend/` provider (§3.2).
5. **Verify** — `./tests/unit.sh`, `./build.sh --host`, `./tests/http_smoke.sh`,
   `./tests/cgi_smoke.sh` (plus `--target` for linux-only changes); log the result;
   state what the green gate actually proved (§4.1, §6.2).
6. **Record** — ADR in `.ai-agents/adr/` for lasting decisions; `ponytail:` for
   bounded cuts (§7, §2.3).
7. **Shape the reply** — action first, numbered steps, one concrete next step, no
   preamble and no closer (§5).
8. **Resume-safe** — everything important is already in `.ai-memory/` (§9).

### Do / Don't

| Do | Don't |
| --- | --- |
| Persist plan + findings + progress under `.ai-memory/`. | Keep the plan only in chat context, or drop plan files in the repo root. |
| Reuse existing code, stdlib, and platform features. | Rewrite what already works to "make it cleaner." |
| Add a platform as a new `src/backend/` provider. | Branch on the platform inside shared code, or add a vtable for two implementations. |
| Run `./tests/unit.sh` + `./build.sh --host` + `./tests/{http,cgi}_smoke.sh` before "done." | Declare success on a hunch, or invent gates the repo does not have. |
| Cut code, never safety. | Drop validation, error handling, or a11y to save lines. |
| Log every error and never repeat a failure. | Retry the same broken approach blindly. |
| Lead with the action; end with one concrete next step. | Bury the answer under context, or close with "hope this helps." |
| Update durable guidance with small, evidence-backed edits. | Rewrite the base guidance wholesale from recall. |
| Put ADRs in `.ai-agents/adr/`; copy `.ai-agents/0000-template.md`. | Scatter decisions across chat or open a `docs/adr/` tree. |
| `git add <specific paths>`; commit only your own files. | `git add -A`, `reset --hard`, `clean -fd`, or force push in a shared worktree. |
| State what a passing gate actually verified. | Treat "the build is green" as "the feature works." |
