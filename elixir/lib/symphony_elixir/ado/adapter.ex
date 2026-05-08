defmodule SymphonyElixir.Ado.Adapter do
  @moduledoc """
  Azure DevOps Boards tracker adapter backed by the `az` CLI.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @impl true
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @impl true
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states = state_names |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if states == [] do
      {:ok, []}
    else
      with {:ok, ids} <- query_issue_ids(states) do
        fetch_issue_states_by_ids(ids)
      end
    end
  end

  @impl true
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, issues} ->
      case show_issue(issue_id) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
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
    args = ["boards", "work-item", "update", "--id", issue_id, "--discussion", body, "--output", "json"]

    with {:ok, _output} <- run_ok("az", args ++ az_context_args(Config.settings!().tracker)) do
      :ok
    end
  end

  @impl true
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    args =
      maybe_add_iteration(["boards", "work-item", "update", "--id", issue_id, "--state", state_name]) ++
        ["--output", "json"]

    with {:ok, _output} <- run_ok("az", args ++ az_context_args(Config.settings!().tracker)) do
      :ok
    end
  end

  defp query_issue_ids(states) do
    tracker = Config.settings!().tracker
    wiql = build_wiql(tracker, states)
    args = ["boards", "query", "--wiql", wiql, "--output", "json"] ++ az_context_args(tracker)

    with {:ok, response} <- run_json("az", args) do
      {:ok, extract_work_item_ids(response)}
    end
  end

  defp show_issue(issue_id) do
    args = ["boards", "work-item", "show", "--id", issue_id, "--output", "json"]

    with {:ok, response} <- run_json("az", args ++ az_context_args(Config.settings!().tracker)) do
      {:ok, normalize_issue(response)}
    end
  end

  defp build_wiql(tracker, states) do
    state_clause =
      states
      |> Enum.map_join(", ", &quote_wiql/1)
      |> then(&"[System.State] IN (#{&1})")

    project_clause =
      case tracker.project do
        project when is_binary(project) and project != "" -> " AND [System.TeamProject] = #{quote_wiql(project)}"
        _ -> ""
      end

    "SELECT [System.Id] FROM WorkItems WHERE #{state_clause}#{project_clause} ORDER BY [System.ChangedDate] DESC"
  end

  defp extract_work_item_ids(%{"workItems" => work_items}) when is_list(work_items) do
    work_items
    |> Enum.map(fn
      %{"id" => id} -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_work_item_ids(work_items) when is_list(work_items) do
    work_items
    |> Enum.map(fn
      %{"id" => id} -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_work_item_ids(_response), do: []

  defp normalize_issue(%{"fields" => fields} = raw) when is_map(fields) do
    id = raw["id"] || fields["System.Id"]
    assigned_to = fields["System.AssignedTo"]

    %Issue{
      id: stringify(id),
      identifier: "ADO-#{stringify(id)}",
      title: fields["System.Title"],
      description: fields["System.Description"],
      state: fields["System.State"],
      url: get_in(raw, ["_links", "html", "href"]) || raw["url"],
      assignee_id: assigned_to_value(assigned_to),
      labels: tag_names(fields["System.Tags"]),
      assigned_to_worker: true,
      created_at: parse_datetime(fields["System.CreatedDate"]),
      updated_at: parse_datetime(fields["System.ChangedDate"]),
      raw: raw
    }
  end

  defp normalize_issue(raw), do: %Issue{id: stringify(raw["id"]), raw: raw}

  defp az_context_args(tracker) do
    []
    |> add_arg("--organization", tracker.organization)
    |> add_arg("--project", tracker.project)
  end

  defp add_arg(args, _flag, value) when value in [nil, ""], do: args
  defp add_arg(args, flag, value), do: args ++ [flag, value]

  defp maybe_add_iteration(args) do
    case System.get_env("ADO_ITERATION") do
      iteration when is_binary(iteration) and iteration != "" -> args ++ ["--iteration", iteration]
      _ -> args
    end
  end

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
    cmd_runner = Application.get_env(:symphony_elixir, :ado_cmd_runner, &System.cmd/3)
    cmd_runner.(command, args, opts)
  end

  defp quote_wiql(value) do
    "'" <> String.replace(to_string(value), "'", "''") <> "'"
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)

  defp assigned_to_value(%{"displayName" => display_name}) when is_binary(display_name), do: display_name
  defp assigned_to_value(%{"uniqueName" => unique_name}) when is_binary(unique_name), do: unique_name
  defp assigned_to_value(value) when is_binary(value), do: value
  defp assigned_to_value(_value), do: nil

  defp tag_names(tags) when is_binary(tags) do
    tags
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp tag_names(_tags), do: []

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil
end
