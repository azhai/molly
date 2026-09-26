# Capability Seams — Plugin Pattern (full)

Source: https://github.com/deepseek-ai/deepseek-harness ("Everything is a Plugin").
See `AGENTS.md` §3.

## Principle
Every component — model adapters, tool registries, even the agent loop — is a
**plugin** composed through a host (Cordis-style). New behavior is a new plugin;
core logic stays closed.

## The Capability Seam
A *seam* is a swappable capability with three roles:

| Role | Responsibility | Example |
| --- | --- | --- |
| **Service Definition** | Declares the interface (the seam). | `ctx.llm`, `ctx.fs`, `ctx.shell` |
| **Service Provider** | Implements the interface. | `llm-deepseek`, `fs-local`, `fs-sandbox` |
| **Consumer** | Uses the capability (often a tool). | `tool-bash` consuming the shell capability |

Swap a **provider** to change behavior end-to-end — e.g. `fs-local` → `fs-sandbox`
(move from local disk to a Landlock-sandboxed environment) — without touching any
**consumer** call site. (`ctx.llm`, `fs-local`, Landlock: examples from the source
project, not from molly.)

## In molly (this repo)

molly has exactly one seam, and it is `src/backend/`:

| Role | File |
| --- | --- |
| Service Definition | `src/backend/backend.odin` — shared types + the proc contract (`list_objects`, `call_object`, `ubus_error_message`). |
| Service Provider | `src/backend/linux.odin` (`#+build linux`, real libuci/libubus/libblobmsg_json) and `src/backend/darwin.odin` (`#+build darwin`, canned JSON). |
| Consumer | `src/handlers/ubus_http.odin`; `src/main.odin` for wiring. |
| Bindings (provider-internal) | `src/backend/bindings/*.odin`, `#+build linux` only. |

The provider is selected by **build tag**, not by configuration or a registry —
that is the molly-appropriate form of "swap a provider": `--host` gives the
darwin provider, `--target` gives the linux one, and no call site changes.

## Provider checklist (before adding a plugin)
- [ ] Is the **interface** already defined, or do I need a new seam? (Define the seam first.)
- [ ] Does the provider keep the **runtime closure closed** (no unbounded transitive deps)?
- [ ] Is it wired through the **plugin host / event bus**, not direct imports from core?
- [ ] Is it selected by **configuration**, so it can be swapped without code changes?
- [ ] Does it have a **test** proving the seam contract (provider-agnostic)?
- [ ] Is the choice recorded as an **ADR** if it is a lasting/architecture-level decision?

### Checklist additions for molly
- [ ] The new provider declares the **same proc names and signatures** as the
      existing ones; a mismatch must fail at compile time on that platform, not at
      runtime.
- [ ] No `#+build` branch leaked into shared code (`src/main.odin`, `src/http/`,
      `src/handlers/`).
- [ ] Both `./build.sh --host` and `./build.sh --target` pass; `--target` is the
      only gate that compiles `src/backend/bindings/` (`AGENTS.md` §4.1).
- [ ] The provider is not a seam at all if only one implementation can ever exist —
      prefer a plain proc over a new indirection layer.

## Composition notes
- Prefer an **event bus** for cross-cutting concerns (logging, telemetry, gates)
  over scattered direct calls.
- Consumers depend on the **definition**, never on a concrete provider.
- Sandboxing (e.g. Landlock) and filesystem/shell access live behind seams so the
  same agent runs safely locally and remotely.

## Monorepo orientation (source project's layout — NOT molly)

Shown only so the harness references in `AGENTS.md` §3.1 make sense; molly is a
single Odin project (see the layout at the top of
`.ai-memory/p2-runtime-skeleton.md`).
- `packages/core/` — product API spine: session, agent, tools.
- `packages/llm/` — capability definitions + model adapters.
- `vendor/` — vendored Cordis (local modifications tracked here).
- `apps/` — entry points (CLI, Web UI).
- `docs/` — architecture, capability-seams, development, ADRs.
