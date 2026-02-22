defmodule TriOnyx.SessionLogger do
  @moduledoc """
  Per-session JSONL logger for the TriOnyx gateway.

  Writes a complete event stream for each agent session to
  `logs/{agent_name}/{session_id}.jsonl`. Each line is a JSON object
  with a `timestamp` field and event-specific data.

  File handles are kept open for the lifetime of the session and
  closed explicitly via `close_session/2` or when the GenServer terminates.
  """

  use GenServer

  require Logger

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Logs an event for the given session. Async cast — never blocks the caller.
  """
  @spec log(String.t(), String.t(), map()) :: :ok
  def log(session_id, agent_name, event) when is_binary(session_id) and is_binary(agent_name) do
    GenServer.cast(__MODULE__, {:log, session_id, agent_name, event})
  end

  @doc """
  Closes the file handle for a session. Call when the session ends.
  """
  @spec close_session(String.t(), String.t()) :: :ok
  def close_session(session_id, agent_name) do
    GenServer.cast(__MODULE__, {:close, session_id, agent_name})
  end

  @doc """
  Lists agent names that have log directories.
  """
  @spec list_agents() :: [String.t()]
  def list_agents do
    log_dir = log_base_dir()

    if File.dir?(log_dir) do
      log_dir
      |> File.ls!()
      |> Enum.filter(fn name ->
        File.dir?(Path.join(log_dir, name))
      end)
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Lists sessions (JSONL files) for a given agent.
  Returns a list of maps with session_id and file size.
  """
  @spec list_sessions(String.t()) :: [map()]
  def list_sessions(agent_name) do
    agent_dir = Path.join(log_base_dir(), agent_name)

    if File.dir?(agent_dir) do
      agent_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.map(fn filename ->
        session_id = String.trim_trailing(filename, ".jsonl")
        path = Path.join(agent_dir, filename)
        stat = File.stat!(path)

        %{
          "session_id" => session_id,
          "size_bytes" => stat.size,
          "modified_at" => NaiveDateTime.to_iso8601(stat.mtime |> NaiveDateTime.from_erl!())
        }
      end)
      |> Enum.sort_by(& &1["modified_at"], :desc)
    else
      []
    end
  end

  @doc """
  Reads the JSONL content for a specific session log file.
  Returns the raw file content as a string.
  """
  @spec read_session(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def read_session(agent_name, session_id) do
    path = session_path(agent_name, session_id)

    if File.exists?(path) do
      {:ok, File.read!(path)}
    else
      {:error, :not_found}
    end
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(_opts) do
    {:ok, %{handles: %{}}}
  end

  @impl GenServer
  def handle_cast({:log, session_id, agent_name, event}, state) do
    key = {agent_name, session_id}

    state =
      if Map.has_key?(state.handles, key) do
        state
      else
        ensure_handle(state, agent_name, session_id)
      end

    entry =
      event
      |> Map.put("timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!()

    case Map.get(state.handles, key) do
      nil ->
        Logger.warning("SessionLogger: no handle for #{agent_name}/#{session_id}, dropping event")
        {:noreply, state}

      handle ->
        IO.write(handle, entry <> "\n")
        {:noreply, state}
    end
  end

  def handle_cast({:close, session_id, agent_name}, state) do
    key = {agent_name, session_id}

    case Map.pop(state.handles, key) do
      {nil, _handles} ->
        {:noreply, state}

      {handle, handles} ->
        File.close(handle)
        Logger.debug("SessionLogger: closed #{agent_name}/#{session_id}")
        {:noreply, %{state | handles: handles}}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("SessionLogger: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.handles, fn {_key, handle} ->
      File.close(handle)
    end)

    :ok
  end

  # --- Private ---

  defp ensure_handle(state, agent_name, session_id) do
    key = {agent_name, session_id}
    path = session_path(agent_name, session_id)
    dir = Path.dirname(path)

    File.mkdir_p!(dir)

    case File.open(path, [:append, :utf8]) do
      {:ok, handle} ->
        Logger.debug("SessionLogger: opened #{path}")
        %{state | handles: Map.put(state.handles, key, handle)}

      {:error, reason} ->
        Logger.error("SessionLogger: failed to open #{path}: #{inspect(reason)}")
        state
    end
  end

  defp session_path(agent_name, session_id) do
    Path.join([log_base_dir(), agent_name, "#{session_id}.jsonl"])
  end

  defp log_base_dir do
    Application.get_env(:tri_onyx, :session_log_dir, "logs")
  end
end
