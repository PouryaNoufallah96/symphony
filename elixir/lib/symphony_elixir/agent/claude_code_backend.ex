defmodule SymphonyElixir.Agent.ClaudeCodeBackend do
  @moduledoc """
  Claude Code agent backend.

  Each turn invokes `claude -p --output-format stream-json` as a fresh
  process. State is persisted under `{workspace}/.claude-thread/` so the
  dashboard and a subsequent turn can inspect prior activity:

  * `session.json` — backend identity, CLI command, last-known session id.
  * `turns.jsonl` — one row per Symphony turn (start, end, status, usage).
  * `events.jsonl` — raw stream events captured during turns.

  Cancellation is process-based (`Port.close/1` propagates SIGTERM through
  the bash wrapper to the claude CLI, then the OS escalates to SIGKILL after
  the grace period if needed).

  The backend emits codex-compatible messages via `on_message` so existing
  orchestrator and dashboard code can integrate without changes:

      :session_started → first stream-json event with session id
      :tool_call_started, :tool_call_completed → tool_use / tool_result lines
      :turn_completed → final `result` event (usage, cost, duration)
      :turn_failed, :turn_cancelled → terminal error states
      :other_message → unrecognized but well-formed lines
      :malformed → JSON parse failure for a candidate protocol line
  """

  @behaviour SymphonyElixir.Agent.Backend

  require Logger

  alias SymphonyElixir.{Config, PathSafety}

  @type session :: %{
          workspace: Path.t(),
          session_dir: Path.t(),
          worker_host: String.t() | nil,
          turn_number: non_neg_integer(),
          last_session_id: String.t() | nil
        }

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- ensure_local(worker_host),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, session_dir} <- ensure_session_dir(expanded_workspace) do
      session = %{
        workspace: expanded_workspace,
        session_dir: session_dir,
        worker_host: worker_host,
        turn_number: 0,
        last_session_id: nil
      }

      write_session_metadata(session)
      {:ok, session}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{} = session, prompt, issue, opts \\ []) when is_binary(prompt) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_number = session.turn_number + 1
    turn_id = "claude-code-#{:erlang.unique_integer([:positive])}-#{turn_number}"
    started_at = DateTime.utc_now()

    Logger.info("Claude Code turn started for #{issue_context(issue)} turn=#{turn_number} turn_id=#{turn_id}")

    case start_port(session.workspace, prompt, session.session_dir, turn_number) do
      {:ok, port, prompt_path} ->
        try do
          consume_stream(port, %{
            on_message: on_message,
            session_dir: session.session_dir,
            turn_id: turn_id,
            turn_number: turn_number,
            session_id: turn_id,
            issue: issue,
            started_at: started_at,
            prompt_path: prompt_path
          })
        after
          stop_port(port, claude_code_settings().stop_grace_ms)
        end

      {:error, reason} ->
        emit_message(on_message, :startup_failed, %{reason: reason}, %{turn_id: turn_id, turn_number: turn_number})
        record_turn(session.session_dir, %{
          turn_id: turn_id,
          turn_number: turn_number,
          status: :startup_failed,
          started_at: DateTime.to_iso8601(started_at),
          ended_at: DateTime.to_iso8601(DateTime.utc_now()),
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # ---------------------------------------------------------------------------
  # Workspace & session-dir helpers
  # ---------------------------------------------------------------------------

  defp ensure_local(nil), do: :ok

  defp ensure_local(host) when is_binary(host) do
    {:error, {:claude_code_remote_unsupported, host}}
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp ensure_session_dir(workspace) do
    dir_name = claude_code_settings().session_dir_name
    session_dir = Path.join(workspace, dir_name)

    case File.mkdir_p(session_dir) do
      :ok -> {:ok, session_dir}
      {:error, reason} -> {:error, {:claude_thread_dir_unavailable, session_dir, reason}}
    end
  end

  defp write_session_metadata(%{session_dir: session_dir, workspace: workspace}) do
    settings = claude_code_settings()

    payload = %{
      "backend" => "claude-code",
      "command" => settings.command,
      "output_format" => settings.output_format,
      "permission_mode" => settings.permission_mode,
      "workspace" => workspace,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    path = Path.join(session_dir, "session.json")

    case File.write(path, Jason.encode!(payload, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Claude Code session metadata write failed: #{inspect(reason)}")
    end
  end

  defp record_turn(session_dir, payload) when is_map(payload) do
    path = Path.join(session_dir, "turns.jsonl")
    line = Jason.encode!(payload) <> "\n"

    case File.write(path, line, [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Claude Code turn log write failed: #{inspect(reason)}")
    end
  end

  defp record_event(session_dir, raw_line, payload) when is_binary(raw_line) do
    path = Path.join(session_dir, "events.jsonl")

    line =
      Jason.encode!(%{
        "received_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "raw" => raw_line,
        "payload" => payload
      }) <> "\n"

    case File.write(path, line, [:append]) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Claude Code event log write failed: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Port lifecycle
  # ---------------------------------------------------------------------------

  defp start_port(workspace, prompt, session_dir, turn_number) do
    settings = claude_code_settings()

    with :ok <- check_prompt_size(prompt, settings.max_prompt_bytes),
         {:ok, prompt_path} <- write_turn_prompt(session_dir, prompt, turn_number),
         {:ok, executable} <- find_bash() do
      command = build_command(settings, prompt_path)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port, prompt_path}
    end
  end

  defp check_prompt_size(prompt, max_bytes) when is_binary(prompt) do
    if byte_size(prompt) <= max_bytes do
      :ok
    else
      {:error, {:prompt_too_large, byte_size(prompt), max_bytes}}
    end
  end

  defp write_turn_prompt(session_dir, prompt, turn_number) do
    filename = "turn-#{:io_lib.format("~4..0B", [turn_number]) |> IO.iodata_to_binary()}-prompt.txt"
    path = Path.join(session_dir, filename)

    case File.write(path, prompt) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:claude_thread_prompt_write_failed, path, reason}}
    end
  end

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      bash -> {:ok, bash}
    end
  end

  defp build_command(settings, prompt_path) do
    flags =
      [
        "--output-format",
        settings.output_format,
        "--print",
        permission_flag(settings.permission_mode)
      ]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))

    flag_string = Enum.map_join(flags, " ", &shell_escape/1)

    "#{settings.command} #{flag_string} < #{shell_escape(prompt_path)}"
  end

  defp permission_flag("dangerously-skip-permissions"), do: "--dangerously-skip-permissions"
  defp permission_flag(""), do: ""
  defp permission_flag(nil), do: ""

  defp permission_flag(mode) when is_binary(mode) do
    case String.trim_leading(mode, "--") do
      "" -> ""
      stripped -> "--#{stripped}"
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp stop_port(port, grace_ms) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        wait_for_port_exit(port, grace_ms)
        :ok
    end
  end

  defp stop_port(_port, _grace_ms), do: :ok

  defp wait_for_port_exit(port, grace_ms) when is_integer(grace_ms) and grace_ms > 0 do
    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      grace_ms -> :ok
    end
  end

  defp wait_for_port_exit(_port, _grace_ms), do: :ok

  # ---------------------------------------------------------------------------
  # Stream consumption
  # ---------------------------------------------------------------------------

  defp consume_stream(port, ctx) do
    timeout_ms = claude_code_settings().turn_timeout_ms
    receive_loop(port, ctx, timeout_ms, "")
  end

  defp receive_loop(port, ctx, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> to_string(chunk)
        handle_line(port, ctx, line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, ctx, timeout_ms, pending <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        on_exit_status(ctx, status)
    after
      timeout_ms ->
        record_turn(ctx.session_dir, %{
          turn_id: ctx.turn_id,
          turn_number: ctx.turn_number,
          status: :timeout,
          started_at: DateTime.to_iso8601(ctx.started_at),
          ended_at: DateTime.to_iso8601(DateTime.utc_now()),
          reason: "turn_timeout"
        })

        emit_message(
          ctx.on_message,
          :turn_failed,
          %{reason: :turn_timeout},
          metadata_for(ctx)
        )

        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, ctx, line, timeout_ms) do
    payload_string = to_string(line)

    case Jason.decode(payload_string) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        ctx = maybe_capture_session_id(ctx, payload)
        record_event(ctx.session_dir, payload_string, payload)

        emit_message(
          ctx.on_message,
          :session_started,
          %{
            session_id: ctx.session_id,
            thread_id: ctx.turn_id,
            turn_id: ctx.turn_id,
            payload: payload,
            raw: payload_string
          },
          metadata_for(ctx, payload)
        )

        receive_loop(port, ctx, timeout_ms, "")

      {:ok, %{"type" => "result", "is_error" => true} = payload} ->
        record_event(ctx.session_dir, payload_string, payload)
        record_turn_completion(ctx, :turn_failed, payload)

        emit_message(
          ctx.on_message,
          :turn_failed,
          %{
            payload: payload,
            raw: payload_string,
            details: payload,
            session_id: ctx.session_id,
            usage: Map.get(payload, "usage")
          },
          metadata_for(ctx, payload)
        )

        {:error, {:turn_failed, payload}}

      {:ok, %{"type" => "result"} = payload} ->
        record_event(ctx.session_dir, payload_string, payload)
        record_turn_completion(ctx, :turn_completed, payload)

        emit_message(
          ctx.on_message,
          :turn_completed,
          %{
            payload: payload,
            raw: payload_string,
            details: payload,
            session_id: ctx.session_id,
            usage: Map.get(payload, "usage")
          },
          metadata_for(ctx, payload)
        )

        {:ok,
         %{
           result: Map.get(payload, "result"),
           session_id: ctx.session_id,
           thread_id: ctx.turn_id,
           turn_id: ctx.turn_id,
           usage: Map.get(payload, "usage"),
           total_cost_usd: Map.get(payload, "total_cost_usd"),
           duration_ms: Map.get(payload, "duration_ms")
         }}

      {:ok, %{"type" => "assistant", "message" => %{"content" => content}} = payload}
      when is_list(content) ->
        record_event(ctx.session_dir, payload_string, payload)
        emit_assistant_chunks(ctx, content, payload, payload_string)
        receive_loop(port, ctx, timeout_ms, "")

      {:ok, %{"type" => "user", "message" => %{"content" => content}} = payload}
      when is_list(content) ->
        record_event(ctx.session_dir, payload_string, payload)
        emit_tool_results(ctx, content, payload, payload_string)
        receive_loop(port, ctx, timeout_ms, "")

      {:ok, payload} ->
        record_event(ctx.session_dir, payload_string, payload)

        emit_message(
          ctx.on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_for(ctx, payload)
        )

        receive_loop(port, ctx, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(payload_string)

        if protocol_message_candidate?(payload_string) do
          emit_message(
            ctx.on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_for(ctx)
          )
        end

        receive_loop(port, ctx, timeout_ms, "")
    end
  end

  defp on_exit_status(ctx, 0) do
    record_turn(ctx.session_dir, %{
      turn_id: ctx.turn_id,
      turn_number: ctx.turn_number,
      status: :exited,
      started_at: DateTime.to_iso8601(ctx.started_at),
      ended_at: DateTime.to_iso8601(DateTime.utc_now()),
      exit_status: 0
    })

    emit_message(
      ctx.on_message,
      :turn_ended,
      %{exit_status: 0, session_id: ctx.session_id},
      metadata_for(ctx)
    )

    {:ok,
     %{
       result: nil,
       session_id: ctx.session_id,
       thread_id: ctx.turn_id,
       turn_id: ctx.turn_id,
       exit_status: 0
     }}
  end

  defp on_exit_status(ctx, status) do
    record_turn(ctx.session_dir, %{
      turn_id: ctx.turn_id,
      turn_number: ctx.turn_number,
      status: :exited_nonzero,
      started_at: DateTime.to_iso8601(ctx.started_at),
      ended_at: DateTime.to_iso8601(DateTime.utc_now()),
      exit_status: status
    })

    emit_message(
      ctx.on_message,
      :turn_ended_with_error,
      %{exit_status: status, session_id: ctx.session_id, reason: {:port_exit, status}},
      metadata_for(ctx)
    )

    {:error, {:port_exit, status}}
  end

  defp emit_assistant_chunks(ctx, content, payload, raw_line) do
    Enum.each(content, fn item ->
      case item do
        %{"type" => "text"} = chunk ->
          emit_message(
            ctx.on_message,
            :assistant_message,
            %{payload: payload, chunk: chunk, raw: raw_line, session_id: ctx.session_id},
            metadata_for(ctx, payload)
          )

        %{"type" => "tool_use"} = chunk ->
          emit_message(
            ctx.on_message,
            :tool_call_started,
            %{
              payload: payload,
              chunk: chunk,
              raw: raw_line,
              session_id: ctx.session_id,
              tool: Map.get(chunk, "name"),
              tool_use_id: Map.get(chunk, "id")
            },
            metadata_for(ctx, payload)
          )

        other ->
          emit_message(
            ctx.on_message,
            :assistant_chunk,
            %{payload: payload, chunk: other, raw: raw_line, session_id: ctx.session_id},
            metadata_for(ctx, payload)
          )
      end
    end)
  end

  defp emit_tool_results(ctx, content, payload, raw_line) do
    Enum.each(content, fn item ->
      case item do
        %{"type" => "tool_result"} = chunk ->
          emit_message(
            ctx.on_message,
            :tool_call_completed,
            %{
              payload: payload,
              chunk: chunk,
              raw: raw_line,
              session_id: ctx.session_id,
              tool_use_id: Map.get(chunk, "tool_use_id")
            },
            metadata_for(ctx, payload)
          )

        other ->
          emit_message(
            ctx.on_message,
            :user_chunk,
            %{payload: payload, chunk: other, raw: raw_line, session_id: ctx.session_id},
            metadata_for(ctx, payload)
          )
      end
    end)
  end

  defp record_turn_completion(ctx, status, payload) do
    record_turn(ctx.session_dir, %{
      turn_id: ctx.turn_id,
      turn_number: ctx.turn_number,
      status: status,
      started_at: DateTime.to_iso8601(ctx.started_at),
      ended_at: DateTime.to_iso8601(DateTime.utc_now()),
      session_id: ctx.session_id,
      usage: Map.get(payload, "usage"),
      total_cost_usd: Map.get(payload, "total_cost_usd"),
      duration_ms: Map.get(payload, "duration_ms"),
      result: Map.get(payload, "result")
    })
  end

  defp maybe_capture_session_id(ctx, %{"session_id" => session_id}) when is_binary(session_id) do
    %{ctx | session_id: session_id}
  end

  defp maybe_capture_session_id(ctx, _payload), do: ctx

  defp metadata_for(ctx, payload \\ %{}) do
    base = %{
      backend: "claude-code",
      turn_id: ctx.turn_id,
      turn_number: ctx.turn_number
    }

    base
    |> Map.put(:session_id, ctx.session_id)
    |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    case Map.get(payload, "usage") do
      usage when is_map(usage) -> Map.put(metadata, :usage, usage)
      _ -> metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_), do: "issue_id=? issue_identifier=?"

  defp log_non_json_stream_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude Code stream output: #{text}")
      else
        Logger.debug("Claude Code stream output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp claude_code_settings do
    Config.settings!().claude_code
  end
end
