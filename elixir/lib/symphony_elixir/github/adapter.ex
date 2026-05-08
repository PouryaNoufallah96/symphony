defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub issue tracker adapter backed by the `gh` CLI.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @issue_json_fields "number,title,body,state,url,labels,assignees,createdAt,updatedAt"

  @impl true
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @impl true
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker
    args = ["issue", "list", "--state", issue_list_state(state_names), "--json", @issue_json_fields]
    normalized_state_names = Enum.map(state_names, &normalize_state/1)

    with {:ok, response} <- run_json("gh", args ++ repo_args(tracker)) do
      issues =
        response
        |> Enum.map(&normalize_issue/1)
        |> Enum.filter(&matches_state_or_label?(&1, normalized_state_names))

      {:ok, issues}
    end
  end

  @impl true
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker

    issue_ids
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, issues} ->
      args = ["issue", "view", issue_id, "--json", @issue_json_fields] ++ repo_args(tracker)

      case run_json("gh", args) do
        {:ok, response} -> {:cont, {:ok, [normalize_issue(response) | issues]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    args = ["issue", "comment", issue_id, "--body", body] ++ repo_args(Config.settings!().tracker)

    with {:ok, _output} <- run_ok("gh", args) do
      :ok
    end
  end

  @impl true
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    case github_state_action(state_name) do
      :close ->
        with {:ok, _output} <- run_ok("gh", ["issue", "close", issue_id, "--reason", "completed"] ++ repo_args(tracker)) do
          :ok
        end

      :reopen ->
        with {:ok, _output} <- run_ok("gh", ["issue", "reopen", issue_id] ++ repo_args(tracker)) do
          :ok
        end

      :label ->
        with {:ok, _output} <- run_ok("gh", ["issue", "edit", issue_id, "--add-label", state_name] ++ repo_args(tracker)) do
          :ok
        end
    end
  end

  defp issue_list_state(state_names) do
    states = Enum.map(state_names, &normalize_state/1)
    closed? = Enum.any?(states, &(&1 in ["closed", "done", "cancelled", "canceled", "duplicate"]))
    open? = Enum.any?(states, &(&1 in ["open", "todo", "in progress", "active", "review"]))

    cond do
      closed? and open? -> "all"
      closed? -> "closed"
      true -> "open"
    end
  end

  defp github_state_action(state_name) do
    case normalize_state(state_name) do
      state when state in ["closed", "done", "cancelled", "canceled", "duplicate"] -> :close
      state when state in ["open", "todo"] -> :reopen
      _state -> :label
    end
  end

  defp matches_state_or_label?(_issue, []), do: true

  defp matches_state_or_label?(issue, normalized_state_names) do
    normalized_issue_state = normalize_state(issue.state)
    normalized_labels = Enum.map(issue.labels, &normalize_state/1)

    normalized_issue_state in normalized_state_names ||
      Enum.any?(normalized_labels, &(&1 in normalized_state_names))
  end

  defp normalize_issue(%{"number" => number} = raw) do
    id = to_string(number)

    %Issue{
      id: id,
      identifier: "##{id}",
      title: raw["title"],
      description: raw["body"],
      state: github_issue_state(raw["state"]),
      url: raw["url"],
      assignee_id: first_assignee(raw["assignees"]),
      labels: label_names(raw["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(raw["createdAt"]),
      updated_at: parse_datetime(raw["updatedAt"]),
      raw: raw
    }
  end

  defp normalize_issue(raw), do: %Issue{raw: raw}

  defp repo_args(tracker) do
    case repository(tracker) do
      nil -> []
      repo -> ["--repo", repo]
    end
  end

  defp repository(%{repository: repository}) when is_binary(repository) and repository != "", do: repository
  defp repository(%{owner: owner, repo: repo}) when is_binary(owner) and is_binary(repo), do: owner <> "/" <> repo
  defp repository(_tracker), do: System.get_env("GITHUB_REPOSITORY")

  defp run_json(command, args) do
    with {:ok, output} <- run_ok(command, args),
         {:ok, decoded} <- Jason.decode(output) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_ok(command, args) do
    case run_command(command, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, command, status, output}}
    end
  rescue
    error -> {:error, {:command_failed, command, Exception.message(error)}}
  end

  defp run_command(command, args, opts) do
    cmd_runner = Application.get_env(:symphony_elixir, :github_cmd_runner, &System.cmd/3)
    cmd_runner.(command, args, opts)
  end

  defp github_issue_state("CLOSED"), do: "Closed"
  defp github_issue_state("OPEN"), do: "Open"
  defp github_issue_state(state) when is_binary(state), do: String.capitalize(String.downcase(state))
  defp github_issue_state(_state), do: nil

  defp label_names(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} -> name
      _label -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp label_names(_labels), do: []

  defp first_assignee([%{"login" => login} | _rest]) when is_binary(login), do: login
  defp first_assignee(_assignees), do: nil

  defp normalize_state(state_name) do
    state_name
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil
end
