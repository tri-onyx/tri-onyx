defmodule TriOnyx.TriggerRouter do
  @moduledoc """
  GenServer that receives trigger events and dispatches them to agent sessions.

  The trigger router is the central dispatch point for all events that cause
  agent sessions to be invoked. It:

  - Receives trigger events from HTTP endpoints, schedulers, and inter-agent messages
  - Resolves which agent handles each trigger
  - Spawns new agent sessions via AgentSupervisor when needed
  - Forwards trigger payloads to existing sessions as prompts
  - Tracks registered trigger→agent mappings

  The router does NOT make autonomous decisions — it mechanically maps triggers
  to agents based on configuration, and applies the trust level from the trigger
  type to the session's taint tracking.
  """

  use GenServer

  require Logger

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentLoader
  alias TriOnyx.AgentSession
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.Triggers.Scheduler

  @type trigger_type ::
          :cron
          | :heartbeat
          | :webhook
          | :external_message
          | :inter_agent
          | :verified_input
          | :unverified_input

  @type trigger_event :: %{
          type: trigger_type(),
          agent_name: String.t(),
          payload: String.t(),
          metadata: map()
        }

  @type state :: %{
          definitions: %{String.t() => AgentDefinition.t()},
          supervisor: GenServer.server()
        }

  # --- Public API ---

  @doc """
  Starts the TriggerRouter GenServer.

  ## Options

  - `:name` — GenServer name (default: `__MODULE__`)
  - `:supervisor` — AgentSupervisor to use (default: `TriOnyx.AgentSupervisor`)
  - `:definitions` — list of `AgentDefinition` structs to register
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatches a trigger event to the appropriate agent session.

  If no session exists for the agent, one is spawned. The trigger payload
  is sent as a prompt to the agent session.

  Returns `{:ok, session_pid}` on success, or `{:error, reason}` on failure.
  """
  @spec dispatch(GenServer.server(), trigger_event()) ::
          {:ok, pid()} | {:error, term()}
  def dispatch(server \\ __MODULE__, event) do
    GenServer.call(server, {:dispatch, event})
  end

  @doc """
  Registers an agent definition with the router.
  """
  @spec register_agent(GenServer.server(), AgentDefinition.t()) :: :ok
  def register_agent(server \\ __MODULE__, definition) do
    GenServer.call(server, {:register_agent, definition})
  end

  @doc """
  Unregisters an agent definition from the router.
  """
  @spec unregister_agent(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def unregister_agent(server \\ __MODULE__, agent_name) do
    GenServer.call(server, {:unregister_agent, agent_name})
  end

  @doc """
  Returns the list of registered agent definitions.
  """
  @spec list_agents(GenServer.server()) :: [AgentDefinition.t()]
  def list_agents(server \\ __MODULE__) do
    GenServer.call(server, :list_agents)
  end

  @doc """
  Returns the definition for a specific agent, or `:error` if not found.
  """
  @spec get_agent(GenServer.server(), String.t()) :: {:ok, AgentDefinition.t()} | :error
  def get_agent(server \\ __MODULE__, agent_name) do
    GenServer.call(server, {:get_agent, agent_name})
  end

  @doc """
  Loads agent definitions from the configured directory and registers them.
  """
  @spec load_agents(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_agents(server \\ __MODULE__) do
    GenServer.call(server, :load_agents)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)

    definitions =
      opts
      |> Keyword.get(:definitions, [])
      |> Enum.map(fn def -> {def.name, def} end)
      |> Map.new()

    Logger.info("TriggerRouter started with #{map_size(definitions)} agent(s) registered")

    {:ok, %{definitions: definitions, supervisor: supervisor}}
  end

  @impl GenServer
  def handle_call({:dispatch, event}, _from, state) do
    %{type: trigger_type, agent_name: agent_name, payload: payload} = event
    metadata = Map.get(event, :metadata, %{})

    Logger.info(
      "TriggerRouter: dispatching #{trigger_type} trigger to agent '#{agent_name}'"
    )

    case Map.fetch(state.definitions, agent_name) do
      {:ok, definition} ->
        result = ensure_session_and_prompt(state.supervisor, definition, trigger_type, payload, metadata)
        {:reply, result, state}

      :error ->
        Logger.warning("TriggerRouter: no agent registered for '#{agent_name}'")
        {:reply, {:error, {:unknown_agent, agent_name}}, state}
    end
  end

  def handle_call({:register_agent, definition}, _from, state) do
    Logger.info("TriggerRouter: registering agent '#{definition.name}'")
    new_defs = Map.put(state.definitions, definition.name, definition)
    {:reply, :ok, %{state | definitions: new_defs}}
  end

  def handle_call({:unregister_agent, agent_name}, _from, state) do
    if Map.has_key?(state.definitions, agent_name) do
      Logger.info("TriggerRouter: unregistering agent '#{agent_name}'")
      new_defs = Map.delete(state.definitions, agent_name)
      {:reply, :ok, %{state | definitions: new_defs}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_agents, _from, state) do
    {:reply, Map.values(state.definitions), state}
  end

  def handle_call({:get_agent, agent_name}, _from, state) do
    case Map.fetch(state.definitions, agent_name) do
      {:ok, _definition} = result -> {:reply, result, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:load_agents, _from, state) do
    case AgentLoader.load_all() do
      {:ok, definitions} ->
        new_defs =
          definitions
          |> Enum.map(fn def -> {def.name, def} end)
          |> Map.new()

        old_names = MapSet.new(Map.keys(state.definitions))
        new_names = MapSet.new(Map.keys(new_defs))

        added = MapSet.difference(new_names, old_names)
        removed = MapSet.difference(old_names, new_names)
        kept = MapSet.intersection(old_names, new_names)

        unless MapSet.size(added) == 0,
          do: Logger.info("TriggerRouter: added agents: #{Enum.join(added, ", ")}")

        unless MapSet.size(removed) == 0,
          do: Logger.info("TriggerRouter: removed agents: #{Enum.join(removed, ", ")}")

        updated =
          Enum.filter(kept, fn name ->
            Map.get(new_defs, name) != Map.get(state.definitions, name)
          end)

        unless updated == [],
          do: Logger.info("TriggerRouter: updated agents: #{Enum.join(updated, ", ")}")

        changed = MapSet.union(removed, MapSet.new(updated))

        # Cancel crons and heartbeats for removed and updated agents
        Enum.each(changed, fn name ->
          Scheduler.cancel_agent_crons(name)
          Scheduler.cancel_heartbeat(name)
        end)

        # Register crons and heartbeats for added and updated agents
        Enum.each(MapSet.union(added, MapSet.new(updated)), fn name ->
          definition = Map.get(new_defs, name)

          if definition do
            if definition.cron_schedules != [] do
              Scheduler.schedule_agent_crons(name, definition.cron_schedules)
            end

            if definition.heartbeat_every do
              Scheduler.schedule_heartbeat(name, definition.heartbeat_every)
            end
          end
        end)

        register_bcp_subscriptions(new_defs)

        Logger.info("TriggerRouter: loaded #{length(definitions)} agent(s) from disk")
        {:reply, {:ok, length(definitions)}, %{state | definitions: new_defs}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("TriggerRouter: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  defp register_bcp_subscriptions(agents) do
    subscriptions =
      agents
      |> Enum.flat_map(fn {_name, definition} ->
        definition.bcp_channels
        |> Enum.filter(fn ch ->
          ch.role == :controller and Map.get(ch, :subscriptions, []) != []
        end)
        |> Enum.flat_map(fn ch ->
          Enum.map(Map.get(ch, :subscriptions, []), fn sub ->
            %TriOnyx.BCP.Subscription{
              id: sub.id,
              controller: definition.name,
              reader: ch.peer,
              category: sub.category,
              fields: sub.fields,
              questions: sub.questions,
              directive: sub.directive,
              max_words: sub.max_words
            }
          end)
        end)
      end)

    TriOnyx.BCP.Subscription.register_all(subscriptions)

    if subscriptions != [] do
      Logger.info("TriggerRouter: registered #{length(subscriptions)} BCP subscription(s)")
    end
  end

  @spec ensure_session_and_prompt(
          GenServer.server(),
          AgentDefinition.t(),
          trigger_type(),
          String.t(),
          map()
        ) :: {:ok, pid()} | {:error, term()}
  defp ensure_session_and_prompt(supervisor, definition, trigger_type, payload, metadata) do
    session_key = Map.get(metadata, "session_key")

    case AgentSupervisor.find_session(supervisor, definition.name, session_key) do
      {:ok, pid} ->
        Logger.info("TriggerRouter: routing to existing session for '#{definition.name}'")

        case AgentSession.send_prompt(pid, payload, metadata) do
          :ok -> {:ok, pid}
          {:error, _reason} = error -> error
        end

      :error ->
        Logger.info("TriggerRouter: spawning new session for '#{definition.name}'")

        session_opts =
          [definition: definition, trigger_type: trigger_type] ++
            if(session_key, do: [session_key: session_key], else: [])

        case AgentSupervisor.start_session(supervisor, session_opts) do
          {:ok, pid} ->
            # Queue the prompt — the session will flush it once the runtime
            # signals :ready. send_prompt returns :ok when the session
            # accepts the prompt for queuing (status == :starting).
            case AgentSession.send_prompt(pid, payload, metadata) do
              :ok -> {:ok, pid}
              {:error, reason} ->
                Logger.warning(
                  "TriggerRouter: prompt queuing failed for '#{definition.name}': #{inspect(reason)}"
                )
                {:ok, pid}
            end

          {:error, _reason} = error ->
            error
        end
    end
  end
end
