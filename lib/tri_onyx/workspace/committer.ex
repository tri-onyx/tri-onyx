defmodule TriOnyx.Workspace.Committer do
  @moduledoc """
  Single writer for incremental workspace provenance.

  Agent sessions report each FUSE-observed write as it happens. The
  committer immediately records the writing session's taint and
  sensitivity in the risk manifest — point-in-time labels, so a file
  written before a session's risk escalated keeps the lower label — and
  batches git commits on a debounce interval to bound commit volume.

  Because the manifest is updated synchronously in this process, a
  concurrently running session that reads the file resolves fresh labels
  immediately, closing the provenance window that previously lasted
  until session end.

  Serializing all incremental git operations through one process also
  prevents index-lock races between concurrently running sessions —
  `sweep/1` and `commit_page/3` route the sweeper's and sessions' git
  operations through here for the same reason. Paths whose commit fails
  stay dirty and are retried on later commit cycles, up to
  `@max_commit_attempts`; the `Workspace.Sweeper` remains the backstop
  for anything dropped or left over after crashes.
  """

  use GenServer

  require Logger

  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace

  @default_debounce_ms 5_000

  # A path whose commit keeps failing (e.g. a corrupted index) is dropped
  # after this many attempts so retries can't become a hot loop.
  @max_commit_attempts 5

  # --- Client API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a FUSE-observed write. Updates the risk manifest with the
  session's labels at write time and queues the path for the next
  debounced commit. Atomic-write temp files are ignored.
  """
  @spec record_write(GenServer.server(), String.t(), String.t(), String.t(), atom(), atom()) ::
          :ok
  def record_write(server \\ __MODULE__, agent_name, session_id, path, taint, sensitivity) do
    GenServer.cast(server, {:record_write, agent_name, session_id, path, taint, sensitivity})
  end

  @doc """
  Commits all pending paths immediately. Called at session end so a
  session's writes are durable before its process exits.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush, 30_000)
  end

  @doc """
  Runs a full workspace sweep from inside the committer process, so the
  sweeper's git operations serialize with incremental commits instead of
  racing them for the index.
  """
  @spec sweep(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def sweep(server \\ __MODULE__) do
    GenServer.call(server, :sweep, :timer.minutes(2))
  end

  @doc """
  Commits a single page artifact via `Workspace.commit_page/2`,
  serialized through the committer for the same reason as `sweep/1`.
  """
  @spec commit_page(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def commit_page(server \\ __MODULE__, agent_name, path) do
    GenServer.call(server, {:commit_page, agent_name, path}, 30_000)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       dirty: %{},
       fails: %{},
       timer: nil,
       debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms)
     }}
  end

  @impl GenServer
  def handle_cast({:record_write, agent_name, session_id, path, taint, sensitivity}, state) do
    if Workspace.temp_file?(path) do
      {:noreply, state}
    else
      entry = %{agent: agent_name, session_id: session_id, taint: taint, sensitivity: sensitivity}

      state =
        if state.dirty[path] == entry do
          # Repeat write with unchanged labels — manifest already current.
          state
        else
          RiskManifest.put(agent_name, [path], taint, sensitivity)
          %{state | dirty: Map.put(state.dirty, path, entry)}
        end

      {:noreply, schedule_commit(state)}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, :ok, commit_dirty(state)}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    # Commit tracked dirty paths first so they land with provenance
    # trailers rather than inside the anonymous sweep commit.
    state = commit_dirty(state)
    {:reply, Workspace.sweep_uncommitted(), state}
  end

  @impl GenServer
  def handle_call({:commit_page, agent_name, path}, _from, state) do
    {:reply, Workspace.commit_page(agent_name, path), state}
  end

  @impl GenServer
  def handle_info(:commit, state) do
    {:noreply, commit_dirty(%{state | timer: nil})}
  end

  # --- Private ---

  defp schedule_commit(%{timer: nil} = state) do
    %{state | timer: Process.send_after(self(), :commit, state.debounce_ms)}
  end

  defp schedule_commit(state), do: state

  defp commit_dirty(%{dirty: dirty} = state) when map_size(dirty) == 0 do
    cancel_timer(state)
  end

  defp commit_dirty(state) do
    # One commit per (agent, session, labels) group so each commit's
    # trailers describe every path it contains.
    failed =
      state.dirty
      |> Enum.group_by(fn {_path, e} -> {e.agent, e.session_id, e.taint, e.sensitivity} end)
      |> Enum.reduce(%{}, fn {{agent, session_id, taint, sensitivity}, entries}, failed ->
        paths = Enum.map(entries, fn {path, _} -> path end)

        case Workspace.commit_session(
               agent,
               session_id,
               paths,
               taint,
               sensitivity
             ) do
          {:ok, hash} when is_binary(hash) ->
            Logger.info(
              "Workspace.Committer: committed #{hash} " <>
                "(#{length(paths)} paths, #{agent}/#{session_id})"
            )

            failed

          {:ok, :no_changes} ->
            failed

          {:error, reason} ->
            Logger.warning(
              "Workspace.Committer: commit failed for #{agent}/#{session_id}: #{inspect(reason)}"
            )

            Enum.into(entries, failed)
        end
      end)

    fails = Map.new(failed, fn {path, _} -> {path, Map.get(state.fails, path, 0) + 1} end)

    {dropped, retained} =
      Enum.split_with(failed, fn {path, _} -> fails[path] >= @max_commit_attempts end)

    if dropped != [] do
      Logger.error(
        "Workspace.Committer: dropping #{length(dropped)} path(s) after " <>
          "#{@max_commit_attempts} failed commit attempts (sweeper is the backstop): " <>
          Enum.map_join(dropped, ", ", fn {path, _} -> path end)
      )
    end

    retained = Map.new(retained)
    state = cancel_timer(%{state | dirty: retained, fails: Map.take(fails, Map.keys(retained))})
    if map_size(retained) > 0, do: schedule_commit(state), else: state
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end
end
