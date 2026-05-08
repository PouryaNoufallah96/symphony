defmodule SymphonyElixir.Agent.CodexBackend do
  @moduledoc """
  Codex agent backend. Delegates to `SymphonyElixir.Codex.AppServer`, which
  speaks JSON-RPC to the local `codex app-server` process over stdio.

  Phase 4b keeps the AppServer module in place rather than physically moving
  the body into this file. The seam at `Agent.Backend` is what matters; the
  internal layout can be reorganized later without orchestrator changes.
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  defdelegate start_session(workspace, opts), to: AppServer

  @impl true
  defdelegate run_turn(session, prompt, issue, opts), to: AppServer

  @impl true
  defdelegate stop_session(session), to: AppServer
end
