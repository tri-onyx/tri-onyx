defmodule TriOnyx.RepoStore.Sweeper do
  @moduledoc """
  Custodian of the working trees: tracks which are mounted by a live
  container, and commits the ones no container owns.

  ## Mount claims

  `RepoStore.prepare_session/1` claims the trees it prepared against the
  process that will own the container (the agent port). The claim is held
  in this process's ETS table and released when the claiming process
  exits, so a tree counts as mounted for exactly as long as the container
  holding it lives. `RepoStore.active_principals/0` and
  `RepoStore.ro_mounted?/1` read that table directly — the liveness
  question must be answerable without messaging a session, because both
  session start and session end run inside session processes.

  ## Crash-recovery sweep

  Sessions commit their own changes at session end (`Workspace.commit_session/4`),
  and gateway writers commit synchronously (`Workspace.record_external_write/5`).
  This sweeper only catches what those miss — trees *orphaned* by a
  crashed session or gateway restart — by periodically committing and
  pushing any dirty tree that no live session owns.

  Two rules keep it from interfering with running work or with provenance:

  - **Live trees are never touched.** A tree whose principal holds a mount
    claim is skipped entirely: that session commits its own changes with
    its own labels at session end, and a sweep commit (or the conflict
    reset that can follow one) would run under a live container.
  - **Nothing enters history unlabeled.** An orphaned tree's provenance
    died with its session, so its commit carries the conservative
    `Workspace.unlabeled_levels/0` floor as `Taint-Level`/`Sensitivity-Level`
    trailers and the changed paths are recorded in the risk manifest.

  The shared read-only checkouts (`_ro`) are pure projections of the bare
  repos and are never swept.
  """

  use GenServer

  require Logger

  alias TriOnyx.RepoStore
  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace

  @default_interval_ms :timer.minutes(5)
  @initial_delay_ms :timer.seconds(30)
  @claims_table :tri_onyx_mount_claims

  @typedoc "A claim on the trees mounted into one running container."
  @type claim :: %{pid: pid(), principal: String.t(), ro: [RepoStore.repo_id()]}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Claims the trees `pid` has mounted: its own rw trees (keyed by
  `principal`) and the `_ro` checkouts of `ro_repos`. The claim is dropped
  when `pid` exits. A no-op when the custodian isn't running (unit tests),
  in which case every tree reads as unmounted — the pre-session state.
  """
  @spec claim(pid(), String.t(), [RepoStore.repo_id()]) :: :ok
  def claim(server \\ __MODULE__, pid, principal, ro_repos)
      when is_pid(pid) and is_binary(principal) do
    GenServer.call(server, {:claim, pid, principal, ro_repos})
  catch
    :exit, _ -> :ok
  end

  @doc "The mount claims currently held."
  @spec claims() :: [claim()]
  def claims do
    @claims_table
    |> :ets.tab2list()
    |> Enum.map(fn {pid, principal, ro} -> %{pid: pid, principal: principal, ro: ro} end)
  rescue
    ArgumentError -> []
  end

  @doc "Runs a sweep immediately. Returns the list of swept `{principal, repo_ref}`."
  @spec sweep_now(GenServer.server()) :: [{String.t(), String.t()}]
  def sweep_now(server \\ __MODULE__) do
    GenServer.call(server, :sweep, :timer.minutes(2))
  end

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    :ets.new(@claims_table, [:named_table, :set, :protected, read_concurrency: true])
    Process.send_after(self(), :sweep, Keyword.get(opts, :initial_delay_ms, @initial_delay_ms))
    {:ok, %{interval_ms: interval}}
  end

  @impl GenServer
  def handle_call({:claim, pid, principal, ro_repos}, _from, state) do
    Process.monitor(pid)
    :ets.insert(@claims_table, {pid, principal, ro_repos})
    {:reply, :ok, state}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, do_sweep(), state}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(@claims_table, pid)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    do_sweep()
    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp do_sweep do
    active = RepoStore.active_principals()

    for {principal, repo_id} <- list_trees(),
        not MapSet.member?(active, principal),
        RepoStore.dirty?(principal, repo_id) do
      sweep_tree(principal, repo_id)
      {principal, RepoStore.ref(repo_id)}
    end
  end

  # Commits one orphaned tree at the unlabeled floor. The manifest entry is
  # written only after a successful push — a commit parked on a conflict
  # branch is not on main (same rule as `Workspace.commit_session/4`).
  defp sweep_tree(principal, repo_id) do
    author = if principal == :gw, do: "gateway", else: principal
    {taint, sensitivity} = Workspace.unlabeled_levels()

    changed =
      principal
      |> RepoStore.changed_paths(repo_id)
      |> Enum.reject(&Workspace.temp_file?/1)

    result =
      RepoStore.commit_and_push(principal, repo_id,
        author: author,
        message: "[sweep] orphaned uncommitted changes",
        trailers: ["Taint-Level: #{taint}", "Sensitivity-Level: #{sensitivity}"],
        session_id: "sweep"
      )

    case result do
      {:ok, sha} when is_binary(sha) ->
        if changed != [] do
          canonical = Enum.map(changed, &Workspace.canonical_for_repo(repo_id, &1))
          RiskManifest.put(author, canonical, taint, sensitivity)
        end

        Logger.info(
          "RepoStore.Sweeper: committed #{String.slice(sha, 0, 10)} " <>
            "for #{inspect(principal)}/#{RepoStore.ref(repo_id)} " <>
            "(taint #{taint}, sensitivity #{sensitivity})"
        )

      {:ok, {:conflict, branch}} ->
        Logger.warning(
          "RepoStore.Sweeper: #{inspect(principal)}/#{RepoStore.ref(repo_id)} " <>
            "parked on #{branch} — paths left unlabeled (not on main)"
        )

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "RepoStore.Sweeper: sweep failed for #{inspect(principal)}/" <>
            "#{RepoStore.ref(repo_id)}: #{inspect(reason)}"
        )
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
