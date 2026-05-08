defmodule SymphonyElixir.Agent.Backend do
  @moduledoc """
  Adapter boundary for agent execution.

  Backends own agent process/session mechanics and event translation. The
  orchestrator continues to own issue polling, workspace lifecycle, retries,
  and terminal state reconciliation.
  """

  alias SymphonyElixir.Config

  @type session :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback stop_session(session()) :: :ok

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    adapter().start_session(workspace, opts)
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    adapter().run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    adapter().stop_session(session)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().agent.kind do
      "claude-code" -> SymphonyElixir.Agent.ClaudeCodeBackend
      "codex" -> SymphonyElixir.Agent.CodexBackend
      _ -> SymphonyElixir.Agent.CodexBackend
    end
  end
end
