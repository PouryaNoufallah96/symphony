defmodule SymphonyElixir.Agent.BackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.{Backend, ClaudeCodeBackend, CodexBackend}

  describe "adapter/0" do
    test "defaults to CodexBackend when agent.kind is unset" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: nil)
      assert Backend.adapter() == CodexBackend
    end

    test "returns CodexBackend for agent.kind = codex" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")
      assert Backend.adapter() == CodexBackend
    end

    test "returns ClaudeCodeBackend for agent.kind = claude-code" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude-code")
      assert Backend.adapter() == ClaudeCodeBackend
    end
  end

  describe "Config.validate!/0 agent kind" do
    test "accepts codex" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "codex")
      assert Config.validate!() == :ok
    end

    test "accepts claude-code" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude-code")
      assert Config.validate!() == :ok
    end

    test "rejects unsupported agent.kind" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "rogue-agent")

      assert {:error, {:unsupported_agent_kind, "rogue-agent"}} = Config.validate!()
    end
  end
end
