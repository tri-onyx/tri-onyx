defmodule TriOnyx.Triggers.InterAgent do
  @moduledoc """
  Inter-agent message routing and sanitization.

  When an agent sends a message to another agent, the gateway mediates
  the communication. This module:

  1. Validates the message structure
  2. Sanitizes the payload via `TriOnyx.Sanitizer` (structured data only)
  3. Routes the sanitized message to the target agent session
  4. Logs the sanitization decision to the audit log

  ## Trust Level

  Trust level: sanitized. The receiving agent is NOT auto-tainted if
  sanitization succeeds (sanitization is the defense). If sanitization
  fails, the message is rejected — the receiving agent never sees it.

  ## Taint Propagation

  - Tainted sender + successful sanitization → receiver inherits sender's taint
    (sanitization is a structural defense, not a taint reduction)
  - Sanitization failure → message rejected, receiver never tainted
  - Sanitization bypassed (should never happen) → receiver tainted
  """

  require Logger

  alias TriOnyx.AgentSupervisor
  alias TriOnyx.AuditLog
  alias TriOnyx.Sanitizer
  alias TriOnyx.TriggerRouter

  @type message :: %{
          from: String.t(),
          to: String.t(),
          message_type: String.t(),
          payload: map()
        }

  @type route_opts :: [
          {:router, GenServer.server()}
          | {:audit_log, GenServer.server()}
          | {:schema, map() | nil}
          | {:supervisor, GenServer.server()}
        ]

  @doc """
  Routes a sanitized inter-agent message to the target agent.

  Validates the message structure, sanitizes the payload, logs the decision
  to the audit log, and dispatches to the target agent session.

  ## Options

  - `:router` — TriggerRouter to dispatch to (default: `TriOnyx.TriggerRouter`)
  - `:audit_log` — AuditLog server for logging (default: `TriOnyx.AuditLog`)
  - `:schema` — optional message schema to validate against
  - `:supervisor` — AgentSupervisor used to look up the sender's session
    (default: `TriOnyx.AgentSupervisor`)

  Returns `{:ok, pid}` if dispatch succeeds, or `{:error, reason}` on failure.
  """
  @spec route(message(), route_opts()) :: {:ok, pid()} | {:error, term()}
  def route(message, opts \\ []) do
    router = Keyword.get(opts, :router, TriOnyx.TriggerRouter)
    audit_log = Keyword.get(opts, :audit_log, AuditLog)
    schema = Keyword.get(opts, :schema, nil)
    supervisor = Keyword.get(opts, :supervisor, AgentSupervisor)

    with :ok <- validate_message(message),
         :ok <- check_messaging_policy(message, router),
         {:ok, sanitized_payload} <- sanitize_payload(message.payload, schema) do
      # Log successful sanitization
      log_sanitization(audit_log, message, true)

      # Look up the sender's risk levels. Taint and sensitivity are separate
      # axes: the receiver's taint must only inherit the sender's TAINT, and
      # the sender's sensitivity must propagate as sensitivity — conflating
      # them (the old combined information_level) wrongly raised receiver
      # taint for high-sensitivity/low-taint senders and dropped sensitivity.
      sender_levels = lookup_sender_levels(supervisor, message.from)

      # Wrap the sanitized payload in a structured envelope so the receiving
      # agent has clear provenance metadata and knows how to reply.
      envelope = %{
        "from" => message.from,
        "type" => message.message_type,
        "payload" => sanitized_payload,
        "reply_to" => message.from,
        "reply_tool" => "mcp__interagent__SendMessage",
        "routed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      event = %{
        type: :inter_agent,
        agent_name: message.to,
        payload: Jason.encode!(envelope),
        metadata: %{
          from_agent: message.from,
          message_type: message.message_type,
          sanitized: true,
          taint_level: sender_levels.taint,
          sensitivity_level: sender_levels.sensitivity,
          # Combined level kept for backward compat with consumers that
          # still read the single-axis field.
          information_level: sender_levels.information_level,
          sender_information_level: sender_levels.information_level,
          routed_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      Logger.info(
        "InterAgent: routing message from '#{message.from}' to '#{message.to}' " <>
          "(type: #{message.message_type})"
      )

      case TriOnyx.TriggerRouter.dispatch(router, event) do
        {:ok, _pid} = result ->
          broadcast_mirror(message, sanitized_payload)
          result

        other ->
          other
      end
    else
      {:error, {:send_not_allowed, from, to}} = error ->
        AuditLog.log_messaging_policy_rejection(audit_log, from, to, :send_not_allowed, "sender '#{from}' does not list '#{to}' in send_to")

        Logger.warning(
          "InterAgent: message from '#{from}' to '#{to}' rejected: sender not allowed to send to target"
        )

        error

      {:error, {:receive_not_allowed, to, from}} = error ->
        AuditLog.log_messaging_policy_rejection(audit_log, from, to, :receive_not_allowed, "receiver '#{to}' does not list '#{from}' in receive_from")

        Logger.warning(
          "InterAgent: message from '#{from}' to '#{to}' rejected: receiver does not accept from sender"
        )

        error

      {:error, reason} = error ->
        # Log failed sanitization
        log_sanitization(audit_log, message, false)

        Logger.warning(
          "InterAgent: message from '#{message.from}' to '#{message.to}' rejected: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Validates the structure of an inter-agent message.
  """
  @spec validate_message(message()) :: :ok | {:error, term()}
  def validate_message(%{from: from, to: to, message_type: type, payload: payload})
      when is_binary(from) and is_binary(to) and is_binary(type) and is_map(payload) do
    cond do
      from == "" -> {:error, {:invalid_field, :from, "must not be empty"}}
      to == "" -> {:error, {:invalid_field, :to, "must not be empty"}}
      type == "" -> {:error, {:invalid_field, :message_type, "must not be empty"}}
      from == to -> {:error, :self_message}
      true -> :ok
    end
  end

  def validate_message(_message) do
    {:error, :invalid_message_structure}
  end

  @doc """
  Sanitizes an inter-agent message payload using the full Sanitizer.

  Delegates to `TriOnyx.Sanitizer` for structural validation. If a schema
  is provided, additionally validates against the schema.
  """
  @spec sanitize(map()) :: {:ok, map()} | {:error, term()}
  def sanitize(payload) when is_map(payload) do
    sanitize_payload(payload, nil)
  end

  # --- Private ---

  @spec check_messaging_policy(message(), GenServer.server()) :: :ok | {:error, term()}
  defp check_messaging_policy(message, router) do
    with {:ok, sender_def} <- TriggerRouter.get_agent(router, message.from),
         {:ok, receiver_def} <- TriggerRouter.get_agent(router, message.to) do
      cond do
        message.to not in sender_def.send_to ->
          {:error, {:send_not_allowed, message.from, message.to}}

        message.from not in receiver_def.receive_from ->
          {:error, {:receive_not_allowed, message.to, message.from}}

        true ->
          :ok
      end
    else
      # If agent definitions can't be looked up (e.g. not registered yet),
      # reject by default — fail closed
      :error ->
        {:error, {:send_not_allowed, message.from, message.to}}
    end
  end

  @spec sanitize_payload(map(), map() | nil) :: {:ok, map()} | {:error, term()}
  defp sanitize_payload(payload, nil) do
    case Sanitizer.sanitize(payload) do
      {:ok, _sanitized} = result ->
        result

      {:error, {_type, detail}} ->
        Logger.warning("InterAgent: payload failed sanitization: #{detail}")
        {:error, :sanitization_failed}
    end
  end

  defp sanitize_payload(payload, schema) when is_map(schema) do
    case Sanitizer.sanitize_with_schema(payload, schema) do
      {:ok, _sanitized} = result ->
        result

      {:error, {_type, detail}} ->
        Logger.warning("InterAgent: payload failed schema validation: #{detail}")
        {:error, :sanitization_failed}
    end
  end

  @default_levels %{taint: :low, sensitivity: :low, information_level: :low}

  # Fetches the sender's taint and sensitivity levels (separate axes) from
  # its active session, plus the combined information_level for backward
  # compat. Defaults to low on all axes when no session is found
  # (conservative for the sanitized path).
  @spec lookup_sender_levels(GenServer.server(), String.t()) :: %{
          taint: TriOnyx.InformationClassifier.information_level(),
          sensitivity: TriOnyx.InformationClassifier.sensitivity_level(),
          information_level: TriOnyx.InformationClassifier.information_level()
        }
  defp lookup_sender_levels(supervisor, agent_name) do
    case AgentSupervisor.find_session(supervisor, agent_name) do
      {:ok, pid} ->
        status = TriOnyx.AgentSession.get_status(pid)

        %{
          taint: Map.get(status, :taint_level, :low),
          sensitivity: Map.get(status, :sensitivity_level, :low),
          information_level: Map.get(status, :information_level, :low)
        }

      :error ->
        @default_levels
    end
  catch
    :exit, _ -> @default_levels
  end

  @mirror_max_len 1_500

  # Mirrors a successfully routed inter-agent message to connectors so
  # humans can follow agent-to-agent conversations in chat. The connector
  # resolves which rooms/channels (if any) the two agents are bound to;
  # the gateway broadcasts unconditionally and platform-agnostically.
  # Best-effort: mirror failures must never affect routing.
  @spec broadcast_mirror(message(), map()) :: :ok
  defp broadcast_mirror(message, sanitized_payload) do
    frame =
      Jason.encode!(%{
        "type" => "inter_agent_mirror",
        "from_agent" => message.from,
        "to_agent" => message.to,
        "message_type" => message.message_type,
        "content" => render_mirror_content(sanitized_payload)
      })

    TriOnyx.ConnectorHandler.broadcast_to_connectors(frame)
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Single text-like field renders as plain text; anything else as JSON.
  defp render_mirror_content(payload) do
    text =
      case payload do
        %{"text" => text} when is_binary(text) and map_size(payload) == 1 -> text
        %{"message" => text} when is_binary(text) and map_size(payload) == 1 -> text
        %{"content" => text} when is_binary(text) and map_size(payload) == 1 -> text
        other -> Jason.encode!(other, pretty: true)
      end

    if String.length(text) > @mirror_max_len do
      String.slice(text, 0, @mirror_max_len) <> "…"
    else
      text
    end
  end

  @spec log_sanitization(GenServer.server(), message(), boolean()) :: :ok
  defp log_sanitization(audit_log, message, sanitized?) do
    AuditLog.log_inter_agent_message(
      audit_log,
      message.from,
      message.to,
      message.message_type,
      sanitized?
    )
  catch
    # Don't fail routing if audit logging is unavailable
    :exit, _ -> :ok
  end
end
