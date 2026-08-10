# Pi captain-attention nudge verification

Audience: maintainer verification.

## Current guarantee

As of 2026-08-10, Pi 0.82.1 primary sessions use `.pi/extensions/fm-primary-decision-nudge.ts` to inspect the latest assistant text after `agent_settled`.
The extension arms only for non-empty text that addresses `Captain` and presents a question or explicit decision request, and it excludes the exact routine reply `Captain, shipshape.`.
A decision verb only counts in an imperative, vocative-initial, second-person, or explicit-request position, so a settled watcher turn such as `Captain, PR #7 is merged and CI is green. I'll confirm the deploy once you're back.` does not page him.
The backward scan skips empty and tool-only assistant entries and stops at the turn boundary, so an ask the captain already answered can never re-arm.
`bin/fm-decision-nudge.sh` owns the shared primary-scope check, Telegram opt-in check, private pending marker, detached delay, single claim, disarm, and content-free phone send.
The primary-scope check gates disarming as well as arming: this tracked entrypoint also runs in crewmate and scout worktrees, which can inherit `FM_HOME` from the daemon environment, and must never cancel a nudge the captain's own session armed.
The Pi extension disarms on interactive or RPC input, before a new agent run, and on session shutdown.
It writes the same `state/.pi-decision-nudge-extension-loaded` marker its two sibling primary extensions write, so `bin/fm-session-start.sh` reports it as not loaded instead of silently losing the nudge, and `bin/fm-spawn.sh` passes it with an explicit `-e` in pi secondmate homes, where project trust is never approved.
All three primary extensions take their session-lock-ownership and version-stamp contract from one place, `.pi/extensions/lib/fm-primary-loaded-marker.ts`, so the writers cannot drift from what the session-start diagnostic checks.
The rendered Pi supervision snippet and the read-only repair line name all three extensions, so the documented trust-free `-e` fallback is exactly what clears the diagnostic.
The shared script header is the single owner of its Claude-compatible and Pi-compatible CLI.

Pi 0.82.1 exposes lifecycle events around agent runs and extension-owned UI calls, but it does not expose a global event when arbitrary code enters or leaves `ctx.ui.confirm`, `ctx.ui.select`, `ctx.ui.input`, or `ctx.ui.custom`.
The tracked Pi path therefore covers settled chat asks and does not guess at unrelated UI overlay state.

## Deterministic regression

Command:

```sh
tests/fm-pi-decision-nudge.test.sh
```

Output:

```text
ok - Pi heuristic arms only explicit captain-facing waits
ok - Pi agent_settled arms chat waits and captain presence disarms
ok - Pi arm and resolve own one pending marker
ok - detached timer claims once and suppresses duplicate sends
ok - a captain answer inside the delay cancels the send
ok - missing Telegram opt-in is inert
ok - non-primary linked worktrees stay out of scope
ok - only a primary session can disarm the captain's pending nudge
ok - Pi captain-attention decision-nudge suite complete
```

The regression uses a capture executable through `FMTG_TG_BIN`, so it verifies the exact content-free message without contacting Telegram.
