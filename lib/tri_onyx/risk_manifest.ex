defmodule TriOnyx.RiskManifest do
  @moduledoc """
  In-memory store for per-file risk provenance (ADR-008).

  Maps canonical paths (`agents/<name>/<path>` or `shared/<name>/<path>`,
  see `TriOnyx.Workspace.canonical_path/2`) to the taint/sensitivity
  labels recorded when the file was last written. The git history of the
  per-agent/shared repos is the durable record — every session-end commit
  carries `Taint-Level`/`Sensitivity-Level` trailers, and human reviews
  carry `Reviewed-Path` trailers — so this store is a derived cache:
  rebuilt at boot from each repo's `git log` plus the migration snapshot
  file (for provenance predating the repo split), and kept current by
  the live writers (`Workspace.commit_session/4` at session end,
  `Workspace.record_external_write/5` for connector deliveries,
  `Workspace.review_artifacts/2` for reviews).

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

  alias TriOnyx.RepoStore

  @levels ~w(low medium high)

  # Provenance exported from the pre-split workspace repo lands here
  # during migration and seeds paths whose history the fresh repos
  # don't carry.
  @snapshot_file "data/risk-manifest-snapshot.json"

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

  @doc """
  Returns `{max_taint, max_sensitivity, top_prefix}` across all entries
  whose canonical path starts with any of the given prefixes.
  `top_prefix` is the prefix contributing the highest combined risk (nil
  when nothing matched). Used to compute a session's read floor from its
  mounted repos.
  """
  @spec max_labels_for_prefixes(atom(), [String.t()]) :: {atom(), atom(), String.t() | nil}
  def max_labels_for_prefixes(table \\ __MODULE__, prefixes) do
    rank = %{"low" => 0, "medium" => 1, "high" => 2}
    atoms = %{"low" => :low, "medium" => :medium, "high" => :high}

    table
    |> :ets.tab2list()
    |> Enum.reduce({:low, :low, nil}, fn {path, entry}, {taint, sensitivity, top} = acc ->
      case Enum.find(prefixes, &String.starts_with?(path, &1)) do
        nil ->
          acc

        prefix ->
          entry_taint = Map.get(entry, "taint_level", "low")
          entry_sens = Map.get(entry, "sensitivity_level", "low")

          new_taint = if rank[entry_taint] > rank[to_string(taint)], do: atoms[entry_taint], else: taint

          new_sens =
            if rank[entry_sens] > rank[to_string(sensitivity)], do: atoms[entry_sens], else: sensitivity

          new_top =
            if {new_taint, new_sens} != {taint, sensitivity} or is_nil(top), do: prefix, else: top

          {new_taint, new_sens, new_top}
      end
    end)
  rescue
    ArgumentError -> {:low, :low, nil}
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
    started = System.monotonic_time(:millisecond)

    total =
      RepoStore.list_repos()
      |> Enum.reduce(0, fn repo_id, acc ->
        prefix =
          case repo_id do
            {:agent, name} -> "agents/#{name}/"
            {:shared, name} -> "shared/#{name}/"
          end

        case RepoStore.log(repo_id, [
               "--no-renames",
               "--name-status",
               "--format=#{@log_format}"
             ]) do
          {:ok, output} ->
            entries = rebuild_entries(output, prefix)
            :ets.insert(table, Map.to_list(entries))
            acc + map_size(entries)

          {:error, reason} ->
            Logger.warning(
              "RiskManifest: git log failed for #{RepoStore.ref(repo_id)}: #{inspect(reason)}"
            )

            acc
        end
      end)

    snapshot_count = load_snapshot(table)
    elapsed = System.monotonic_time(:millisecond) - started

    Logger.info(
      "RiskManifest: rebuilt #{total} entries from repo histories " <>
        "(+#{snapshot_count} from migration snapshot) in #{elapsed}ms"
    )

    :ok
  end

  # Seeds entries from the migration snapshot for canonical paths the
  # fresh repos have no provenance commits for. Live history always wins.
  @spec load_snapshot(:ets.table()) :: non_neg_integer()
  defp load_snapshot(table) do
    path =
      Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
      |> Path.join(@snapshot_file)

    with {:ok, content} <- File.read(path),
         {:ok, %{} = snapshot} <- Jason.decode(content) do
      snapshot
      |> Enum.reject(fn {key, _entry} -> :ets.member(table, key) end)
      |> Enum.map(fn {key, entry} -> {key, entry} end)
      |> then(fn missing ->
        :ets.insert(table, missing)
        length(missing)
      end)
    else
      {:error, :enoent} -> 0
      other ->
        Logger.warning("RiskManifest: could not load snapshot: #{inspect(other)}")
        0
    end
  end

  @doc """
  Returns the `git log` format string provenance replay expects. Exposed
  for the migration task, which replays the legacy workspace repo.
  """
  @spec log_format() :: String.t()
  def log_format, do: @log_format

  # Walks one repo's commits newest → oldest, prefixing repo-relative
  # paths with the repo's canonical prefix ("agents/<name>/" or
  # "shared/<name>/"). The first provenance commit seen for a path wins;
  # a deletion seen first settles the path with no entry; a review seen
  # before the underlying write overlays taint "low" onto it.
  # Reviewed-Path trailers already carry canonical paths.
  @doc false
  @spec rebuild_entries(String.t(), String.t()) :: map()
  def rebuild_entries(log_output, prefix) do
    {entries, _reviews, _settled} =
      log_output
      |> String.split(<<0x01>>, trim: true)
      |> Enum.reduce({%{}, %{}, MapSet.new()}, &fold_commit(&1, &2, prefix))

    entries
  end

  defp fold_commit(block, {entries, reviews, settled} = acc, prefix) do
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
          |> Enum.map(fn {change, path} -> {change, prefix <> path} end)
          |> Enum.reduce({entries, settled}, fn
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
