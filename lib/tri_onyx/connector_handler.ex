defmodule TriOnyx.ConnectorHandler do
  @moduledoc """
  WebSock behaviour handler for external connector WebSocket connections.

  Each connector (e.g. Matrix, Slack) maintains a persistent WebSocket to the
  gateway. This handler manages the connection lifecycle:

  1. **Authentication** — connector sends a `register` frame with a shared secret
  2. **Message routing** — inbound user messages are mapped to trigger types based
     on trust level and dispatched through `TriggerRouter`
  3. **Event streaming** — agent output events are pushed back to the connector
     wrapped in the appropriate frame type with the opaque channel object
  4. **Health tracking** — periodic health messages keep the connector registered;
     stale connectors are removed after 60 seconds

  The channel object is treated as opaque — stored and echoed back without
  interpretation. Thread-to-session mapping uses `{agent_name, channel_hash}`
  as the session key.

  ## WebSocket Protocol

  ### Inbound (Connector -> Gateway)

  - `register` — `{connector_id, platform, token}`
  - `message` — `{agent_name, content, channel, trust}`
  - `typing` — `{agent_name, channel, is_typing}`
  - `health` — `{connector_id, adapters}`
  - `action_result` — `{action, success, error?}`

  ### Outbound (Gateway -> Connector)

  - `registered` — `{connector_id}`
  - `agent_text` — `{agent_name, session_id, content, channel}`
  - `agent_typing` — `{agent_name, session_id, channel, is_typing}`
  - `agent_result` — `{agent_name, session_id, channel, duration_ms}`
  - `agent_step` — `{agent_name, session_id, channel, step_type, name?, input?, content?, is_error?, duration_ms?, num_turns?, cost_usd?}`
  - `agent_error` — `{agent_name, session_id, channel, message}`
  - `error` — `{message}`
  """

  require Logger

  alias TriOnyx.ActionApprovalQueue
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.BCP.ApprovalQueue
  alias TriOnyx.EventBus
  alias TriOnyx.SystemCommand
  alias TriOnyx.TriggerRouter

  @behaviour WebSock

  @health_timeout_ms 60_000

  @type state :: %{
          authenticated: boolean(),
          connector_id: String.t() | nil,
          platform: String.t() | nil,
          session_channels: %{String.t() => {map(), String.t()}},
          health_timer: reference() | nil
        }

  # --- WebSock Callbacks ---

  @impl WebSock
  @spec init(term()) :: {:ok, state()}
  def init(_opts) do
    {:ok,
     %{
       authenticated: false,
       connector_id: nil,
       platform: nil,
       session_channels: %{},
       health_timer: nil
     }}
  end

  @impl WebSock
  @spec handle_in({binary(), opcode: atom()}, state()) ::
          {:push, [{:text, binary()}], state()}
          | {:ok, state()}
          | {:stop, :normal, state()}
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, frame} ->
        handle_frame(frame, state)

      {:error, _reason} ->
        Logger.warning("ConnectorHandler: invalid JSON from #{state.connector_id || "unknown"}")
        {:push, [{:text, encode_error("invalid JSON")}], state}
    end
  end

  def handle_in({_data, [opcode: :binary]}, state) do
    {:push, [{:text, encode_error("binary frames not supported")}], state}
  end

  @impl WebSock
  @spec handle_info(term(), state()) :: {:push, [{:text, binary()}], state()} | {:ok, state()}
  def handle_info({:event_bus, session_id, event}, state) do
    handle_event_bus(session_id, event, state)
  end

  def handle_info(:health_timeout, state) do
    Logger.warning(
      "ConnectorHandler: health timeout for connector #{state.connector_id}, disconnecting"
    )

    unregister_connector(state.connector_id)
    {:stop, :normal, state}
  end

  def handle_info({:push_frame, frame}, state) do
    if state.authenticated do
      {:push, [{:text, frame}], state}
    else
      {:ok, state}
    end
  end

  def handle_info(msg, state) do
    Logger.warning("ConnectorHandler: unexpected message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl WebSock
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, %{connector_id: nil}), do: :ok

  def terminate(reason, state) do
    Logger.info("ConnectorHandler: connector #{state.connector_id} disconnected: #{inspect(reason)}")
    unregister_connector(state.connector_id)
    cancel_health_timer(state.health_timer)
    :ok
  end

  # --- Frame Handlers ---

  @spec handle_frame(map(), state()) ::
          {:push, [{:text, binary()}], state()} | {:ok, state()} | {:stop, :normal, state()}
  defp handle_frame(%{"type" => "register"} = frame, %{authenticated: false} = state) do
    connector_id = Map.get(frame, "connector_id", "")
    platform = Map.get(frame, "platform", "unknown")
    token = Map.get(frame, "token", "")

    expected_token = Application.get_env(:tri_onyx, :connector_token)

    if expected_token != nil and token == expected_token do
      Logger.info("ConnectorHandler: connector #{connector_id} (#{platform}) authenticated")

      register_connector(connector_id, platform)
      health_ref = schedule_health_timeout()

      new_state = %{
        state
        | authenticated: true,
          connector_id: connector_id,
          platform: platform,
          health_timer: health_ref
      }

      reply = Jason.encode!(%{"type" => "registered", "connector_id" => connector_id})
      {:push, [{:text, reply}], new_state}
    else
      Logger.warning("ConnectorHandler: auth failed for connector #{connector_id}")
      reply = encode_error("authentication failed")
      {:push, [{:text, reply}], state}
    end
  end

  defp handle_frame(%{"type" => "register"}, %{authenticated: true} = state) do
    {:push, [{:text, encode_error("already registered")}], state}
  end

  defp handle_frame(_frame, %{authenticated: false} = state) do
    {:push, [{:text, encode_error("not authenticated, send register first")}], state}
  end

  defp handle_frame(%{"type" => "message"} = frame, state) do
    agent_name = Map.get(frame, "agent_name", "")
    content = Map.get(frame, "content", "")
    channel = Map.get(frame, "channel", %{})
    trust = Map.get(frame, "trust", %{})

    case SystemCommand.parse(content) do
      {:command, cmd, args} ->
        context = %{agent_name: agent_name}
        {status, message} = SystemCommand.execute(cmd, args, context)

        reply =
          Jason.encode!(%{
            "type" => "system_command_response",
            "agent_name" => agent_name,
            "command" => content,
            "status" => to_string(status),
            "message" => message,
            "channel" => channel
          })

        {:push, [{:text, reply}], state}

      :not_a_command ->
        trigger_type = trust_to_trigger(trust)
        channel_hash = compute_channel_hash(channel)
        session_key = "#{agent_name}:#{channel_hash}"

        Logger.info(
          "ConnectorHandler: message from #{state.connector_id} for agent #{agent_name} " <>
            "(trigger=#{trigger_type})"
        )

        event = %{
          type: trigger_type,
          agent_name: agent_name,
          payload: content,
          metadata: %{
            "source" => "connector",
            "connector_id" => state.connector_id,
            "platform" => state.platform,
            "channel" => channel,
            "session_key" => session_key
          }
        }

        case dispatch_with_retry(event, agent_name) do
          {:ok, pid} ->
            session_id = get_session_id(pid)
            already_subscribed = Map.has_key?(state.session_channels, session_id)

            unless already_subscribed do
              EventBus.subscribe(session_id)
            end

            new_channels = Map.put(state.session_channels, session_id, {channel, agent_name})

            # Send typing=true immediately so the user sees the bot is working
            typing_frame =
              Jason.encode!(%{
                "type" => "agent_typing",
                "agent_name" => agent_name,
                "session_id" => session_id,
                "channel" => channel,
                "is_typing" => true
              })

            {:push, [{:text, typing_frame}], %{state | session_channels: new_channels}}

          {:error, reason} ->
            Logger.warning(
              "ConnectorHandler: dispatch failed for agent #{agent_name}: #{inspect(reason)}"
            )

            reply = encode_error("dispatch failed: #{inspect(reason)}")
            {:push, [{:text, reply}], state}
        end
    end
  end

  defp handle_frame(%{"type" => "typing"} = frame, state) do
    agent_name = Map.get(frame, "agent_name", "")
    _channel = Map.get(frame, "channel", %{})
    is_typing = Map.get(frame, "is_typing", false)

    Logger.debug(
      "ConnectorHandler: typing indicator from #{state.connector_id} " <>
        "for agent #{agent_name} (typing=#{is_typing})"
    )

    # Typing indicators are informational — no dispatch needed
    {:ok, state}
  end

  defp handle_frame(%{"type" => "health"} = frame, state) do
    connector_id = Map.get(frame, "connector_id", state.connector_id)
    adapters = Map.get(frame, "adapters", %{})

    adapter_count = if is_map(adapters), do: map_size(adapters), else: length(adapters)

    Logger.debug(
      "ConnectorHandler: health from #{connector_id} (#{adapter_count} adapter(s))"
    )

    # Reset the health timeout
    cancel_health_timer(state.health_timer)
    health_ref = schedule_health_timeout()

    # Update registration with latest adapter info
    register_connector(connector_id, state.platform)

    {:ok, %{state | health_timer: health_ref}}
  end

  defp handle_frame(%{"type" => "reaction"} = frame, state) do
    approval_id = Map.get(frame, "approval_id")
    action_approval_id = Map.get(frame, "action_approval_id")
    # Strip Unicode variation selectors (U+FE0E, U+FE0F) so 👍️ matches 👍
    emoji = Map.get(frame, "emoji", "") |> String.replace(~r/[\x{FE0E}\x{FE0F}]/u, "")
    sender = Map.get(frame, "sender", "")
    agent_name = Map.get(frame, "agent_name", "")
    channel = Map.get(frame, "channel", %{})
    trust = Map.get(frame, "trust", %{})

    cond do
      # Action approval reaction — action_approval_id is present
      is_binary(action_approval_id) and action_approval_id != "" ->
        Logger.info(
          "ConnectorHandler: action approval reaction from #{sender} " <>
            "(approval=#{action_approval_id}, emoji=#{emoji})"
        )

        case emoji do
          "👍" ->
            ActionApprovalQueue.approve(action_approval_id)

          "👎" ->
            ActionApprovalQueue.reject(action_approval_id, "rejected via reaction by #{sender}")

          _ ->
            Logger.warning(
              "ConnectorHandler: unrecognized action approval emoji #{emoji} for #{action_approval_id}"
            )
        end

        {:ok, state}

      # BCP approval reaction — approval_id is present
      is_binary(approval_id) and approval_id != "" ->
        Logger.info(
          "ConnectorHandler: approval reaction from #{sender} " <>
            "(approval=#{approval_id}, emoji=#{emoji})"
        )

        case emoji do
          "👍" ->
            ApprovalQueue.approve(approval_id)

          "👎" ->
            ApprovalQueue.reject(approval_id, "rejected via reaction by #{sender}")

          _ ->
            Logger.warning(
              "ConnectorHandler: unrecognized approval emoji #{emoji} for #{approval_id}"
            )
        end

        {:ok, state}

      # General reaction on an agent's message — forward as trigger
      agent_name != "" ->
        Logger.info(
          "ConnectorHandler: reaction #{emoji} from #{sender} on #{agent_name}'s message"
        )

        trigger_type = trust_to_trigger(trust)
        item_url = Map.get(frame, "item_url") || Map.get(frame, "article_url")
        item_type = Map.get(frame, "item_type", "article")

        payload =
          if is_binary(item_url) and item_url != "" do
            vote = case emoji do
              "👍" -> "up"
              "👎" -> "down"
              other -> other
            end
            Jason.encode!(%{"type" => "item_feedback", "item_type" => item_type, "url" => item_url, "vote" => vote})
          else
            "Reaction: #{emoji} from #{sender} on your message"
          end

        event = %{
          type: trigger_type,
          agent_name: agent_name,
          payload: payload,
          metadata: %{
            "source" => "connector",
            "connector_id" => state.connector_id,
            "platform" => state.platform,
            "channel" => channel,
            "trigger_subtype" => "reaction",
            "emoji" => emoji,
            "sender" => sender
          }
        }

        case dispatch_with_retry(event, agent_name) do
          {:ok, pid} ->
            session_id = get_session_id(pid)
            already_subscribed = Map.has_key?(state.session_channels, session_id)

            unless already_subscribed do
              EventBus.subscribe(session_id)
            end

            new_channels = Map.put(state.session_channels, session_id, {channel, agent_name})
            {:ok, %{state | session_channels: new_channels}}

          {:error, reason} ->
            Logger.warning(
              "ConnectorHandler: reaction dispatch failed for #{agent_name}: #{inspect(reason)}"
            )

            {:ok, state}
        end

      true ->
        Logger.warning("ConnectorHandler: reaction frame with no approval_id or agent_name")
        {:ok, state}
    end
  end

  defp handle_frame(%{"type" => "action_result"} = frame, state) do
    action = Map.get(frame, "action", "unknown")
    success = Map.get(frame, "success", false)
    error = Map.get(frame, "error")

    Logger.info(
      "ConnectorHandler: action_result from #{state.connector_id} " <>
        "(action=#{action} success=#{success}#{if error, do: " error=#{error}", else: ""})"
    )

    {:ok, state}
  end

  defp handle_frame(%{"type" => type}, state) do
    Logger.warning("ConnectorHandler: unknown frame type #{type} from #{state.connector_id}")
    {:push, [{:text, encode_error("unknown frame type: #{type}")}], state}
  end

  defp handle_frame(_frame, state) do
    {:push, [{:text, encode_error("missing type field")}], state}
  end

  # --- EventBus Event Routing ---

  @spec handle_event_bus(String.t(), map(), state()) ::
          {:push, [{:text, binary()}], state()} | {:ok, state()}
  defp handle_event_bus(session_id, event, state) do
    session_entry = Map.get(state.session_channels, session_id)

    # Only route events for sessions we're tracking
    if session_entry == nil do
      {:ok, state}
    else
      {channel, agent_name} = session_entry
      case Map.get(event, "type") do
        "text" ->
          content = Map.get(event, "content", "")

          # Filter out HEARTBEAT_OK responses — these are internal acks
          # that should never be forwarded to users.
          if String.contains?(content, "HEARTBEAT_OK") do
            {:ok, state}
          else
            # Clear typing indicator when text is delivered so the user
            # doesn't see "writing…" alongside the actual response.
            typing_frame =
              Jason.encode!(%{
                "type" => "agent_typing",
                "agent_name" => agent_name,
                "session_id" => session_id,
                "channel" => channel,
                "is_typing" => false
              })

            text_frame =
              Jason.encode!(%{
                "type" => "agent_text",
                "agent_name" => agent_name,
                "session_id" => session_id,
                "content" => content,
                "channel" => channel
              })

            {:push, [{:text, typing_frame}, {:text, text_frame}], state}
          end

        "ready" ->


          frame =
            Jason.encode!(%{
              "type" => "agent_typing",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "is_typing" => false
            })

          {:push, [{:text, frame}], state}

        "tool_use" ->


          typing_frame =
            Jason.encode!(%{
              "type" => "agent_typing",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "is_typing" => true
            })

          step_frame =
            Jason.encode!(%{
              "type" => "agent_step",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "step_type" => "tool_use",
              "name" => Map.get(event, "name", ""),
              "input" => Map.get(event, "input", %{})
            })

          {:push, [{:text, typing_frame}, {:text, step_frame}], state}

        "tool_result" ->


          frame =
            Jason.encode!(%{
              "type" => "agent_step",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "step_type" => "tool_result",
              "name" => Map.get(event, "name", ""),
              "content" => Map.get(event, "content", ""),
              "is_error" => Map.get(event, "is_error", false)
            })

          {:push, [{:text, frame}], state}

        "result" ->


          typing_frame =
            Jason.encode!(%{
              "type" => "agent_typing",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "is_typing" => false
            })

          result_frame =
            Jason.encode!(%{
              "type" => "agent_result",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "duration_ms" => Map.get(event, "duration_ms", 0)
            })

          step_frame =
            Jason.encode!(%{
              "type" => "agent_step",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "step_type" => "result",
              "duration_ms" => Map.get(event, "duration_ms", 0),
              "num_turns" => Map.get(event, "num_turns", 0),
              "cost_usd" => Map.get(event, "cost_usd", 0)
            })

          {:push, [{:text, typing_frame}, {:text, result_frame}, {:text, step_frame}], state}

        "error" ->
          typing_frame =
            Jason.encode!(%{
              "type" => "agent_typing",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "is_typing" => false
            })

          error_frame =
            Jason.encode!(%{
              "type" => "agent_error",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "message" => Map.get(event, "message", "unknown error")
            })

          {:push, [{:text, typing_frame}, {:text, error_frame}], state}

        "agent_log" ->
          frame =
            Jason.encode!(%{
              "type" => "agent_log",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "level" => Map.get(event, "level", ""),
              "message" => Map.get(event, "message", "")
            })

          {:push, [{:text, frame}], state}

        "risk_escalation" ->
          agent_name = Map.get(event, "agent_name", "")

          frame =
            Jason.encode!(%{
              "type" => "risk_escalation",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "previous_risk" => Map.get(event, "previous_risk", ""),
              "effective_risk" => Map.get(event, "effective_risk", ""),
              "taint_level" => Map.get(event, "taint_level", ""),
              "sensitivity_level" => Map.get(event, "sensitivity_level", ""),
              "source" => Map.get(event, "source", "")
            })

          {:push, [{:text, frame}], state}

        "action_approval_request" ->
          frame =
            Jason.encode!(%{
              "type" => "action_approval_request",
              "approval_id" => Map.get(event, "approval_id", ""),
              "agent_name" => Map.get(event, "agent_name", ""),
              "session_id" => session_id,
              "tool_name" => Map.get(event, "tool_name", ""),
              "tool_input" => Map.get(event, "tool_input", %{}),
              "channel" => channel
            })

          {:push, [{:text, frame}], state}

        "port_down" ->
          # Agent process crashed — clear the typing indicator
          typing_frame =
            Jason.encode!(%{
              "type" => "agent_typing",
              "agent_name" => agent_name,
              "session_id" => session_id,
              "channel" => channel,
              "is_typing" => false
            })

          {:push, [{:text, typing_frame}], state}

        "article" ->
          frame =
            Jason.encode!(%{
              "type" => "article",
              "agent_name" => Map.get(event, "agent_name", agent_name),
              "session_id" => session_id,
              "title" => Map.get(event, "title", ""),
              "url" => Map.get(event, "url", ""),
              "source" => Map.get(event, "source", ""),
              "summary" => Map.get(event, "summary", ""),
              "channel" => channel
            })

          {:push, [{:text, frame}], state}

        "listing" ->
          frame =
            Jason.encode!(%{
              "type" => "listing",
              "agent_name" => Map.get(event, "agent_name", agent_name),
              "session_id" => session_id,
              "title" => Map.get(event, "title", ""),
              "url" => Map.get(event, "url", ""),
              "price" => Map.get(event, "price", ""),
              "location" => Map.get(event, "location", ""),
              "channel" => channel
            })

          {:push, [{:text, frame}], state}

        _other ->
          # Ignore events we don't map to connector frames
          {:ok, state}
      end
    end
  end

  @doc """
  Pushes a raw JSON frame to all authenticated connector handler processes.

  Used for proactive notifications (e.g. heartbeat results) that aren't tied
  to an existing session channel.
  """
  @spec broadcast_to_connectors(binary()) :: :ok
  def broadcast_to_connectors(frame) when is_binary(frame) do
    TriOnyx.ConnectorRegistry
    |> Registry.select([{{:_, :"$1", :_}, [], [:"$1"]}])
    |> Enum.each(fn pid -> send(pid, {:push_frame, frame}) end)

    :ok
  end

  # --- Registry Helpers ---

  @spec register_connector(String.t(), String.t()) :: :ok
  defp register_connector(connector_id, platform) do
    value = %{platform: platform, connected_at: DateTime.utc_now(), pid: self()}

    case Registry.register(TriOnyx.ConnectorRegistry, connector_id, value) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> update_connector(connector_id, value)
    end
  end

  @spec update_connector(String.t(), map()) :: :ok
  defp update_connector(connector_id, value) do
    Registry.update_value(TriOnyx.ConnectorRegistry, connector_id, fn _old -> value end)
    :ok
  end

  @spec unregister_connector(String.t() | nil) :: :ok
  defp unregister_connector(nil), do: :ok

  defp unregister_connector(connector_id) do
    Registry.unregister(TriOnyx.ConnectorRegistry, connector_id)
    :ok
  end

  @doc """
  Returns a list of currently connected connectors with their metadata.
  """
  @spec list_connectors() :: [map()]
  def list_connectors do
    TriOnyx.ConnectorRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.map(fn {connector_id, value} ->
      %{
        "connector_id" => connector_id,
        "platform" => value.platform,
        "connected_at" => DateTime.to_iso8601(value.connected_at)
      }
    end)
  end

  # --- Dispatch with stuck-session recovery ---

  @spec dispatch_with_retry(map(), String.t()) :: {:ok, pid()} | {:error, term()}
  defp dispatch_with_retry(event, agent_name) do
    case TriggerRouter.dispatch(event) do
      {:error, :not_ready} ->
        # Session exists but is stuck (e.g. :starting with no Docker).
        # Stop it and try once more — TriggerRouter will spawn a fresh one.
        Logger.warning(
          "ConnectorHandler: session for '#{agent_name}' not ready, stopping and retrying"
        )

        case AgentSupervisor.find_session(agent_name) do
          {:ok, pid} -> AgentSupervisor.stop_session(AgentSupervisor, pid, "stuck session (not ready)")
          :error -> :ok
        end

        # Brief pause to let the supervisor clean up
        Process.sleep(100)

        TriggerRouter.dispatch(event)

      other ->
        other
    end
  end

  # --- Private Helpers ---

  @spec trust_to_trigger(map()) :: atom()
  defp trust_to_trigger(%{"level" => "verified"}), do: :verified_input
  defp trust_to_trigger(%{"level" => "unverified"}), do: :unverified_input
  defp trust_to_trigger(_), do: :unverified_input

  @spec compute_channel_hash(map()) :: String.t()
  defp compute_channel_hash(channel) when is_map(channel) do
    channel
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @spec get_session_id(pid()) :: String.t()
  defp get_session_id(pid) do
    status = TriOnyx.AgentSession.get_status(pid)
    status.id
  end


  @spec schedule_health_timeout() :: reference()
  defp schedule_health_timeout do
    Process.send_after(self(), :health_timeout, @health_timeout_ms)
  end

  @spec cancel_health_timer(reference() | nil) :: :ok
  defp cancel_health_timer(nil), do: :ok

  defp cancel_health_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end

  @spec encode_error(String.t()) :: binary()
  defp encode_error(message) do
    Jason.encode!(%{"type" => "error", "message" => message})
  end
end
