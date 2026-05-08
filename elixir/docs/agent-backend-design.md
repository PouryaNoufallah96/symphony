# Agent Backend Design Spike

This spike evaluates adding a Claude Code backend beside the current Codex app-server backend.

**Status:** Phase 4b landed. The backend boundary described below is now in code:

- `SymphonyElixir.Agent.Backend` — behavior + dispatcher (`agent.kind` based)
- `SymphonyElixir.Agent.CodexBackend` — delegates to existing `Codex.AppServer`
- `SymphonyElixir.Agent.ClaudeCodeBackend` — new `claude -p --output-format stream-json` driver
- Schema discriminated union on `agent.kind` (`codex | claude-code`) with a new `claude_code` config block
- `AgentRunner` routes through `Agent.Backend` instead of calling `AppServer` directly
- 12 new tests cover the dispatcher, schema validation, ClaudeCodeBackend stream parsing, error mapping, and prompt size limits.

Symphony × Claude Code remains experimental until the three live smokes (continuation, stream-json
event coverage, SIGTERM cancellation) have been run against a real `claude -p` install.

## Recommendation

Add a small `SymphonyElixir.Agent.Backend` behavior and keep Codex as the first implementation.
Claude Code should be marked experimental until its stream-json telemetry and cancellation semantics
are proven in a live smoke run.

Suggested behavior:

```elixir
@callback start_session(issue, workspace, settings) :: {:ok, session} | {:error, term()}
@callback run_turn(session, prompt, opts) :: {:ok, turn_result, session} | {:error, term()}
@callback cancel_turn(session) :: :ok | {:error, term()}
@callback close_session(session) :: :ok
```

The orchestrator should continue to own issue polling, workspace lifecycle, retries, and terminal
state reconciliation. The backend owns only agent process/session mechanics and event translation.

## Continuation Across Turns

Codex keeps a long-lived app-server session and Symphony sends additional turn requests. Claude Code
should use an explicit session file under the workspace rather than replaying all prior prompts into
each invocation.

Design:

- Store backend state in `{workspace}/.claude-thread/session.json`.
- Prefer Claude Code's session continuation flag or session id when available.
- If the installed CLI cannot continue by id, replay only a compact workpad summary plus the current
turn prompt, not the full event stream.
- Keep the existing `agent.max_turns` orchestration cap unchanged.

Risk: replay-based continuation can lose hidden model state and inflate prompt tokens. That mode
should be visible in logs as `continuation_mode=replay`.

## Dynamic Tools

Codex receives `linear_graphql` through app-server dynamic tools. Claude Code discovers tools from
workspace `.claude/` skills and MCP configuration.

Design:

- Backend startup copies or verifies the selected skill catalog before the first turn.
- Tracker-specific skills remain prompt-driven: Linear uses `linear`, GitHub uses `github`, ADO uses
  `ado`.
- Do not implement JSON-RPC dynamic tools for Claude Code in Phase 4b.
- If a workflow needs raw Linear GraphQL from Claude Code, provide it through the repo `.claude/`
  skill/MCP setup instead of the Codex dynamic tool channel.

Risk: feature parity depends on each workspace having the right `.claude/` tool configuration.

## Max Turns

Codex reports turn events over JSON-RPC. Claude Code returns once per `claude -p` process.

Design:

- Treat one Claude Code invocation as one Symphony turn.
- The existing agent runner loop remains the only `max_turns` enforcement point.
- A single invocation timeout uses the existing backend turn timeout setting or a new
  backend-specific timeout if Phase 4b needs one.

## Dashboard Telemetry

The current dashboard is built around Codex JSON-RPC turn events. Claude Code should stream
`--output-format stream-json` and map those events into the existing observability event taxonomy.

Design:

- Parse stdout as newline-delimited JSON.
- Persist raw events to `{workspace}/.claude-thread/events.jsonl`.
- Map events into normalized categories: `turn_started`, `assistant_delta`, `tool_started`,
  `tool_finished`, `token_usage`, `turn_finished`, `error`.
- Unknown events are stored raw and surfaced as debug telemetry, not dropped.

Risk: Claude Code event names may change. The mapper should be isolated and tested with fixtures.

## Cancellation

Codex supports `turn/cancel`. Claude Code cancellation is process based.

Design:

- Keep the OS process handle in the backend session.
- On cancellation, send `SIGTERM` and wait a short grace period.
- Escalate to `SIGKILL` only after the grace period.
- Mark the turn result as cancelled and do not run `after_run` hooks for a killed process unless the
  process exited cleanly.

Risk: process cancellation cannot guarantee tool-level atomicity. The prompt must continue to tell
agents to keep changes reviewable and resumable.

## Retries

Retries should stay at Symphony's current orchestration level.

Design:

- Backend returns normalized error reasons: `:timeout`, `:cancelled`, `{:exit_status, status}`,
  `{:stream_parse_error, reason}`, `{:cli_error, reason}`.
- The agent runner decides whether to retry the same issue and increments the existing retry count.
- Do not add backend-internal retry loops except for bounded stream-read transient errors.

## Workpad File

Claude Code needs a durable thread/workpad that the dashboard and later invocations can inspect.

Design:

- Directory: `{workspace}/.claude-thread/`
- `session.json`: backend name, CLI version, continuation mode, session id when available.
- `turns.jsonl`: one JSON object per Symphony turn with prompt hash, start/end timestamps, status,
  exit status, token usage when known, and output file references.
- `events.jsonl`: raw Claude Code stream events.

The dashboard should read normalized turn metadata first and only inspect raw events for detailed
per-turn panes.

## Phase 4b Scope

Green-light Phase 4b only if a local smoke proves:

- `claude -p` can be continued or replayed within acceptable prompt size.
- stream-json events include enough data for current dashboard cards.
- `SIGTERM` cancellation leaves the workspace usable for a retry.

If any point fails, keep Symphony x Claude Code experimental and leave it out of the smoke matrix.
