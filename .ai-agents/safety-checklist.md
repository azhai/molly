# Safety Checklist — Non-Negotiables

Derived from ponytail's "safety is non-negotiable" and deepseek-harness'
`SAFETY.md` experimental notice. See `AGENTS.md` §0 (rule 6), §2.2, and §6.3.

Run this as a review gate before declaring any task done. Every item must be
satisfied or explicitly justified in an ADR / `ponytail:` marker with a known
ceiling. The automated part of this gate is `./tests/http_smoke.sh` (§4.1); the
rest is a read of the diff.

## Trust boundaries
- [ ] All untrusted input is validated and sanitized at the boundary.
- [ ] No external/agent-supplied data is executed as code (no unsafe `eval`/`exec`).
- [ ] Shell commands are constructed safely (no unsanitized interpolation of untrusted values).
- [ ] Request paths are normalized and confined to `--docroot`; `..`, `%2e%2e`,
      and `%00` are rejected (molly: `src/http/uri.odin`, asserted by the
      `路径逃逸` block of `tests/http_smoke.sh`).
- [ ] Docroot files are only read — never created, overwritten, or deleted by a
      request.

## Data loss
- [ ] Destructive operations (delete, overwrite, `git reset --hard`, drop) are guarded.
- [ ] Irreversible writes require explicit confirmation or a safe default (backup / dry-run).
- [ ] No silent truncation or overwriting of user data.
- [ ] `.ai-memory/` and `.ai-agents/` are edited, never regenerated or deleted:
      they are the only record of the current plan and the decisions behind it.

## Security
- [ ] No secrets, tokens, or credentials are written into source, logs, or commits.
- [ ] No new exposed network surface without auth; no debug endpoints left open.
- [ ] Dependencies are from trusted sources and keep the runtime closure closed.

## Accessibility
- [ ] UI uses semantic markup with labels and roles.
- [ ] Color is never the sole carrier of meaning; contrast meets the baseline.
- [ ] Interactive elements are keyboard-operable.

## Experimental surfaces
- [ ] Any experimental/unsafe feature carries an explicit notice (harness
      `SAFETY.md` style; the bilingual form is *not* required in this repo —
      `AGENTS.md` §8). Local example: the transitional-mode `WARN` line and the
      "ACL 未实施" banner from the P2 plan.
- [ ] Risky behavior is gated behind a flag the user must opt into.
- [ ] Behavior that has not been verified on the target device is labelled as
      such (molly: anything outside `--host` + `http_smoke.sh` coverage).

## If you must cut a corner
Use a `ponytail:` marker **only** for trivial, bounded simplifications, and record
the accepted ceiling. Never use it to waive an item above — those are non-negotiable.
