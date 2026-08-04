defmodule TriOnyx.RepoStore.Sweeper do
  @moduledoc """
  Crash-recovery backstop for uncommitted working-tree changes.

  Sessions commit their own changes at session end (`Workspace.commit_session/4`),
  and gateway writers commit synchronously (`Workspace.record_external_write/5`).
  This sweeper only catches what those miss — trees left dirty by a
  crashed session or gateway restart — by periodically committing and
  pushing any dirty tree it finds.

  The shared read-only checkouts (`_ro`) are pure projections of the bare
  repos and are never swept.
  """

  use GenServer

  require Logger

  alias TriOnyx.RepoStore

  @default_interval_ms :timer.minutes(5)
  @initial_delay_ms :timer.seconds(30)

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs a sweep immediately. Returns the list of swept `{principal, repo_ref}`."
  @spec sweep_now(GenServer.server()) :: [{String.t(), String.t()}]
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep, :timer.minutes(2))
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    Process.send_after(self(), :sweep, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_call(:sweep, _from, state) do
    {:reply, do_sweep(), state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    do_sweep()
    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp do_sweep do
    for {principal, repo_id} <- list_trees(), RepoStore.dirty?(principal, repo_id) do
      author = if principal == :gw, do: "gateway", else: principal

      case RepoStore.commit_and_push(principal, repo_id,
             author: author,
             message: "[sweep] uncommitted changes",
             session_id: "sweep"
           ) do
        {:ok, sha} when is_binary(sha) ->
          Logger.info(
            "RepoStore.Sweeper: committed #{String.slice(sha, 0, 10)} " <>
              "for #{inspect(principal)}/#{RepoStore.ref(repo_id)}"
          )

        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "RepoStore.Sweeper: sweep failed for #{inspect(principal)}/" <>
              "#{RepoStore.ref(repo_id)}: #{inspect(reason)}"
          )
      end

      {principal, RepoStore.ref(repo_id)}
    end
  end

  # Enumerates (principal, repo_id) pairs from the trees/ directory
  # layout: trees/<agent>/self, trees/<agent>/<shared>, trees/_gw/<shared>.
  # The _ro subtree is skipped by construction.
  defp list_trees do
    trees_root = Path.join(RepoStore.root(), "trees")

    case File.ls(trees_root) do
      {:ok, principals} ->
        principals
        |> Enum.reject(&(&1 == "_ro"))
        |> Enum.flat_map(fn principal_dir ->
          principal = if principal_dir == "_gw", do: :gw, else: principal_dir

          case File.ls(Path.join(trees_root, principal_dir)) do
            {:ok, entries} ->
              Enum.map(entries, fn
                "self" -> {principal, {:agent, principal_dir}}
                shared -> {principal, {:shared, shared}}
              end)

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
