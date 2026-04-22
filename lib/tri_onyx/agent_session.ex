defmodule TriOnyx.AgentSession do
  @moduledoc """
  GenServer managing a single agent session lifecycle.

  Each agent session is a BEAM process that:
  - Holds session state (taint and sensitivity levels, risk scores, agent definition)
  - Owns an `AgentPort` process for communicating with the Python runtime
  - Receives prompts from the trigger system and forwards to the port
  - Tracks taint and sensitivity status based on runtime events (tool results, trigger type)
  - Recomputes effective risk when either axis changes

  The session does NOT execute tools or proxy API calls — the agent runs
  autonomously inside its Docker container. Events from the runtime are
  observational and used for taint tracking and audit logging.
  """

  use GenServer

  require Logger

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentPort
  alias TriOnyx.EventBus
  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskScorer
  alias TriOnyx.SensitivityMatrix
  alias TriOnyx.SessionLogger
  alias TriOnyx.ToolRegistry
  alias TriOnyx.BCP
  alias TriOnyx.SystemCommand
  alias TriOnyx.Triggers.InterAgent
  alias TriOnyx.Workspace

  @type t :: %{
          id: String.t(),
          definition: AgentDefinition.t(),
          port: pid() | nil,
          taint_level: InformationClassifier.information_level(),
          sensitivity_level: InformationClassifier.sensitivity_level(),
          information_level: InformationClassifier.information_level(),
          information_sources: [String.t()],
          input_risk: atom(),
          effective_risk: RiskScorer.risk_level(),
          started_at: DateTime.t(),
          status: :starting | :ready | :running | :saving_memory | :stopped,
          workspace_writes: MapSet.t(String.t()),
          trigger_type: atom(),
          last_text: String.t() | nil,
          shutdown_reason: String.t() | nil,
          memory_save_timer: reference() | nil,
          interrupt_prompt: {String.t(), map()} | nil,
          session_key: String.t() | nil,
          mode: :normal | :reflection
        }

  @type start_opt ::
          {:definition, AgentDefinition.t()}
          | {:trigger_type, atom()}
          | {:id, String.t()}
          | {:name, GenServer.name()}
          | {:session_key, String.t()}
          | {:mode, :normal | :reflection}

  # --- Public API ---

  @doc """
  Starts an agent session GenServer.

  ## Required Options

  - `:definition` — parsed `AgentDefinition` struct
  - `:trigger_type` — the trigger type that caused this session to start
    (used for input risk inference)

  ## Optional

  - `:id` — session ID (auto-generated if not provided)
  - `:name` — GenServer name for registration
  """
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sends a prompt to the agent session for processing.
  """
  @spec send_prompt(GenServer.server(), String.t(), map()) :: :ok | {:error, :not_ready}
  def send_prompt(server, content, metadata \\ %{}) do
    GenServer.call(server, {:prompt, content, metadata})
  end

  @doc """
  Delivers a BCP query to this agent's runtime via the port.

  If the session is still starting, the query is queued and flushed when
  the port becomes ready.  Returns `:ok` if accepted, `{:error, :not_ready}`
  if the session is in a state that can't accept queries.
  """
  @spec deliver_bcp_query(GenServer.server(), String.t(), integer(), String.t(), map()) ::
          :ok | {:error, :not_ready}
  def deliver_bcp_query(server, query_id, category, from_agent, spec) do
    GenServer.call(server, {:bcp_query, query_id, category, from_agent, spec})
  end

  @doc """
  Delivers a validated BCP response to this agent's runtime via the port.

  Called by `BCP.Channel` when a reader's response passes gateway validation.
  The response is delivered with `channel_mode: :bcp` metadata so the session
  knows to skip taint elevation.
  """
  @spec deliver_bcp_response(GenServer.server(), String.t(), integer(), String.t(), map(), keyword()) ::
          :ok | {:error, :not_ready}
  def deliver_bcp_response(server, query_id, category, from_agent, response, opts \\ []) do
    GenServer.call(server, {:bcp_response_delivery, query_id, category, from_agent, response, opts})
  end

  @doc """
  Returns the current session state as a map.
  """
  @spec get_status(GenServer.server()) :: t()
  def get_status(server) do
    GenServer.call(server, :get_status)
  end

  @doc """
  Stops the agent session gracefully.

  When the session has an active port and is in `:ready` or `:running` status,
  sends a memory save prompt to the agent before shutting down. The agent has
  30 seconds to save its memory before the shutdown proceeds regardless.
  """
  @spec stop(GenServer.server(), String.t()) :: :ok
  def stop(server, reason \\ "operator requested") do
    GenServer.call(server, {:graceful_stop, reason})
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    definition = Keyword.fetch!(opts, :definition)
    trigger_type = Keyword.get(opts, :trigger_type, :external_message)
    mode = Keyword.get(opts, :mode, :normal)
    session_id = Keyword.get(opts, :id, generate_session_id(mode))
    session_key = Keyword.get(opts, :session_key)

    capability_level = RiskScorer.infer_capability(definition.tools, definition.network, definition)
    input_risk = RiskScorer.infer_input_risk(trigger_type, definition.tools, definition)
    effective_risk = RiskScorer.effective_risk(input_risk, :low, capability_level)

    Logger.info(
      "AgentSession starting: agent=#{definition.name} session=#{session_id} " <>
        "input_risk=#{input_risk} capability=#{capability_level} " <>
        "effective_risk=#{RiskScorer.format_risk(effective_risk)}"
    )

    classification = initial_classification(trigger_type)

    # Apply base_taint as a floor — model provenance risk cannot be lower than declared
    effective_taint = InformationClassifier.higher_level(classification.taint, definition.base_taint)

    # Apply mount sensitivity as a floor — privileged mounts raise baseline sensitivity
    mount_sensitivity = mount_sensitivity_floor(definition)
    effective_sensitivity = InformationClassifier.higher_level(classification.sensitivity, mount_sensitivity)

    state = %{
      id: session_id,
      definition: definition,
      port: nil,
      capability_level: capability_level,
      taint_level: effective_taint,
      sensitivity_level: effective_sensitivity,
      information_level: InformationClassifier.higher_level(effective_taint, effective_sensitivity),
      information_sources:
        mount_sensitivity_sources(definition) ++
        if(effective_taint != :low or classification.sensitivity != :low,
          do: [classification.reason | if(definition.base_taint != :low, do: ["base_taint: #{definition.base_taint}"], else: [])],
          else: if(definition.base_taint != :low, do: ["base_taint: #{definition.base_taint}"], else: [])
        ),
      input_risk: input_risk,
      effective_risk: effective_risk,
      started_at: DateTime.utc_now(),
      status: :starting,
      workspace_writes: MapSet.new(),
      trigger_type: trigger_type,
      last_text: nil,
      pending_prompt: nil,
      pending_tools: %{},
      idle_timer: nil,
      shutdown_reason: nil,
      memory_save_timer: nil,
      interrupt_prompt: nil,
      session_key: session_key,
      mode: mode
    }

    # Log session start
    SessionLogger.log(session_id, definition.name, %{
      "type" => "session_start",
      "agent_name" => definition.name,
      "model" => definition.model,
      "trigger_type" => to_string(trigger_type),
      "input_risk" => to_string(input_risk),
      "capability_level" => to_string(capability_level),
      "effective_risk" => RiskScorer.format_risk(effective_risk)
    })

    # Spawn the port process asynchronously
    {:ok, state, {:continue, :spawn_port}}
  end

  @impl GenServer
  def handle_continue(:spawn_port, state) do
    port_opts = [
      notify: self(),
      definition: state.definition,
      session_id: state.id,
      mode: state.mode
    ]

    Workspace.ensure_agent_dir(state.definition.name)

    # Reflection runs deliberately skip persona assembly — the Python harness
    # uses a hardcoded reflection system prompt and must not see the agent's
    # usual memory/notes/heartbeat.
    workspace_context =
      case state.mode do
        :reflection -> %{}
        _ -> Workspace.read_context(state.definition.name)
      end

    case AgentPort.start_link(port_opts) do
      {:ok, port_pid} ->
        Process.monitor(port_pid)

        # Send start configuration to the runtime
        agent_config = build_agent_config(state.definition, workspace_context, state.mode)
        AgentPort.send_start(port_pid, agent_config)

        {:noreply, %{state | port: port_pid}}

      {:error, reason} ->
        Logger.error("AgentSession: failed to spawn port: #{inspect(reason)}")
        {:stop, {:port_spawn_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:prompt, content, metadata}, _from, %{status: :ready, port: port} = state)
      when port != nil do
    state = state |> cancel_idle_timeout() |> maybe_elevate_from_metadata(metadata)
    broadcast_event(state, %{"type" => "user_prompt", "content" => content})
    AgentPort.send_prompt(port, content, metadata)
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call({:prompt, content, metadata}, _from, %{status: status} = state)
      when status in [:starting] do
    Logger.info("AgentSession #{state.id}: queuing prompt (status=#{status}, #{byte_size(content)} bytes)")
    state = maybe_elevate_from_metadata(state, metadata)
    {:reply, :ok, %{state | pending_prompt: {content, metadata}}}
  end

  def handle_call({:prompt, content, metadata}, _from, %{status: :running, port: port} = state)
      when port != nil do
    Logger.info("AgentSession #{state.id}: interrupting running prompt for new user message")
    AgentPort.send_interrupt(port, "user_message")
    state = maybe_elevate_from_metadata(state, metadata)
    {:reply, :ok, %{state | interrupt_prompt: {content, metadata}}}
  end

  def handle_call({:prompt, _content, _metadata}, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  # BCP query delivery — send directly to port when ready/running, queue when starting
  def handle_call({:bcp_query, query_id, category, from_agent, spec}, _from, %{status: status, port: port} = state)
      when status in [:ready, :running] and port != nil do
    AgentPort.send_bcp_query(port, query_id, category, from_agent, spec)
    {:reply, :ok, state}
  end

  def handle_call({:bcp_query, query_id, category, from_agent, spec}, _from, %{status: :starting} = state) do
    Logger.info("AgentSession #{state.id}: queuing BCP query #{query_id} (starting)")
    pending = Map.get(state, :pending_bcp_queries, [])
    {:reply, :ok, Map.put(state, :pending_bcp_queries, pending ++ [{query_id, category, from_agent, spec}])}
  end

  def handle_call({:bcp_query, _query_id, _category, _from_agent, _spec}, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  # BCP response delivery — send to port when ready (controller is always running)
  def handle_call({:bcp_response_delivery, query_id, category, from_agent, response, opts}, _from,
                  %{status: status, port: port} = state)
      when status in [:ready, :running] and port != nil do
    AgentPort.send_bcp_response_delivery(port, query_id, category, from_agent, response, opts)
    {:reply, :ok, state}
  end

  def handle_call({:bcp_response_delivery, query_id, category, from_agent, response, opts}, _from,
                  %{status: :starting} = state) do
    Logger.info("AgentSession #{state.id}: queuing BCP response delivery #{query_id} (starting)")
    pending = Map.get(state, :pending_bcp_deliveries, [])
    {:reply, :ok, Map.put(state, :pending_bcp_deliveries, pending ++ [{query_id, category, from_agent, response, opts}])}
  end

  def handle_call({:bcp_response_delivery, _query_id, _category, _from_agent, _response, _opts}, _from, state) do
    {:reply, {:error, :not_ready}, state}
  end

  def handle_call({:graceful_stop, reason}, _from, %{status: status, port: port} = state)
      when status in [:ready, :running] and port != nil do
    Logger.info("AgentSession #{state.id}: graceful stop requested, sending memory save (reason: #{reason})")
    state = cancel_idle_timeout(state)
    AgentPort.send_memory_save(port, reason)
    timer_ref = Process.send_after(self(), :memory_save_timeout, 30_000)
    {:reply, :ok, %{state | status: :saving_memory, shutdown_reason: reason, memory_save_timer: timer_ref}}
  end

  def handle_call({:graceful_stop, reason}, _from, state) do
    {:stop, {:shutdown, reason}, :ok, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply,
     Map.take(state, [
       :id,
       :definition,
       :taint_level,
       :sensitivity_level,
       :information_level,
       :information_sources,
       :input_risk,
       :effective_risk,
       :started_at,
       :status,
       :session_key
     ]), state}
  end

  @impl GenServer
  def handle_info({:agent_event, _port_pid, event}, state) do
    handle_agent_event(event, state)
  end

  def handle_info(:idle_timeout, %{port: port} = state) when port != nil do
    Logger.info("AgentSession #{state.id}: idle timeout reached, sending memory save before shutdown")
    broadcast_event(state, %{"type" => "idle_timeout"})
    AgentPort.send_memory_save(port, "idle timeout")
    timer_ref = Process.send_after(self(), :memory_save_timeout, 30_000)
    {:noreply, %{state | status: :saving_memory, shutdown_reason: "idle timeout", memory_save_timer: timer_ref, idle_timer: nil}}
  end

  def handle_info(:idle_timeout, state) do
    Logger.info("AgentSession #{state.id}: idle timeout reached, stopping (no port)")
    broadcast_event(state, %{"type" => "idle_timeout"})
    {:stop, {:shutdown, "idle timeout"}, state}
  end

  def handle_info(:memory_save_timeout, %{status: :saving_memory} = state) do
    Logger.warning("AgentSession #{state.id}: memory save timed out, proceeding with shutdown")
    AgentPort.send_shutdown(state.port, state.shutdown_reason)
    {:stop, {:shutdown, state.shutdown_reason}, state}
  end

  def handle_info({:DOWN, _ref, :process, port_pid, reason}, %{port: port_pid} = state) do
    Logger.warning("AgentSession: port process down: #{inspect(reason)}")
    broadcast_event(state, %{"type" => "port_down", "reason" => inspect(reason)})
    {:noreply, %{state | port: nil, status: :stopped}}
  end

  def handle_info(msg, state) do
    Logger.warning("AgentSession: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, %{port: port} = state) when is_pid(port) do
    Logger.info("AgentSession terminating: #{inspect(reason)}")
    log_session_stop(state, reason)
    AgentPort.send_shutdown(port, "session terminating")
    :ok
  end

  def terminate(reason, state) do
    Logger.info("AgentSession terminating: #{inspect(reason)}")
    log_session_stop(state, reason)
    :ok
  end

  # --- Event Handlers ---

  @spec handle_agent_event(AgentPort.event(), t()) :: {:noreply, t()}
  defp handle_agent_event({:ready}, state) do
    Logger.info("AgentSession #{state.id}: runtime ready")
    broadcast_event(state, %{"type" => "ready"})

    state = %{state | status: :ready}

    # Flush any BCP queries that arrived while the runtime was starting
    {state, had_bcp_queries} =
      case Map.get(state, :pending_bcp_queries, []) do
        [] -> {state, false}
        queries ->
          Enum.each(queries, fn {query_id, category, from_agent, spec} ->
            Logger.info("AgentSession #{state.id}: flushing queued BCP query #{query_id}")
            AgentPort.send_bcp_query(state.port, query_id, category, from_agent, spec)
          end)
          {Map.delete(state, :pending_bcp_queries), true}
      end

    # Flush any BCP response deliveries that arrived while the runtime was starting
    {state, had_bcp_deliveries} =
      case Map.get(state, :pending_bcp_deliveries, []) do
        [] -> {state, false}
        deliveries ->
          Enum.each(deliveries, fn {query_id, category, from_agent, response, opts} ->
            Logger.info("AgentSession #{state.id}: flushing queued BCP response delivery #{query_id}")
            AgentPort.send_bcp_response_delivery(state.port, query_id, category, from_agent, response, opts)
          end)
          {Map.delete(state, :pending_bcp_deliveries), true}
      end

    had_bcp = had_bcp_queries or had_bcp_deliveries

    # Notify Reader agents of any active BCP subscriptions targeting them
    send_subscriptions_active(state)

    # Flush any prompt that arrived while the runtime was starting.
    # If BCP queries/deliveries were flushed, discard the trigger prompt — the BCP
    # message already contains the full spec and the runtime formats
    # it into a proper prompt.  Sending the trigger payload too would
    # override the structured content with a useless summary string.
    case state.pending_prompt do
      {content, metadata} when had_bcp == false ->
        Logger.info("AgentSession #{state.id}: flushing queued prompt (#{byte_size(content)} bytes)")
        broadcast_event(state, %{"type" => "user_prompt", "content" => content})
        AgentPort.send_prompt(state.port, content, metadata)
        {:noreply, %{state | status: :running, pending_prompt: nil}}

      {_content, _metadata} ->
        Logger.info("AgentSession #{state.id}: discarding trigger prompt (BCP messages already flushed)")
        {:noreply, %{state | status: :running, pending_prompt: nil}}

      nil when state.mode == :reflection ->
        {:noreply, state}

      nil ->
        {:noreply, schedule_idle_timeout(state)}
    end
  end

  defp handle_agent_event({:interrupted, reason}, state) do
    Logger.info("AgentSession #{state.id}: runtime interrupted (reason=#{reason})")
    broadcast_event(state, %{"type" => "interrupted", "reason" => reason})

    state = %{state | status: :ready}

    case state.interrupt_prompt do
      {content, metadata} ->
        prefixed = "[Previous task was interrupted by user]\n\n" <> content
        Logger.info("AgentSession #{state.id}: sending queued interrupt prompt (#{byte_size(prefixed)} bytes)")
        broadcast_event(state, %{"type" => "user_prompt", "content" => prefixed})
        AgentPort.send_prompt(state.port, prefixed, metadata)
        {:noreply, %{state | status: :running, interrupt_prompt: nil}}

      nil ->
        {:noreply, schedule_idle_timeout(state)}
    end
  end

  defp handle_agent_event({:text, content}, state) do
    Logger.debug("AgentSession #{state.id}: text output (#{byte_size(content)} bytes)")
    broadcast_event(state, %{"type" => "text", "content" => content})
    {:noreply, %{state | last_text: content}}
  end

  defp handle_agent_event({:tool_use, id, name, input}, state) do
    Logger.info("AgentSession #{state.id}: tool_use #{name} (#{id})")
    broadcast_event(state, %{"type" => "tool_use", "id" => id, "name" => name, "input" => input})
    {:noreply, %{state | pending_tools: Map.put(state.pending_tools, id, {name, input})}}
  end

  defp handle_agent_event({:tool_result, id, content, is_error}, state) do
    # Look up the tool name from pending_tools before popping it so we can
    # include it in the broadcast (connectors use it for formatted display).
    tool_name = case Map.get(state.pending_tools, id) do
      {name, _input} -> name
      nil -> ""
    end

    broadcast_event(state, %{
      "type" => "tool_result",
      "id" => id,
      "name" => tool_name,
      "content" => content,
      "is_error" => is_error
    })

    # Classify tool result using the tool name tracked from the tool_use event
    {state, _} =
      case Map.pop(state.pending_tools, id) do
        {{tool_name, tool_input}, remaining_tools} ->
          state = %{state | pending_tools: remaining_tools}
          tool_meta = ToolRegistry.tool_meta(tool_name)
          classification = InformationClassifier.classify_tool_result(tool_name, tool_input, tool_meta)
          state = elevate_risk(state, classification)

          # Record git provenance for write tools (async, non-blocking)
          if is_error != true and tool_name in ["Write", "Edit", "NotebookEdit"] do
            maybe_record_provenance(tool_name, tool_input, state)
          end

          {state, nil}

        {nil, _} ->
          {state, nil}
      end

    {:noreply, state}
  end

  defp handle_agent_event({:send_message_request, req_id, to, msg_type, payload}, state) do
    Logger.info(
      "AgentSession #{state.id}: send_message_request to=#{to} type=#{msg_type}"
    )

    # Route asynchronously to avoid GenServer deadlock: InterAgent.route()
    # calls find_session() → get_status() on ALL sessions, which would
    # deadlock when it reaches the sender's own GenServer (this process).
    port = state.port
    from_name = state.definition.name
    session_id = state.id

    Task.start(fn ->
      message = %{
        from: from_name,
        to: to,
        message_type: msg_type,
        payload: payload
      }

      case InterAgent.route(message) do
        {:ok, _pid} ->
          AgentPort.send_message_response(port, req_id, true, "delivered")
          Logger.info("AgentSession #{session_id}: message delivered to #{to}")

        {:error, reason} ->
          detail = inspect(reason)
          AgentPort.send_message_response(port, req_id, false, detail)
          Logger.warning("AgentSession #{session_id}: message to #{to} rejected: #{detail}")
      end
    end)

    broadcast_event(state, %{
      "type" => "send_message",
      "from" => state.definition.name,
      "to" => to,
      "message_type" => msg_type,
      "status" => "routing"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:submit_item_request, req_id, item_type, title, url, metadata}, state) do
    Logger.info(
      "AgentSession #{state.id}: submit_item_request type=#{item_type} title=#{title}"
    )

    # Validate required fields
    if item_type == "" or title == "" or url == "" do
      AgentPort.send_submit_item_response(
        state.port, req_id, false, "type, title, and url are required"
      )
    else
      # Respond immediately — the item will be delivered asynchronously via EventBus
      AgentPort.send_submit_item_response(state.port, req_id, true, "")

      item_event = Map.merge(%{
        "type" => item_type,
        "agent_name" => state.definition.name,
        "title" => title,
        "url" => url
      }, metadata)

      broadcast_event(state, item_event)

      # For non-interactive sessions (heartbeat, cron, etc.) no connector is
      # subscribed to this session's EventBus, so also push via
      # broadcast_to_connectors so the item reaches Matrix/Slack.
      if state.trigger_type not in [:verified_input, :unverified_input] do
        TriOnyx.ConnectorHandler.broadcast_to_connectors(Jason.encode!(item_event))
      end
    end

    {:noreply, state}
  end

  defp handle_agent_event({:bcp_query_request, req_id, to, category, spec}, state) do
    Logger.info(
      "AgentSession #{state.id}: bcp_query_request to=#{to} cat=#{category} req_id=#{req_id}"
    )

    # Route asynchronously to avoid GenServer deadlock (same pattern as :send_message_request)
    from_name = state.definition.name

    port = state.port

    Task.start(fn ->
      # Pass the runtime's request_id as the query id so the response delivery
      # matches what the controller's runtime is waiting for
      query_spec = Map.merge(spec, %{category: category, session_id: state.id, id: req_id})

      case BCP.Channel.send_query(from_name, to, query_spec) do
        {:ok, query} ->
          Logger.info("AgentSession: BCP query #{query.id} dispatched to #{to}")

        {:error, reason} ->
          Logger.warning("AgentSession: BCP query to #{to} failed: #{inspect(reason)}")
          AgentPort.send_bcp_query_error(port, req_id, to, format_bcp_error(reason))
      end
    end)

    broadcast_event(state, %{
      "type" => "bcp_query",
      "from" => state.definition.name,
      "to" => to,
      "category" => category,
      "status" => "routing"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:bcp_response, query_id, response}, state) do
    Logger.info(
      "AgentSession #{state.id}: bcp_response for query=#{query_id}"
    )

    # Look up the pending query and route through the channel for validation
    # and delivery to the controller.  Send validation result back to the
    # reader's runtime so BCPRespond can give the agent feedback.
    port = state.port

    Task.start(fn ->
      case BCP.Channel.pop_query(query_id) do
        {:ok, query} ->
          case BCP.Channel.receive_response(query, response) do
            {:ok, _validated} ->
              Logger.info("AgentSession: BCP response for query #{query_id} validated and delivered")
              AgentPort.send_bcp_validation_result(port, query_id, true, "validated and delivered")

            {:error, reason} ->
              Logger.warning("AgentSession: BCP response for query #{query_id} rejected: #{inspect(reason)}")
              AgentPort.send_bcp_validation_result(port, query_id, false, inspect(reason))
          end

        :error ->
          Logger.warning("AgentSession: BCP response for unknown query #{query_id} (not in pending queries)")
          AgentPort.send_bcp_validation_result(port, query_id, false, "unknown query_id")
      end
    end)

    broadcast_event(state, %{
      "type" => "bcp_response",
      "query_id" => query_id,
      "status" => "validating"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:bcp_subscription_publish, subscription_id, controller, response}, state) do
    Logger.info(
      "AgentSession #{state.id}: bcp_subscription_publish sub=#{subscription_id} controller=#{controller}"
    )

    reader_name = state.definition.name
    port = state.port

    Task.start(fn ->
      case BCP.Subscription.lookup(reader_name, subscription_id) do
        {:ok, sub} ->
          if sub.controller != controller do
            Logger.warning(
              "BCP subscription publish: controller mismatch for #{subscription_id}, " <>
                "expected #{sub.controller}, got #{controller}"
            )

            AgentPort.send_bcp_validation_result(
              port,
              nil,
              false,
              "Controller mismatch: expected #{sub.controller}, got #{controller}",
              subscription_id
            )
          else
            case BCP.Subscription.to_query(sub) do
              {:ok, query} ->
                case BCP.Channel.receive_response(query, response,
                       subscription_id: sub.id
                     ) do
                  {:ok, _validated} ->
                    AgentPort.send_bcp_validation_result(
                      port,
                      nil,
                      true,
                      "Published to controller #{controller}",
                      subscription_id
                    )

                  {:error, reason} ->
                    AgentPort.send_bcp_validation_result(
                      port,
                      nil,
                      false,
                      "Validation failed: #{inspect(reason)}",
                      subscription_id
                    )
                end

              {:error, reason} ->
                AgentPort.send_bcp_validation_result(
                  port,
                  nil,
                  false,
                  "Invalid subscription spec: #{inspect(reason)}",
                  subscription_id
                )
            end
          end

        :error ->
          Logger.warning(
            "BCP subscription publish: unknown subscription #{subscription_id} for reader #{reader_name}"
          )

          AgentPort.send_bcp_validation_result(
            port,
            nil,
            false,
            "No active subscription '#{subscription_id}' from controller '#{controller}'",
            subscription_id
          )
      end
    end)

    broadcast_event(state, %{
      "type" => "bcp_subscription_publish",
      "subscription_id" => subscription_id,
      "controller" => controller,
      "status" => "validating"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:send_email_request, req_id, draft_path}, state) do
    Logger.info("AgentSession #{state.id}: send_email_request draft=#{draft_path}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])

    # Translate agent path (/workspace/...) to host path
    host_path =
      draft_path
      |> String.replace_prefix("/workspace/agents/#{state.definition.name}/", "")
      |> then(&Path.join(agent_dir, &1))
      |> Path.expand()

    # Validate path is within agent workspace (prevent path traversal)
    expanded_agent_dir = Path.expand(agent_dir)

    if String.starts_with?(host_path, expanded_agent_dir) do
      port = state.port
      session_id = state.id
      agent_name = state.definition.name

      Task.start(fn ->
        proceed =
          if ToolRegistry.requires_approval?("SendEmail") do
            # Read draft for approval context
            draft_summary = read_draft_summary(host_path)

            {:ok, approval_id} =
              BCP.ApprovalQueue.submit(%{
                kind: "action",
                agent_name: agent_name,
                session_id: session_id,
                tool_name: "SendEmail",
                tool_input: Map.merge(%{"draft_path" => draft_path}, draft_summary)
              })

            approval_frame =
              Jason.encode!(%{
                "type" => "approval_request",
                "approval_id" => approval_id,
                "kind" => "action",
                "from_agent" => agent_name,
                "to_agent" => "",
                "category" => 0,
                "query_summary" => "SendEmail: #{Map.get(draft_summary, "subject", draft_path)}",
                "response_content" => format_draft_for_approval(draft_summary),
                "anomalies" => []
              })

            TriOnyx.ConnectorHandler.broadcast_to_connectors(approval_frame)

            case BCP.ApprovalQueue.await_decision(BCP.ApprovalQueue, approval_id) do
              {:approved, _item} -> :proceed
              {:rejected, reason} -> {:rejected, reason}
              {:error, :timeout} -> {:rejected, "approval timed out"}
            end
          else
            :proceed
          end

        case proceed do
          :proceed ->
            case TriOnyx.Connectors.Email.send_email(host_path) do
              {:ok, message_id} ->
                AgentPort.send_send_email_response(port, req_id, true, "sent", message_id)

              {:error, reason} ->
                AgentPort.send_send_email_response(port, req_id, false, reason)
            end

          {:rejected, reason} ->
            AgentPort.send_send_email_response(port, req_id, false, "approval rejected: #{reason}")
        end
      end)

      broadcast_event(state, %{
        "type" => "send_email",
        "agent_name" => state.definition.name,
        "draft_path" => draft_path,
        "status" => "pending_approval"
      })
    else
      AgentPort.send_send_email_response(state.port, req_id, false, "path traversal rejected")
    end

    {:noreply, state}
  end

  defp handle_agent_event({:save_draft_request, req_id, draft_path}, state) do
    Logger.info("AgentSession #{state.id}: save_draft_request draft=#{draft_path}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])

    host_path =
      draft_path
      |> String.replace_prefix("/workspace/agents/#{state.definition.name}/", "")
      |> then(&Path.join(agent_dir, &1))
      |> Path.expand()

    expanded_agent_dir = Path.expand(agent_dir)

    if String.starts_with?(host_path, expanded_agent_dir) do
      port = state.port

      Task.start(fn ->
        case TriOnyx.Connectors.Email.save_draft(host_path) do
          {:ok, :saved} ->
            AgentPort.send_save_draft_response(port, req_id, true, "draft saved to IMAP Drafts")

          {:error, reason} ->
            AgentPort.send_save_draft_response(port, req_id, false, reason)
        end
      end)
    else
      AgentPort.send_save_draft_response(state.port, req_id, false, "path traversal rejected")
    end

    {:noreply, state}
  end

  defp handle_agent_event({:move_email_request, req_id, uid, source_folder, dest_folder}, state) do
    Logger.info(
      "AgentSession #{state.id}: move_email_request uid=#{uid} " <>
        "#{source_folder} -> #{dest_folder}"
    )

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])
    port = state.port

    Task.start(fn ->
      case TriOnyx.Connectors.Email.move_email(uid, source_folder, dest_folder, agent_dir) do
        {:ok, :moved} ->
          AgentPort.send_move_email_response(port, req_id, true, "moved")

        {:error, reason} ->
          AgentPort.send_move_email_response(port, req_id, false, reason)
      end
    end)

    broadcast_event(state, %{
      "type" => "move_email",
      "agent_name" => state.definition.name,
      "uid" => uid,
      "source_folder" => source_folder,
      "dest_folder" => dest_folder,
      "status" => "moving"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:create_folder_request, req_id, folder_name}, state) do
    Logger.info("AgentSession #{state.id}: create_folder_request folder=#{folder_name}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])
    port = state.port

    Task.start(fn ->
      case TriOnyx.Connectors.Email.create_folder(folder_name, agent_dir) do
        {:ok, :created} ->
          AgentPort.send_create_folder_response(port, req_id, true, "created")

        {:error, reason} ->
          AgentPort.send_create_folder_response(port, req_id, false, reason)
      end
    end)

    broadcast_event(state, %{
      "type" => "create_folder",
      "agent_name" => state.definition.name,
      "folder_name" => folder_name,
      "status" => "creating"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:calendar_query_request, req_id, params}, state) do
    Logger.info("AgentSession #{state.id}: calendar_query_request params=#{inspect(params)}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])
    port = state.port

    Task.start(fn ->
      case TriOnyx.Connectors.Calendar.calendar_query(agent_dir, params) do
        {:ok, events} ->
          AgentPort.send_calendar_query_response(port, req_id, true, "#{length(events)} events", events)

        {:error, reason} ->
          AgentPort.send_calendar_query_response(port, req_id, false, reason)
      end
    end)

    broadcast_event(state, %{
      "type" => "calendar_query",
      "agent_name" => state.definition.name,
      "params" => params,
      "status" => "querying"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:calendar_create_request, req_id, draft_path}, state) do
    Logger.info("AgentSession #{state.id}: calendar_create_request draft=#{draft_path}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])

    host_path =
      draft_path
      |> String.replace_prefix("/workspace/agents/#{state.definition.name}/", "")
      |> then(&Path.join(agent_dir, &1))
      |> Path.expand()

    expanded_agent_dir = Path.expand(agent_dir)

    if String.starts_with?(host_path, expanded_agent_dir) do
      port = state.port

      Task.start(fn ->
        case TriOnyx.Connectors.Calendar.calendar_create(host_path) do
          {:ok, event} ->
            # Write event file to agent workspace
            calendar = event["calendar"]
            uid = event["uid"]
            events_dir = Path.join([agent_dir, "events", calendar])
            File.mkdir_p!(events_dir)
            safe_uid = String.replace(uid, ~r/[^\w.\-@]/, "_") |> String.slice(0, 200)
            event_path = Path.join(events_dir, "#{safe_uid}.json")
            File.write!(event_path, Jason.encode!(event, pretty: true))

            AgentPort.send_calendar_create_response(port, req_id, true, "created", event)

          {:error, reason} ->
            AgentPort.send_calendar_create_response(port, req_id, false, reason)
        end
      end)

      broadcast_event(state, %{
        "type" => "calendar_create",
        "agent_name" => state.definition.name,
        "draft_path" => draft_path,
        "status" => "creating"
      })
    else
      AgentPort.send_calendar_create_response(state.port, req_id, false, "path traversal rejected")
    end

    {:noreply, state}
  end

  defp handle_agent_event({:calendar_update_request, req_id, draft_path}, state) do
    Logger.info("AgentSession #{state.id}: calendar_update_request draft=#{draft_path}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])

    host_path =
      draft_path
      |> String.replace_prefix("/workspace/agents/#{state.definition.name}/", "")
      |> then(&Path.join(agent_dir, &1))
      |> Path.expand()

    expanded_agent_dir = Path.expand(agent_dir)

    if String.starts_with?(host_path, expanded_agent_dir) do
      port = state.port

      Task.start(fn ->
        case TriOnyx.Connectors.Calendar.calendar_update(host_path) do
          {:ok, event} ->
            # Write updated event file
            calendar = event["calendar"]
            uid = event["uid"]
            if calendar != "" and uid do
              events_dir = Path.join([agent_dir, "events", calendar])
              File.mkdir_p!(events_dir)
              safe_uid = String.replace(uid, ~r/[^\w.\-@]/, "_") |> String.slice(0, 200)
              event_path = Path.join(events_dir, "#{safe_uid}.json")
              File.write!(event_path, Jason.encode!(event, pretty: true))
            end

            AgentPort.send_calendar_update_response(port, req_id, true, "updated", event)

          {:error, reason} ->
            AgentPort.send_calendar_update_response(port, req_id, false, reason)
        end
      end)

      broadcast_event(state, %{
        "type" => "calendar_update",
        "agent_name" => state.definition.name,
        "draft_path" => draft_path,
        "status" => "updating"
      })
    else
      AgentPort.send_calendar_update_response(state.port, req_id, false, "path traversal rejected")
    end

    {:noreply, state}
  end

  defp handle_agent_event({:calendar_delete_request, req_id, uid, calendar}, state) do
    Logger.info("AgentSession #{state.id}: calendar_delete_request uid=#{uid} calendar=#{calendar}")

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    agent_dir = Path.join([workspace_dir, "agents", state.definition.name])
    port = state.port

    Task.start(fn ->
      case TriOnyx.Connectors.Calendar.calendar_delete(uid, calendar, agent_dir) do
        {:ok, :deleted} ->
          AgentPort.send_calendar_delete_response(port, req_id, true, "deleted")

        {:error, reason} ->
          AgentPort.send_calendar_delete_response(port, req_id, false, reason)
      end
    end)

    broadcast_event(state, %{
      "type" => "calendar_delete",
      "agent_name" => state.definition.name,
      "uid" => uid,
      "calendar" => calendar,
      "status" => "deleting"
    })

    {:noreply, state}
  end

  defp handle_agent_event({:restart_agent_request, req_id, agent_name, force}, state) do
    Logger.info(
      "AgentSession #{state.id}: restart_agent_request agent=#{agent_name} force=#{force}"
    )

    # Authorization check: agent must be in restart_targets
    unless agent_name in state.definition.restart_targets do
      AgentPort.send_restart_agent_response(
        state.port,
        req_id,
        false,
        "agent '#{agent_name}' is not in restart_targets"
      )

      broadcast_event(state, %{
        "type" => "restart_agent",
        "from" => state.definition.name,
        "target" => agent_name,
        "force" => force,
        "status" => "rejected",
        "reason" => "not in restart_targets"
      })
    else
      # Route asynchronously to avoid GenServer deadlock (same pattern as SendMessage)
      port = state.port
      session_id = state.id
      from_name = state.definition.name

      Task.start(fn ->
        case SystemCommand.execute(:restart, [agent_name], %{}, force: force) do
          {:ok, detail} ->
            AgentPort.send_restart_agent_response(port, req_id, true, detail)
            Logger.info("AgentSession #{session_id}: restart of #{agent_name} initiated: #{detail}")

          {:error, detail} ->
            AgentPort.send_restart_agent_response(port, req_id, false, detail)
            Logger.warning("AgentSession #{session_id}: restart of #{agent_name} failed: #{detail}")
        end
      end)

      broadcast_event(state, %{
        "type" => "restart_agent",
        "from" => from_name,
        "target" => agent_name,
        "force" => force,
        "status" => "routing"
      })
    end

    {:noreply, state}
  end

  defp handle_agent_event({:fuse_write, _op, path}, state) do
    # Strip leading slash and track the written path for session commit
    clean_path = String.trim_leading(path, "/")
    Logger.debug("AgentSession #{state.id}: fuse write: #{clean_path}")
    {:noreply, %{state | workspace_writes: MapSet.put(state.workspace_writes, clean_path)}}
  end

  defp handle_agent_event({:result, metadata}, state) do
    Logger.info(
      "AgentSession #{state.id}: session complete " <>
        "(turns=#{metadata.num_turns}, duration=#{metadata.duration_ms}ms, " <>
        "cost=$#{metadata.cost_usd})"
    )

    broadcast_event(state, %{
      "type" => "result",
      "model" => state.definition.model,
      "num_turns" => metadata.num_turns,
      "duration_ms" => metadata.duration_ms,
      "cost_usd" => metadata.cost_usd,
      "input_tokens" => metadata.input_tokens,
      "output_tokens" => metadata.output_tokens,
      "cache_creation_input_tokens" => metadata.cache_creation_input_tokens,
      "cache_read_input_tokens" => metadata.cache_read_input_tokens
    })

    # Classify heartbeat result
    if state.trigger_type == :heartbeat do
      classification =
        if state.last_text && String.contains?(state.last_text, "HEARTBEAT_OK"),
          do: "ok",
          else: "alert"

      Logger.info(
        "AgentSession #{state.id}: heartbeat result=#{classification} " <>
          "agent=#{state.definition.name}"
      )

      broadcast_event(state, %{
        "type" => "heartbeat_result",
        "classification" => classification,
        "agent_name" => state.definition.name,
        "last_text" => state.last_text
      })

      # Push heartbeat text to connected connectors (Matrix, Slack, etc.)
      # Skip when saving_memory to avoid sending internal memory-save text.
      if state.last_text && classification != "ok" && state.status != :saving_memory do
        frame =
          Jason.encode!(%{
            "type" => "heartbeat_notification",
            "agent_name" => state.definition.name,
            "session_id" => state.id,
            "content" => state.last_text
          })

        TriOnyx.ConnectorHandler.broadcast_to_connectors(frame)
      end
    end

    # Push result text to connectors for non-heartbeat, non-interactive agents
    # (cron, inter-agent, webhook). Interactive sessions (verified/unverified
    # input from connectors) already deliver text via EventBus subscriptions,
    # so broadcasting here would duplicate the message.
    # Skip when saving_memory — the memory-save result is internal and should
    # not be pushed to chat (otherwise users see a duplicate/garbled message).
    if state.trigger_type not in [:heartbeat, :verified_input, :unverified_input] &&
         state.status != :saving_memory &&
         state.last_text do
      frame =
        Jason.encode!(%{
          "type" => "heartbeat_notification",
          "agent_name" => state.definition.name,
          "session_id" => state.id,
          "content" => state.last_text
        })

      TriOnyx.ConnectorHandler.broadcast_to_connectors(frame)
    end

    # Commit workspace writes
    state = commit_workspace_writes(state)

    # If we're in :saving_memory, this result is from the memory save prompt.
    # Commit and stop.
    cond do
      state.status == :saving_memory ->
        cancel_timer(state.memory_save_timer)
        Logger.info("AgentSession #{state.id}: memory save complete, shutting down")
        AgentPort.send_shutdown(state.port, state.shutdown_reason)
        {:stop, {:shutdown, state.shutdown_reason}, state}

      state.mode == :reflection ->
        Logger.info("AgentSession #{state.id}: reflection complete, shutting down")
        AgentPort.send_shutdown(state.port, "reflection complete")
        {:stop, {:shutdown, "reflection complete"}, state}

      state.interrupt_prompt != nil ->
        # Race condition: result arrived before runtime saw the interrupt.
        # The prompt completed normally, so send the queued prompt without
        # the [interrupted] prefix since nothing was actually cut short.
        {content, metadata} = state.interrupt_prompt
        state = %{state | status: :ready, interrupt_prompt: nil}
        Logger.info("AgentSession #{state.id}: result arrived with queued interrupt prompt, sending directly")
        broadcast_event(state, %{"type" => "user_prompt", "content" => content})
        AgentPort.send_prompt(state.port, content, metadata)
        {:noreply, %{state | status: :running}}

      true ->
        state = %{state | status: :ready}
        {:noreply, schedule_idle_timeout(state)}
    end
  end

  defp handle_agent_event({:log, level, message}, state) do
    agent = state.definition.name

    # Log to Elixir Logger at the matching level
    case level do
      "debug" -> Logger.debug("Agent[#{agent}] #{message}")
      "info" -> Logger.info("Agent[#{agent}] #{message}")
      "warning" -> Logger.warning("Agent[#{agent}] #{message}")
      "error" -> Logger.error("Agent[#{agent}] #{message}")
      "critical" -> Logger.critical("Agent[#{agent}] #{message}")
      _ -> Logger.info("Agent[#{agent}] [#{level}] #{message}")
    end

    # Broadcast WARNING+ to EventBus so connectors and test harness can see them
    if level in ["warning", "error", "critical"] do
      broadcast_event(state, %{"type" => "agent_log", "level" => level, "message" => message})
    end

    {:noreply, state}
  end

  defp handle_agent_event({:error, message}, state) do
    Logger.error("AgentSession #{state.id}: runtime error: #{message}")
    broadcast_event(state, %{"type" => "error", "message" => message})
    {:noreply, state}
  end

  defp handle_agent_event({:port_down, reason}, state) do
    Logger.warning("AgentSession #{state.id}: port down: #{reason}")
    broadcast_event(state, %{"type" => "port_down", "reason" => reason})
    new_state = %{state | port: nil, status: :stopped}

    case state.mode do
      # Reflection runs are single-shot; once the port exits there's nothing
      # left for the session to do, so terminate cleanly instead of lingering.
      :reflection -> {:stop, :normal, new_state}
      _ -> {:noreply, new_state}
    end
  end

  # --- Risk Level Management ---

  @doc """
  Elevates the session's taint and sensitivity levels from a classification map.

  Both axes are monotonic within a session — they can only escalate.
  When either axis changes, effective_risk is recomputed.
  """
  @spec elevate_risk(t(), InformationClassifier.classification()) :: t()
  def elevate_risk(state, %{taint: new_taint, sensitivity: new_sensitivity, reason: source}) do
    current_taint = state.taint_level
    current_sensitivity = state.sensitivity_level

    effective_taint = InformationClassifier.higher_level(current_taint, new_taint)
    effective_sensitivity = InformationClassifier.higher_level(current_sensitivity, new_sensitivity)

    taint_changed = effective_taint != current_taint
    sensitivity_changed = effective_sensitivity != current_sensitivity

    if taint_changed or sensitivity_changed do
      new_info_level = InformationClassifier.higher_level(effective_taint, effective_sensitivity)
      cap = Map.get(state, :capability_level, :medium)
      new_effective = RiskScorer.effective_risk(effective_taint, effective_sensitivity, cap)
      previous_risk = state.effective_risk
      risk_changed = new_effective != previous_risk

      Logger.warning(
        "AgentSession #{state.id}: risk escalated " <>
          "taint #{current_taint} → #{effective_taint}, " <>
          "sensitivity #{current_sensitivity} → #{effective_sensitivity} " <>
          "by #{source} (effective_risk: #{RiskScorer.format_risk(previous_risk)} → " <>
          "#{RiskScorer.format_risk(new_effective)})"
      )

      state = %{
        state
        | taint_level: effective_taint,
          sensitivity_level: effective_sensitivity,
          information_level: new_info_level,
          information_sources: [source | state.information_sources],
          input_risk: new_info_level,
          effective_risk: new_effective
      }

      # Notify user when effective risk level changes.
      # Guard on :definition to avoid crashes when called outside a GenServer
      # (e.g., in unit tests with bare state maps).
      if risk_changed and is_map_key(state, :definition) do
        escalation_event = %{
          "type" => "risk_escalation",
          "agent_name" => state.definition.name,
          "previous_risk" => RiskScorer.format_risk(previous_risk),
          "effective_risk" => RiskScorer.format_risk(new_effective),
          "taint_level" => to_string(effective_taint),
          "sensitivity_level" => to_string(effective_sensitivity),
          "capability_level" => to_string(cap),
          "source" => source
        }

        broadcast_event(state, escalation_event)

        TriOnyx.ConnectorHandler.broadcast_to_connectors(Jason.encode!(escalation_event))
      end

      state
    else
      # No escalation needed, just record the source if it's non-trivial
      if new_taint != :low or new_sensitivity != :low do
        %{state | information_sources: [source | state.information_sources]}
      else
        state
      end
    end
  end

  @doc """
  Elevates the session's information level if the new level is higher.

  Kept for backward compatibility. Delegates to `elevate_risk/2` treating
  the level as taint only.
  """
  @spec elevate_information(t(), InformationClassifier.information_level(), String.t()) :: t()
  def elevate_information(state, new_level, source) do
    elevate_risk(state, %{taint: new_level, sensitivity: :low, reason: source})
  end

  # --- Git Provenance ---

  @write_tools ["Write", "Edit", "NotebookEdit"]

  @spec maybe_record_provenance(String.t(), map(), t()) :: :ok
  defp maybe_record_provenance(tool_name, tool_input, state)
       when tool_name in @write_tools do
    raw_path = Map.get(tool_input, "file_path", "")

    if raw_path != "" do
      workspace_path = TriOnyx.Workspace.workspace_dir()

      # The agent container sees files at /workspace/..., but the gateway
      # workspace is a local directory. Strip the container prefix so git
      # gets a path relative to the workspace root.
      file_path = raw_path |> String.replace_leading("/workspace/", "")
      agent_name = state.definition.name
      taint = state.taint_level
      sensitivity = state.sensitivity_level

      Task.start(fn ->
        case TriOnyx.GitProvenance.record_write(
               workspace_path,
               file_path,
               agent_name,
               taint,
               sensitivity
             ) do
          :ok ->
            Logger.info(
              "AgentSession #{state.id}: recorded provenance for #{file_path} " <>
                "(taint: #{taint}, sensitivity: #{sensitivity})"
            )

          {:error, reason} ->
            Logger.warning(
              "AgentSession #{state.id}: failed to record provenance for #{file_path}: #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  end

  # --- Private Helpers ---

  # Checks prompt metadata for classification info (set by inter-agent
  # routing) and elevates the session's risk accordingly.
  @spec maybe_elevate_from_metadata(t(), map()) :: t()
  defp maybe_elevate_from_metadata(state, metadata) when is_map(metadata) do
    # BCP taint-neutral delivery: skip elevation when channel_mode is :bcp.
    # Gateway-validated structured responses carry bounded bandwidth and are
    # safe to deliver without tainting the receiving agent.
    if Map.get(metadata, :channel_mode) == :bcp do
      Logger.info(
        "AgentSession #{state.id}: BCP taint-neutral delivery (channel_mode: :bcp)"
      )

      state
    else
      taint = Map.get(metadata, :taint_level) || Map.get(metadata, :information_level)
      sensitivity = Map.get(metadata, :sensitivity_level, :low)
      from_agent = Map.get(metadata, :from_agent, "unknown")

      case taint do
        level when level in [:low, :medium, :high] ->
          sensitivity_level = if sensitivity in [:low, :medium, :high], do: sensitivity, else: :low

          elevate_risk(state, %{
            taint: level,
            sensitivity: sensitivity_level,
            reason: "inter-agent message from #{from_agent}"
          })

        _ ->
          state
      end
    end
  end

  defp maybe_elevate_from_metadata(state, _metadata), do: state

  @spec build_agent_config(AgentDefinition.t(), map(), :normal | :reflection) :: map()
  defp build_agent_config(definition, workspace_context, mode) do
    # In reflection mode the Python harness substitutes its own hardcoded
    # system prompt and tool allow-list; we send an empty system prompt and
    # no skills/plugins so no persona or extensions leak through.
    system_prompt =
      case mode do
        :reflection -> ""
        _ -> Workspace.PromptAssembler.assemble(definition, workspace_context)
      end

    {skills, plugins} =
      case mode do
        :reflection -> {[], []}
        _ -> {definition.skills, definition.plugins}
      end

    base = %{
      "name" => definition.name,
      "tools" => definition.tools,
      "model" => definition.model,
      "system_prompt" => system_prompt,
      "max_turns" => 100,
      "cwd" => "/workspace",
      "skills" => skills,
      "plugins" => plugins
    }

    case mode do
      :reflection -> Map.put(base, "mode", "reflection")
      _ -> base
    end
  end


  @spec initial_classification(atom()) :: InformationClassifier.classification()
  defp initial_classification(trigger_type) do
    InformationClassifier.classify_trigger(trigger_type)
  end

  @spec generate_session_id(:normal | :reflection) :: String.t()
  defp generate_session_id(mode \\ :normal) do
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    case mode do
      :reflection -> "reflection-" <> random
      _ -> random
    end
  end

  @spec mount_sensitivity_floor(AgentDefinition.t()) :: InformationClassifier.sensitivity_level()
  defp mount_sensitivity_floor(%AgentDefinition{} = definition) do
    [{:docker_socket, definition.docker_socket}, {:trionyx_repo, definition.trionyx_repo}]
    |> Enum.filter(fn {_mount, enabled} -> enabled end)
    |> Enum.map(fn {mount, _} -> SensitivityMatrix.mount_sensitivity(mount) end)
    |> Enum.reduce(:low, &InformationClassifier.higher_level/2)
  end

  @spec mount_sensitivity_sources(AgentDefinition.t()) :: [String.t()]
  defp mount_sensitivity_sources(%AgentDefinition{} = definition) do
    [{:docker_socket, definition.docker_socket}, {:trionyx_repo, definition.trionyx_repo}]
    |> Enum.filter(fn {_mount, enabled} -> enabled end)
    |> Enum.filter(fn {mount, _} -> SensitivityMatrix.mount_sensitivity(mount) != :low end)
    |> Enum.map(fn {mount, _} ->
      level = SensitivityMatrix.mount_sensitivity(mount)
      "mount:#{mount} (sensitivity: #{level})"
    end)
  end

  defp send_subscriptions_active(%{port: port, definition: definition}) do
    subs = TriOnyx.BCP.Subscription.for_reader(definition.name)

    if subs != [] do
      AgentPort.send_bcp_subscriptions_active(port, subs)
    end
  end

  @spec broadcast_event(t(), map()) :: :ok
  defp broadcast_event(%{id: session_id, definition: definition}, event) do
    full_event = Map.put(event, "session_id", session_id)
    EventBus.broadcast(session_id, full_event)
    SessionLogger.log(session_id, definition.name, full_event)
  end

  defp log_session_stop(state, reason) when is_map(state) and is_map_key(state, :id) do
    SessionLogger.log(state.id, state.definition.name, %{
      "type" => "session_stop",
      "agent_name" => state.definition.name,
      "reason" => inspect(reason),
      "taint_level" => to_string(state.taint_level),
      "sensitivity_level" => to_string(state.sensitivity_level),
      "effective_risk" => RiskScorer.format_risk(state.effective_risk)
    })

    SessionLogger.close_session(state.id, state.definition.name)
  end

  defp log_session_stop(_state, _reason), do: :ok

  @spec schedule_idle_timeout(t()) :: t()
  defp schedule_idle_timeout(%{definition: %{idle_timeout: nil}} = state), do: state

  defp schedule_idle_timeout(%{definition: %{idle_timeout: ms}} = state) do
    state = cancel_idle_timeout(state)
    ref = Process.send_after(self(), :idle_timeout, ms)
    %{state | idle_timer: ref}
  end

  @spec cancel_idle_timeout(t()) :: t()
  defp cancel_idle_timeout(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timeout(%{idle_timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer: nil}
  end

  @spec commit_workspace_writes(t()) :: t()
  defp commit_workspace_writes(state) do
    # Filter out atomic-write temp files (e.g., .SOUL.md.tmp.50.123456) —
    # only commit the final renamed paths.
    commit_paths =
      state.workspace_writes
      |> MapSet.to_list()
      |> Enum.reject(&temp_file?/1)

    if commit_paths != [] do
      # Update risk manifest with both taint and sensitivity levels
      Workspace.update_risk_manifest(
        state.definition.name,
        commit_paths,
        state.taint_level,
        state.sensitivity_level
      )

      # Include the manifest in committed paths
      all_paths = [".tri-onyx/risk-manifest.json" | commit_paths]

      case Workspace.commit_session(
             state.definition.name,
             state.id,
             all_paths,
             state.taint_level,
             state.sensitivity_level
           ) do
        {:ok, hash} when is_binary(hash) ->
          Logger.info("AgentSession #{state.id}: workspace committed #{hash}")

        {:ok, :no_changes} ->
          Logger.debug("AgentSession #{state.id}: no workspace changes to commit")

        {:error, reason} ->
          Logger.error("AgentSession #{state.id}: workspace commit failed: #{inspect(reason)}")
      end
    end

    %{state | workspace_writes: MapSet.new()}
  end

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  # Detects atomic-write temp files created by Claude SDK's Write tool.
  # These have patterns like "SOUL.md.tmp.50.1771023878427" (no leading dot).
  @doc false
  @spec temp_file?(String.t()) :: boolean()
  def temp_file?(path) do
    basename = Path.basename(path)
    Regex.match?(~r/\.tmp\.\d+\.\d+$/, basename)
  end

  defp format_bcp_error({:agent_not_found, name}),
    do: "Agent '#{name}' not found. It may not be configured."

  defp format_bcp_error({:no_bcp_channel, from, to, _role}),
    do: "No BCP channel configured between '#{from}' and '#{to}'."

  defp format_bcp_error({:category_exceeds_max, cat, max}),
    do: "Category #{cat} exceeds max allowed category #{max} for this channel."

  defp format_bcp_error({:reader_dispatch_failed, agent, msg}),
    do: "Failed to start reader agent '#{agent}': #{msg}"

  defp format_bcp_error(reason), do: inspect(reason)

  # Reads a draft JSON file and returns a map with to/subject/body for approval context.
  @spec read_draft_summary(String.t()) :: map()
  defp read_draft_summary(host_path) do
    case File.read(host_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, draft} ->
            Map.take(draft, ["to", "subject", "body", "cc", "in_reply_to"])

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  defp format_draft_for_approval(draft) do
    parts =
      [
        if(draft["to"], do: "To: #{draft["to"]}"),
        if(draft["cc"], do: "Cc: #{draft["cc"]}"),
        if(draft["subject"], do: "Subject: #{draft["subject"]}"),
        if(draft["in_reply_to"], do: "In-Reply-To: #{draft["in_reply_to"]}"),
        if(draft["body"], do: "\n#{draft["body"]}")
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, "\n")
  end
end
