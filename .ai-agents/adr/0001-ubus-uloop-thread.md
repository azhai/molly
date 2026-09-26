# ADR 0001: Keep thread-per-connection; add a dedicated ubus/uloop thread

## Status
Accepted

## Context

P2 shipped the HTTP layer as **one connection = one thread** (`src/http/server.odin`, each
`Connection` owns an arena) and talks to ubus as a **synchronous client**:
`linux.odin` keeps one global `ubus_context` behind `g_lock` and calls
`ubus_invoke_fd` (`bindings/ubus.odin`, "we are only a client: lookup / lookup_id / invoke").

P3 has to do three things that this model cannot express (this is risk **R4** in
`.ai-memory/p2-runtime-skeleton.md`):

1. **Serve** the four objects itself (`session` / `uci` / `file` / `luci`) instead of
   forwarding to the device's rpcd (P2 decision 7 — currently "transitional mode").
2. Deliver `/ubus/subscribe` events to HTTP clients (SSE); today it returns 501 (decision 8).
3. Enforce ACL on incoming calls (upstream `uh_ubus_allowed`), which lives in the server path.

Serving objects requires driving the libubus event loop, i.e. registering objects
(`ubus_add_object`) and processing messages that arrive on the ubus socket.

Facts verified against the local sysroot headers and `.so` symbol tables (2026-09-26):

| Fact | Evidence |
| --- | --- |
| `ubus_add_uloop` / `ubus_handle_event` are `static inline` (not linkable) and touch only `ctx->sock` | `libubus.h:289-292`, `:294-298` |
| `struct ubus_context` **is** public, with `struct uloop_fd sock;` | `libubus.h:160-165` |
| `struct uloop_fd` is public (cb, fd, eof, error, registered, flags) | `uloop.h:62-70` |
| uloop is part of libubox and exports what we need | `llvm-nm -D libubox.so`: `uloop_init`, `uloop_fd_add`, `uloop_fd_delete`, `uloop_timeout_set`, `uloop_run_timeout`, `uloop_done` |
| libubus exports the server-side API | `llvm-nm -D libubus.so`: `ubus_add_object`, `ubus_register_subscriber`, `ubus_send_reply`, `ubus_complete_deferred_request`, `ubus_send_event`, `ubus_register_event_handler` |

So R4 is solvable with **public API only** — no private struct guessing.

## Decision

Keep the HTTP layer exactly as it is (thread per connection). Add **one dedicated ubus
thread** that owns a **separate server `ubus_context`** and runs `uloop_run_timeout`.

1. **Two ubus contexts, two roles.**
   - *server ctx*: owned by the ubus thread; registers `session`/`uci`/`file`/`luci`,
     drives uloop, receives calls and events. Handlers execute in this thread, so they
     need no locking of their own.
   - *client ctx*: the existing one in `linux.odin`; HTTP threads keep doing synchronous
     `ubus_invoke_fd` against it under `g_lock` (used for the transitional forwarding and
     for anything molly calls outward).
2. **Wire ubus into the loop by replicating the two inlines** in Odin
   (`uloop_fd_add(&ctx.sock, ULOOP_BLOCKING | ULOOP_READ)` and `ctx.sock.cb(&ctx.sock, ULOOP_READ)`),
   with a bound `struct ubus_context` / `struct uloop_fd` layout plus `#assert` offset checks —
   same discipline as `bindings/uci.odin`.
3. **SSE bridges through a per-subscription pipe.** The HTTP thread asks the ubus thread to
   attach its pipe to the loop (a mutex-guarded command API; every ctx/loop mutation happens
   in the ubus thread), then blocks on the pipe and writes SSE frames. Teardown detaches and
   closes. A `uloop_timeout` in the ubus thread provides heartbeats.

## Options considered

- **A. Dedicated uloop thread + two contexts + pipes (chosen).**
  Keeps every line of verified P2 code; gives P3 a single-threaded execution domain for
  object handlers and ACL; uloop is already on the device (libubox).
- **B. Rewrite the HTTP layer as single-threaded epoll.**
  Rejected: throws away the verified `http` + `luci` + `handlers` stack and its test suite,
  to buy concurrency we do not need (32-connection ceiling, <2 MB RSS target). High risk,
  no requirement forces it.
- **C. One shared ubus context for the loop and for outgoing invokes.**
  Rejected: libubus is not thread-safe. Holding `g_lock` across `uloop_run_timeout` starves
  every invoke; not holding it corrupts the context's request registry.
- **D. Raw `poll()` on `ctx->sock.fd` instead of uloop.**
  Viable and slightly smaller, but loses timers (SSE heartbeat, session expiry) and diverges
  from upstream rpcd for no benefit; uloop ships with libubox, which we already link.

## Consequences

- **Easier**: incoming ubus calls, ACL checks, object registration and event fan-out all run
  in one thread with no internal locking; the HTTP layer is untouched.
- **Harder**: two contexts to keep alive (the server ctx needs an explicit reconnect policy);
  a cross-thread command channel to build and test; a new failure domain — if the ubus thread
  dies, molly keeps serving HTTP but loses its ubus service.
- **Ceilings we accept** (each is greppable / documented, not hidden):
  1. An SSE connection still occupies one HTTP thread (`ponytail:`-level simplification
     versus a multiplexing writer thread).
  2. `uloop` becomes a hard dependency of the linux provider (libubox is already required
     for `libblobmsg_json`); the darwin provider gets a fake server context so `--host`
     keeps compiling and the shared logic stays testable.
  3. The `ubus_context` / `uloop_fd` layout binding is compile-time asserted but only
     device-verifiable at runtime — same status as the `uci.h` bindings (P2 step 7).

## Follow-ups

- [ ] P3-1: bind uloop + server-side ubus API; register a probe object `molly.probe`
      with method `ping`. Verify on the device with `ubus -v list` + `ubus call molly.probe ping`.
- [ ] Decide the server ctx reconnect policy (`ubus_reconnect` vs `ubus_auto_conn`) before
      P3-2, and record it here or in a new ADR.
- [ ] P3-7: SSE pipe plumbing + heartbeat timer.
- [ ] Re-scope "template rendering": server-side ucode (`.ut`) subset vs. driving the LuCI
      JS client against our JSON API — needs its own ADR before any code (biggest unknown in P3).
