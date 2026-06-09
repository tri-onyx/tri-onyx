defmodule TriOnyx.RiskManifest do
  @moduledoc """
  In-memory store for per-file risk provenance (ADR-008).

  Maps workspace-relative paths to the taint/sensitivity labels recorded
  when the file was last written by an agent. The git history of the
  workspace repository is the durable record — every provenance commit
  carries `Taint-Level`/`Sensitivity-Level` trailers, and human reviews
  carry `Reviewed-Path` trailers — so this store is a derived cache:
  rebuilt from `git log` at boot and kept current by the live writers
  (`Workspace.Committer` for FUSE-observed writes, connectors for
  polled inbox/event files, `Workspace.review_artifacts/2` for reviews).

  Entries keep the same string-keyed shape the JSON manifest file used:

      %{
        "taint_level" => "high",
        "sensitivity_level" => "medium",
        "risk_level" => "high",
        "agent" => "news",
        "updated_at" => "2026-06-09T10:30:00+00:00"
      }

  Reviewed entries additionally carry `"reviewed_by"` and `"reviewed_at"`.

  Lookups read a protected ETS table directly and never touch the
  GenServer, so classification on the agent-event hot path is O(1).
  """

  use GenServer

  require Logger

  alias TriOnyx.Workspace

  @levels ~w(low medium high)

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns `{:ok, entry}` for a workspace-relative path, or `:error` when
  the path has no provenance entry.
  """
  @spec lookup(atom(), String.t()) :: {:ok, map()} | :error
  def lookup(table \\ __MODULE__, path) do
    case :ets.lookup(table, path) do
      [{^path, entry}] -> {:ok, entry}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Returns the full manifest as a `%{path => entry}` map.
  """
  @spec snapshot(atom()) :: map()
  def snapshot(table \\ __MODULE__) do
    table |> :ets.tab2list() |> Map.new()
  rescue
    ArgumentError -> %{}
  end

  @doc """
  Records provenance entries for paths written by an agent. Synchronous,
  so a concurrent reader resolves fresh labels as soon as this returns.
  """
  @spec put(GenServer.server(), String.t(), [String.t()], atom(), atom()) :: :ok
  def put(server \\ __MODULE__, agent_name, paths, taint_level, sensitivity_level) do
    GenServer.call(server, {:put, agent_name, paths, taint_level, sensitivity_level})
  end

  @doc """
  Marks paths as human-reviewed: taint resets to `"low"`, sensitivity is
  kept (reviewing a file does not make its contents less confidential).
  """
  @spec review(GenServer.server(), [String.t()], String.t()) :: :ok
  def review(server \\ __MODULE__, paths, reviewer) do
    GenServer.call(server, {:review, paths, reviewer})
  end

  @doc """
  Drops all entries and rebuilds the manifest from workspace git history.
  """
  @spec reload(GenServer.server()) :: :ok
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload, 60_000)
  end

  @doc """
  Removes all entries (test isolation helper).
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(name, [:named_table, :set, :protected, read_concurrency: true])
    load_from_git(table)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call({:put, agent_name, paths, taint, sensitivity}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    risk = higher_of(taint, sensitivity)

    entries =
      Enum.map(paths, fn path ->
        {path,
         %{
           "taint_level" => to_string(taint),
           "sensitivity_level" => to_string(sensitivity),
           "risk_level" => to_string(risk),
           "agent" => agent_name,
           "updated_at" => now
         }}
      end)

    :ets.insert(state.table, entries)
    {:reply, :ok, state}
  end

  def handle_call({:review, paths, reviewer}, _from, state) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entries =
      Enum.map(paths, fn path ->
        existing =
          case :ets.lookup(state.table, path) do
            [{^path, entry}] -> entry
            [] -> %{}
          end

        sensitivity = Map.get(existing, "sensitivity_level", "low")

        {path,
         Map.merge(existing, %{
           "taint_level" => "low",
           "sensitivity_level" => sensitivity,
           "risk_level" => sensitivity,
           "reviewed_by" => reviewer,
           "reviewed_at" => now
         })}
      end)

    :ets.insert(state.table, entries)
    {:reply, :ok, state}
  end

  def handle_call(:reload, _from, state) do
    :ets.delete_all_objects(state.table)
    load_from_git(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  # --- Git history rebuild ---

  # One %x01-prefixed header line per commit; fields are %x1f-separated and
  # repeated trailer values are %x1e-separated. --name-status lines follow.
  @log_format "%x01%H%x1f%an%x1f%aI" <>
                "%x1f%(trailers:key=Taint-Level,valueonly,separator=%x1e)" <>
                "%x1f%(trailers:key=Sensitivity-Level,valueonly,separator=%x1e)" <>
                "%x1f%(trailers:key=Reviewed-Path,valueonly,separator=%x1e)" <>
                "%x1f%(trailers:key=Reviewed-By,valueonly,separator=%x1e)"

  @spec load_from_git(:ets.table()) :: :ok
  defp load_from_git(table) do
    dir = Workspace.workspace_dir()

    if File.dir?(Path.join(dir, ".git")) do
      safe = Workspace.git_safe_args(dir)
      started = System.monotonic_time(:millisecond)

      case System.cmd(
             "git",
             safe ++ ["log", "--no-renames", "--name-status", "--format=#{@log_format}"],
             cd: dir
           ) do
        {output, 0} ->
          entries = rebuild_entries(output)
          :ets.insert(table, Map.to_list(entries))
          elapsed = System.monotonic_time(:millisecond) - started

          Logger.info(
            "RiskManifest: rebuilt #{map_size(entries)} entries from git history in #{elapsed}ms"
          )

        {output, code} ->
          Logger.warning("RiskManifest: git log failed (exit #{code}): #{String.slice(output, 0, 500)}")
      end
    else
      Logger.info("RiskManifest: no workspace git repository at #{dir}, starting empty")
    end

    :ok
  end

  # Walks commits newest → oldest. The first provenance commit seen for a
  # path wins; a deletion seen first settles the path with no entry; a
  # review seen before the underlying write overlays taint "low" onto it.
  @spec rebuild_entries(String.t()) :: map()
  defp rebuild_entries(log_output) do
    {entries, _reviews, _settled} =
      log_output
      |> String.split(<<0x01>>, trim: true)
      |> Enum.reduce({%{}, %{}, MapSet.new()}, &fold_commit/2)

    entries
  end

  defp fold_commit(block, {entries, reviews, settled} = acc) do
    [header | rest] = String.split(block, "\n")

    case String.split(header, <<0x1F>>) do
      [_hash, author, date, taint_s, sensitivity_s, reviewed_paths_s, reviewed_by_s] ->
        taint = parse_level(taint_s)
        sensitivity = parse_level(sensitivity_s)
        reviewer = first_value(reviewed_by_s) || author

        reviews =
          reviewed_paths_s
          |> String.split(<<0x1E>>, trim: true)
          |> Enum.reduce(reviews, fn path, acc ->
            if MapSet.member?(settled, path) or Map.has_key?(acc, path) do
              acc
            else
              Map.put(acc, path, {reviewer, date})
            end
          end)

        {entries, settled} =
          rest
          |> parse_name_status()
          |> Enum.reduce({entries, settled}, fn
            {_change, ".tri-onyx/" <> _}, inner ->
              inner

            {:deleted, path}, {e, s} ->
              {e, MapSet.put(s, path)}

            {:changed, path}, {e, s} ->
              cond do
                MapSet.member?(s, path) ->
                  {e, s}

                # Commit without provenance trailers (sweep, manual, init):
                # the file's labels come from an older provenance commit,
                # matching the previous manifest-file behaviour.
                is_nil(taint) ->
                  {e, s}

                true ->
                  entry = build_entry(author, date, taint, sensitivity, Map.get(reviews, path))
                  {Map.put(e, path, entry), MapSet.put(s, path)}
              end
          end)

        {entries, reviews, settled}

      _malformed ->
        acc
    end
  end

  @spec parse_name_status([String.t()]) :: [{:changed | :deleted, String.t()}]
  defp parse_name_status(lines) do
    Enum.flat_map(lines, fn line ->
      case String.split(line, "\t", parts: 2) do
        ["D", path] -> [{:deleted, path}]
        [status, path] when status in ~w(A M T) -> [{:changed, path}]
        _ -> []
      end
    end)
  end

  @spec build_entry(String.t(), String.t(), String.t(), String.t() | nil, {String.t(), String.t()} | nil) ::
          map()
  defp build_entry(author, date, taint, sensitivity, review) do
    sensitivity = sensitivity || "low"

    base = %{
      "taint_level" => taint,
      "sensitivity_level" => sensitivity,
      "risk_level" => higher_of_strings(taint, sensitivity),
      "agent" => author,
      "updated_at" => date
    }

    case review do
      nil ->
        base

      {reviewer, reviewed_at} ->
        Map.merge(base, %{
          "taint_level" => "low",
          "risk_level" => sensitivity,
          "reviewed_by" => reviewer,
          "reviewed_at" => reviewed_at
        })
    end
  end

  # First %x1e-separated trailer value, normalized to a known level, or nil.
  @spec parse_level(String.t()) :: String.t() | nil
  defp parse_level(field) do
    case first_value(field) do
      nil ->
        nil

      value ->
        normalized = value |> String.trim() |> String.downcase()
        if normalized in @levels, do: normalized, else: nil
    end
  end

  @spec first_value(String.t()) :: String.t() | nil
  defp first_value(field) do
    field |> String.split(<<0x1E>>, trim: true) |> List.first()
  end

  @spec higher_of(atom(), atom()) :: atom()
  defp higher_of(a, b) do
    rank = %{low: 0, medium: 1, high: 2}
    if (rank[a] || 0) >= (rank[b] || 0), do: a, else: b
  end

  @spec higher_of_strings(String.t(), String.t()) :: String.t()
  defp higher_of_strings(a, b) do
    rank = %{"low" => 0, "medium" => 1, "high" => 2}
    if (rank[a] || 0) >= (rank[b] || 0), do: a, else: b
  end
end
