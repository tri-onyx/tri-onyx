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
  prevents index-lock races between concurrently running sessions.
  Paths whose commit fails stay dirty and are retried on the next
  commit cycle; the `Workspace.Sweeper` remains the backstop for
  anything left over after crashes.
  """

  use GenServer

  require Logger

  alias TriOnyx.Workspace

  @manifest_path ".tri-onyx/risk-manifest.json"
  @default_debounce_ms 5_000

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

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       dirty: %{},
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
          Workspace.update_risk_manifest(agent_name, [path], taint, sensitivity)
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
               [@manifest_path | paths],
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

    state = cancel_timer(%{state | dirty: failed})
    if map_size(failed) > 0, do: schedule_commit(state), else: state
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end
end
