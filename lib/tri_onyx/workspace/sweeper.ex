defmodule TriOnyx.Workspace.Sweeper do
  @moduledoc """
  Periodically commits any uncommitted workspace changes.

  The per-write provenance system (`GitProvenance.record_write/5`) only
  tracks files written through the FUSE path during agent sessions.
  Changes made outside that path — plugin installs, manual edits, file
  deletions — accumulate as dirty state.

  This GenServer runs a sweep on a configurable interval (default 5 min)
  and on startup, calling `Workspace.sweep_uncommitted/0` to stage and
  commit anything left over.
  """

  use GenServer

  require Logger

  @default_interval_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval_ms)

    # Sweep once on startup (after a short delay to let the app finish booting)
    Process.send_after(self(), :sweep, :timer.seconds(10))

    {:ok, %{interval: interval}}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    case TriOnyx.Workspace.sweep_uncommitted() do
      {:ok, :clean} ->
        :ok

      {:ok, hash} ->
        Logger.info("WorkspaceSweeper: committed #{hash}")

      {:error, reason} ->
        Logger.warning("WorkspaceSweeper: sweep failed: #{inspect(reason)}")
    end

    schedule_next(state.interval)
    {:noreply, state}
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
