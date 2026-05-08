defmodule SymphonyElixir.Agent.ClaudeCodeBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.ClaudeCodeBackend
  alias SymphonyElixir.Linear.Issue

  setup do
    workspace_root =
      Path.join(System.tmp_dir!(), "claude-code-backend-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    workspace = Path.join(workspace_root, "issue-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(workspace_root) end)

    {:ok, workspace_root: workspace_root, workspace: workspace}
  end

  defp write_fake_claude!(dir, body) do
    path = Path.join(dir, "fake_claude.sh")

    contents = """
    #!/usr/bin/env bash
    # Drain stdin so prompt write doesn't SIGPIPE the parent.
    cat > /dev/null
    #{body}
    """

    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp issue_fixture do
    %Issue{id: "issue-1", identifier: "TEST-1", title: "Verify Claude Code backend"}
  end

  defp configure_workflow!(ctx, fake_command) do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude-code",
      workspace_root: ctx.workspace_root,
      claude_code_command: fake_command,
      claude_code_permission_mode: "",
      claude_code_turn_timeout_ms: 30_000,
      claude_code_stop_grace_ms: 100
    )
  end

  describe "start_session/2" do
    test "creates the .claude-thread/ directory and session.json", ctx do
      configure_workflow!(ctx, "echo init")

      assert {:ok, session} = ClaudeCodeBackend.start_session(ctx.workspace, [])

      assert String.ends_with?(session.workspace, "/issue-1")
      assert String.ends_with?(session.session_dir, "/.claude-thread")
      assert File.exists?(session.session_dir)
      assert File.exists?(Path.join(session.session_dir, "session.json"))

      session_metadata = Jason.decode!(File.read!(Path.join(session.session_dir, "session.json")))
      assert session_metadata["backend"] == "claude-code"
    end

    test "rejects worker_host (remote unsupported)", ctx do
      configure_workflow!(ctx, "echo init")

      assert {:error, {:claude_code_remote_unsupported, "remote-host"}} =
               ClaudeCodeBackend.start_session(ctx.workspace, worker_host: "remote-host")
    end

    test "rejects workspace outside the configured root", ctx do
      configure_workflow!(ctx, "echo init")
      outside = Path.join(System.tmp_dir!(), "not-a-symphony-workspace-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
               ClaudeCodeBackend.start_session(outside, [])
    end
  end

  describe "run_turn/4" do
    test "parses stream-json into codex-compatible events and persists logs", ctx do
      script_dir = Path.join(ctx.workspace_root, "scripts")
      File.mkdir_p!(script_dir)

      script_body = """
      cat <<'JSON'
      {"type":"system","subtype":"init","session_id":"session-abc","model":"claude-sonnet-4-6"}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on it."}]}}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Edit","input":{"path":"a.txt"}}]}}
      {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}
      {"type":"result","subtype":"success","is_error":false,"duration_ms":42,"num_turns":1,"result":"done","total_cost_usd":0.001,"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0}}
      JSON
      """

      fake_command = write_fake_claude!(script_dir, script_body)
      configure_workflow!(ctx, fake_command)

      {:ok, session} = ClaudeCodeBackend.start_session(ctx.workspace, [])
      parent = self()

      assert {:ok, result} =
               ClaudeCodeBackend.run_turn(session, "do the thing", issue_fixture(),
                 on_message: fn message -> send(parent, {:msg, message}) end
               )

      assert result.session_id == "session-abc"
      assert result.usage["input_tokens"] == 100
      assert result.usage["output_tokens"] == 50
      assert result.total_cost_usd == 0.001
      assert result.duration_ms == 42

      events = drain_messages([])
      event_names = Enum.map(events, & &1.event)

      assert :session_started in event_names
      assert :assistant_message in event_names
      assert :tool_call_started in event_names
      assert :tool_call_completed in event_names
      assert :turn_completed in event_names

      turn_completed =
        Enum.find(events, &(&1.event == :turn_completed))

      assert turn_completed.session_id == "session-abc"
      assert turn_completed.usage["input_tokens"] == 100

      events_path = Path.join(session.session_dir, "events.jsonl")
      turns_path = Path.join(session.session_dir, "turns.jsonl")

      assert File.exists?(events_path)
      assert File.exists?(turns_path)

      events_lines = events_path |> File.read!() |> String.split("\n", trim: true)
      assert length(events_lines) >= 5

      turn_lines = turns_path |> File.read!() |> String.split("\n", trim: true)
      assert [last_turn | _] = Enum.reverse(turn_lines)
      decoded = Jason.decode!(last_turn)
      assert decoded["status"] == "turn_completed"
      assert decoded["session_id"] == "session-abc"
    end

    test "emits :turn_failed when result is_error is true", ctx do
      script_dir = Path.join(ctx.workspace_root, "scripts-fail")
      File.mkdir_p!(script_dir)

      script_body = """
      cat <<'JSON'
      {"type":"system","subtype":"init","session_id":"session-fail"}
      {"type":"result","subtype":"error_max_turns","is_error":true,"duration_ms":99,"num_turns":1,"result":"hit max","usage":{"input_tokens":10,"output_tokens":5}}
      JSON
      """

      fake_command = write_fake_claude!(script_dir, script_body)
      configure_workflow!(ctx, fake_command)

      {:ok, session} = ClaudeCodeBackend.start_session(ctx.workspace, [])
      parent = self()

      assert {:error, {:turn_failed, payload}} =
               ClaudeCodeBackend.run_turn(session, "fail this", issue_fixture(),
                 on_message: fn message -> send(parent, {:msg, message}) end
               )

      assert payload["is_error"] == true

      events = drain_messages([])
      assert Enum.any?(events, &(&1.event == :turn_failed))
    end

    test "rejects oversize prompt", ctx do
      script_dir = Path.join(ctx.workspace_root, "scripts-big")
      File.mkdir_p!(script_dir)
      fake_command = write_fake_claude!(script_dir, "true")

      write_workflow_file!(Workflow.workflow_file_path(),
        agent_kind: "claude-code",
        workspace_root: ctx.workspace_root,
        claude_code_command: fake_command,
        claude_code_max_prompt_bytes: 16
      )

      {:ok, session} = ClaudeCodeBackend.start_session(ctx.workspace, [])

      huge_prompt = String.duplicate("x", 1024)

      assert {:error, {:prompt_too_large, 1024, 16}} =
               ClaudeCodeBackend.run_turn(session, huge_prompt, issue_fixture(), [])
    end
  end

  defp drain_messages(acc) do
    receive do
      {:msg, message} -> drain_messages([message | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
