defmodule TriOnyx.DefinitionWatcher do
  @moduledoc """
  Watches the agent-definitions directory for file changes and triggers
  a reload of agent definitions into the TriggerRouter.

  Uses `FileSystem` to receive OS-level file change notifications.
  Rapid changes are debounced with a 500ms timer so that multiple saves
  (e.g. from an editor doing write-rename) collapse into a single reload.

  Running sessions keep their frozen definition — only new sessions pick
  up the updated definitions.
  """

  use GenServer

  require Logger

  @debounce_ms 500

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    agents_dir =
      Keyword.get_lazy(opts, :agents_dir, fn ->
        Application.get_env(:tri_onyx, :agents_dir, "./workspace/agent-definitions")
      end)

    expanded = Path.expand(agents_dir)

    case FileSystem.start_link(dirs: [expanded]) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(watcher_pid)
        Logger.info("DefinitionWatcher: watching #{expanded}")
        {:ok, %{watcher_pid: watcher_pid, debounce_ref: nil, dir: expanded}}

      :ignore ->
        Logger.warning("DefinitionWatcher: file watcher unavailable (inotify-tools not installed?)")
        {:ok, %{watcher_pid: nil, debounce_ref: nil, dir: expanded}}

      {:error, reason} ->
        Logger.warning("DefinitionWatcher: failed to start file watcher: #{inspect(reason)}")
        {:ok, %{watcher_pid: nil, debounce_ref: nil, dir: expanded}}
    end
  end

  @impl GenServer
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if agent_definition_file?(path) do
      state = schedule_reload(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("DefinitionWatcher: file watcher stopped")
    {:noreply, %{state | watcher_pid: nil}}
  end

  def handle_info(:reload, state) do
    Logger.info("DefinitionWatcher: reloading agent definitions")

    case TriOnyx.TriggerRouter.load_agents() do
      {:ok, count} ->
        Logger.info("DefinitionWatcher: reload complete, #{count} agent(s) loaded")

      {:error, reason} ->
        Logger.warning("DefinitionWatcher: reload failed: #{inspect(reason)}")
    end

    {:noreply, %{state | debounce_ref: nil}}
  end

  def handle_info(msg, state) do
    Logger.warning("DefinitionWatcher: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  defp agent_definition_file?(path) do
    basename = Path.basename(path)
    String.ends_with?(basename, ".md") and not editor_temp_file?(basename)
  end

  defp editor_temp_file?(basename) do
    String.ends_with?(basename, ".swp") or
      String.ends_with?(basename, "~") or
      String.starts_with?(basename, "#") or
      String.starts_with?(basename, ".")
  end

  defp schedule_reload(state) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    ref = Process.send_after(self(), :reload, @debounce_ms)
    %{state | debounce_ref: ref}
  end
end
