defmodule TriOnyx.AgentSupervisor do
  @moduledoc """
  DynamicSupervisor managing agent session processes.

  Agent sessions are spawned at runtime in response to triggers and
  supervised with a `:temporary` restart strategy — crashed agents are
  not automatically restarted, since each session may carry unique state
  (taint, conversation context) that cannot be safely recovered.

  The supervisor provides operations for:
  - Starting agent sessions from definitions
  - Stopping sessions by name or pid
  - Listing active sessions with their status and risk scores
  """

  use DynamicSupervisor

  require Logger

  alias TriOnyx.AgentSession

  @doc """
  Starts the AgentSupervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new agent session under the supervisor.

  ## Options

  - `:definition` — (required) parsed `AgentDefinition` struct
  - `:trigger_type` — trigger type for risk inference (default: `:external_message`)
  - `:id` — session ID (auto-generated if omitted)

  Returns `{:ok, pid}` on success.
  """
  @spec start_session(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor \\ __MODULE__, opts) do
    definition = Keyword.fetch!(opts, :definition)

    child_spec = %{
      id: AgentSession,
      start: {AgentSession, :start_link, [opts]},
      restart: :temporary,
      shutdown: 10_000
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} = result ->
        Logger.info("Started agent session for '#{definition.name}' (pid=#{inspect(pid)})")
        result

      {:error, reason} = error ->
        Logger.error("Failed to start agent session for '#{definition.name}': #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stops an agent session by pid.
  """
  @spec stop_session(GenServer.server(), pid(), String.t()) :: :ok | {:error, :not_found}
  def stop_session(supervisor \\ __MODULE__, pid, reason \\ "operator requested") do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok ->
        Logger.info("Stopped agent session (pid=#{inspect(pid)}, reason=#{reason})")
        :ok

      {:error, :not_found} = error ->
        Logger.warning("Agent session not found: #{inspect(pid)}")
        error
    end
  end

  @doc """
  Lists all active agent sessions with their current status.

  Returns a list of maps containing session state.
  """
  @spec list_sessions(GenServer.server()) :: [AgentSession.t()]
  def list_sessions(supervisor \\ __MODULE__) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, _modules} when is_pid(pid) ->
        try do
          [AgentSession.get_status(pid)]
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Finds an active session by agent name.

  When `session_key` is provided, matches on the session's stored key
  (e.g. `"concierge:abc123"`) so that multiple concurrent sessions for
  the same agent can be distinguished by external user/channel.

  Returns `{:ok, pid}` if found, `:error` if no session exists for that agent.
  """
  @spec find_session(GenServer.server(), String.t(), String.t() | nil) :: {:ok, pid()} | :error
  def find_session(supervisor \\ __MODULE__, agent_name, session_key \\ nil)
      when is_binary(agent_name) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(:error, fn
      {:undefined, pid, :worker, _modules} when is_pid(pid) ->
        try do
          status = AgentSession.get_status(pid)

          name_match = status.definition.name == agent_name

          key_match =
            if session_key do
              Map.get(status, :session_key) == session_key
            else
              true
            end

          if name_match and key_match do
            {:ok, pid}
          else
            nil
          end
        catch
          :exit, _ -> nil
        end

      _ ->
        nil
    end)
  end

  @doc """
  Returns the count of active sessions.
  """
  @spec count_sessions(GenServer.server()) :: non_neg_integer()
  def count_sessions(supervisor \\ __MODULE__) do
    %{active: active} = DynamicSupervisor.count_children(supervisor)
    active
  end
end
