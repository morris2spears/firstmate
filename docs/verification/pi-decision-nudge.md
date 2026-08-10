# Pi captain-attention nudge verification

Audience: maintainer verification.

## Current guarantee

As of 2026-08-10, Pi 0.82.1 primary sessions use `.pi/extensions/fm-primary-decision-nudge.ts` to inspect the latest assistant text after `agent_settled`.
The extension arms only for non-empty text that addresses `Captain` and presents a question or explicit decision request, and it excludes the exact routine reply `Captain, shipshape.`.
`bin/fm-decision-nudge.sh` owns the shared primary-scope check, Telegram opt-in check, private pending marker, detached delay, single claim, disarm, and content-free phone send.
The Pi extension disarms on interactive or RPC input, before a new agent run, and on session shutdown.
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
ok - Pi captain-attention decision-nudge suite complete
```

The regression uses a capture executable through `FMTG_TG_BIN`, so it verifies the exact content-free message without contacting Telegram.
