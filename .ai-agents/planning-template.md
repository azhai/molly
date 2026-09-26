# Planning Templates — `task_plan.md` / `findings.md` / `progress.md`

Copy these into `.ai-memory/` at the start of any multi-step task. Never into the
repo root — the root is product code (`src/`, `build.sh`, `tests/`). See
`AGENTS.md` §1.

A single consolidated file is allowed when the three sections stay distinguishable
by heading; name it `<phase-slug>.md` (the current plan is
`.ai-memory/p2-runtime-skeleton.md`). One task = one file.

## task_plan.md

```md
# Task Plan: <short title>

## Goal
One sentence: what "done" means.

## Phases
- [ ] 1. <phase> — <acceptance criterion>
- [ ] 2. <phase> — <acceptance criterion>
- [ ] 3. <phase> — <acceptance criterion>
- [ ] 4. Verify — run repo gates, all green

## Open questions
- <question> → <answer or owner>

## Resume point
If context resets, continue from: <last checked phase>.
```

## findings.md

```md
# Findings

## <YYYY-MM-DD> — <topic>
- Learned: <fact or decision>
- Source: <file:line / URL>
- Implication: <why it matters for this task>

## Errors logged
- [ ] <command> failed with <error>; next attempt: <different approach>
```

## progress.md

```md
# Progress Log

## <YYYY-MM-DD HH:MM>
- Ran: `<command>` → exit <code>
  - note: <what changed / observed>
- Ran: `<gate command>` → all green / <N> failed
- Attempts on <subtask>:
  1. <approach A> → failed (<reason>) — do not repeat
  2. <approach B> → succeeded
```

## Usage rules
- Create `.ai-memory/task_plan.md` **before** the first code change.
- Append to `.ai-memory/findings.md` after ~every 2 read/search operations.
- Log every command and every error in `.ai-memory/progress.md`, with its exit status.
- Check off phases in `.ai-memory/task_plan.md` as they finish, and keep the
  `Resume point` line current — it is what a reset reads first.
- Record gate runs as `通过 N，失败 M`, the same counts `http_smoke.sh` prints.
- Never `git add` `.ai-memory/`: it is working memory, not product (`AGENTS.md` §6.3).
- On `/clear` or crash, re-read these three files and resume — no restatement needed.
