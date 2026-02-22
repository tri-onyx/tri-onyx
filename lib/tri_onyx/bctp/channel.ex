defmodule TriOnyx.BCTP.Channel do
  @moduledoc """
  BCTP routing module for bandwidth-constrained inter-agent communication.

  Analogous to `TriOnyx.Triggers.InterAgent` but for the BCTP protocol.
  Routes structured queries from Controller agents to Reader agents and
  validates responses on the return path. Validated responses are delivered
  with `channel_mode: :bctp` metadata, which signals `AgentSession` to skip
  taint elevation — making BCTP communication taint-neutral.

  All routing decisions are deterministic and gateway-enforced. No LLM logic.
  """

  require Logger

  alias TriOnyx.AgentSession
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.BCTP.ApprovalQueue
  alias TriOnyx.BCTP.Query
  alias TriOnyx.BCTP.Validator
  alias TriOnyx.ConnectorHandler
  alias TriOnyx.TriggerRouter

  @approval_timeout_ms 300_000

  # ETS table for pending queries. Created once by Application.start/2 so the
  # table is owned by the long-lived Application process. Task processes that
  # call send_query/receive_response read/write to it but don't own it.
  @pending_queries_table :bctp_pending_queries

  @type query_spec :: map()

  @doc """
  Ensures the pending queries ETS table exists.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@pending_queries_table) do
      :undefined ->
        :ets.new(@pending_queries_table, [:set, :public, :named_table])
        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Looks up a pending query by ID and removes it from the table.
  """
  @spec pop_query(String.t()) :: {:ok, Query.t()} | :error
  def pop_query(query_id) do
    ensure_table()

    case :ets.lookup(@pending_queries_table, query_id) do
      [{^query_id, query}] ->
        :ets.delete(@pending_queries_table, query_id)
        {:ok, query}

      [] ->
        :error
    end
  end

  @doc """
  Controller initiates a BCTP query to a Reader agent.

  Pipeline:
  1. Look up both agent definitions to verify BCTP channel exists
  2. Validate roles (from must be controller, to must be reader)
  3. Look up BCTP channel config from controller's definition
  4. Build a Query from the spec
  5. Compute bandwidth
  6. Dispatch query to Reader's AgentPort

  Returns `{:ok, query}` or `{:error, reason}`.
  """
  @spec send_query(String.t(), String.t(), query_spec()) ::
          {:ok, Query.t()} | {:error, term()}
  def send_query(from_agent, to_agent, query_spec) do
    with {:ok, from_def} <- lookup_agent(from_agent),
         {:ok, _to_def} <- lookup_agent(to_agent),
         {:ok, channel_config} <- find_bctp_channel(from_def, to_agent, :controller),
         :ok <- validate_category(query_spec, channel_config),
         {:ok, query} <- build_query(from_agent, to_agent, query_spec),
         bandwidth <- Query.compute_bandwidth(query),
         :ok <- dispatch_to_reader(to_agent, query) do
      # Store the query so the response handler can look it up for validation
      ensure_table()
      :ets.insert(@pending_queries_table, {query.id, query})

      Logger.info(
        "BCTP.Channel: query #{query.id} from #{from_agent} to #{to_agent} " <>
          "(cat-#{query.category}, #{Float.round(bandwidth, 1)} bits)"
      )

      {:ok, query}
    end
  end

  @doc """
  Reader's response arrives at the gateway for validation and delivery.

  Pipeline:
  1. Validate response against Query spec via Validator
  2. On success: deliver to Controller with `channel_mode: :bctp` metadata
  3. On failure: reject response

  Returns `{:ok, validated_response}` or `{:error, reason}`.
  """
  @spec receive_response(Query.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def receive_response(%Query{} = query, response, opts \\ []) do
    case Validator.validate_response(query, response) do
      {:ok, validated} ->
        deliver_to_controller(query, validated, opts)
        {:ok, validated}

      {:ok, validated, anomalies} ->
        Logger.warning(
          "BCTP.Channel: query #{query.id} response has anomalies: #{inspect(anomalies)}"
        )

        deliver_to_controller(query, validated, opts)
        {:ok, validated}

      {:ok, validated, anomalies, :requires_approval} ->
        Logger.warning(
          "BCTP.Channel: query #{query.id} Cat-3 response requires approval, " <>
            "anomalies: #{inspect(anomalies)}"
        )

        # Submit to approval queue and broadcast to connectors for human review
        {:ok, approval_id} =
          ApprovalQueue.submit(%{
            query: query_to_spec(query),
            from_agent: query.from,
            to_agent: query.to,
            justification: "Cat-3 response with anomalies: #{inspect(anomalies)}"
          })

        # Extract response content from validated map
        response_content = Map.get(validated, :response, Map.get(validated, "response", ""))

        Logger.info(
          "BCTP.Channel: Cat-3 approval for query #{query.id}, " <>
            "validated keys=#{inspect(Map.keys(validated))}, " <>
            "response_content length=#{byte_size(to_string(response_content))}"
        )

        # Broadcast approval request to all connected connectors
        approval_frame =
          Jason.encode!(%{
            "type" => "approval_request",
            "approval_id" => approval_id,
            "from_agent" => query.from,
            "to_agent" => query.to,
            "category" => query.category,
            "query_summary" => query.directive || "",
            "response_content" => response_content,
            "anomalies" => Enum.map(anomalies, &anomaly_to_map/1)
          })

        ConnectorHandler.broadcast_to_connectors(approval_frame)

        # Block until human approves/rejects or timeout
        case ApprovalQueue.await_decision(ApprovalQueue, approval_id, @approval_timeout_ms) do
          {:approved, _item} ->
            Logger.info("BCTP.Channel: query #{query.id} Cat-3 response approved")
            deliver_to_controller(query, validated, opts)
            {:ok, validated}

          {:rejected, reason} ->
            Logger.warning("BCTP.Channel: query #{query.id} Cat-3 response rejected: #{reason}")
            {:error, {:approval_rejected, reason}}

          {:error, :timeout} ->
            Logger.warning("BCTP.Channel: query #{query.id} Cat-3 approval timed out")
            {:error, :approval_timeout}
        end

      {:error, reason} ->
        Logger.warning(
          "BCTP.Channel: query #{query.id} response rejected: #{reason}"
        )

        {:error, {:validation_failed, reason}}
    end
  end

  # --- Private ---

  @spec lookup_agent(String.t()) :: {:ok, TriOnyx.AgentDefinition.t()} | {:error, term()}
  defp lookup_agent(agent_name) do
    case TriggerRouter.get_agent(agent_name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:agent_not_found, agent_name}}
    end
  end

  @spec find_bctp_channel(TriOnyx.AgentDefinition.t(), String.t(), :controller | :reader) ::
          {:ok, TriOnyx.AgentDefinition.bctp_channel()} | {:error, term()}
  defp find_bctp_channel(definition, peer_name, expected_role) do
    case Enum.find(definition.bctp_channels, fn ch ->
           ch.peer == peer_name and ch.role == expected_role
         end) do
      nil ->
        {:error, {:no_bctp_channel, definition.name, peer_name, expected_role}}

      channel ->
        {:ok, channel}
    end
  end

  @spec validate_category(query_spec(), TriOnyx.AgentDefinition.bctp_channel()) ::
          :ok | {:error, term()}
  defp validate_category(%{category: cat}, %{max_category: max_cat}) when cat <= max_cat, do: :ok

  defp validate_category(%{category: cat}, %{max_category: max_cat}) do
    {:error, {:category_exceeds_max, cat, max_cat}}
  end

  @spec build_query(String.t(), String.t(), query_spec()) ::
          {:ok, Query.t()} | {:error, term()}
  defp build_query(from_agent, to_agent, spec) do
    session_id = Map.get(spec, :session_id, "bctp-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}")

    attrs =
      spec
      |> Map.put(:from, from_agent)
      |> Map.put(:to, to_agent)
      |> Map.put(:session_id, session_id)

    case Query.new(attrs) do
      {:ok, query} -> {:ok, query}
      {:error, reason} -> {:error, {:invalid_query_spec, reason}}
    end
  end

  @spec dispatch_to_reader(String.t(), Query.t()) :: :ok | {:error, term()}
  defp dispatch_to_reader(to_agent, query) do
    spec = query_to_spec(query)

    # First, try to deliver to an existing session
    case AgentSupervisor.find_session(to_agent) do
      {:ok, session_pid} ->
        AgentSession.deliver_bctp_query(
          session_pid, query.id, query.category, query.from, spec
        )

      :error ->
        # Reader not running — start it via TriggerRouter and deliver the query.
        # The BCTP query serves as the trigger payload that starts the reader session.
        # We dispatch a :bctp trigger to ensure the session is created, then deliver.
        bctp_trigger = %{
          type: :bctp,
          agent_name: to_agent,
          payload: "BCTP query from #{query.from} (cat-#{query.category}, id=#{query.id})",
          metadata: %{bctp_query: true, from_agent: query.from}
        }

        case TriggerRouter.dispatch(bctp_trigger) do
          {:ok, session_pid} ->
            AgentSession.deliver_bctp_query(
              session_pid, query.id, query.category, query.from, spec
            )

          {:error, _reason} = error ->
            error
        end
    end
  rescue
    e -> {:error, {:reader_dispatch_failed, to_agent, Exception.message(e)}}
  end

  @spec deliver_to_controller(Query.t(), map(), keyword()) :: :ok
  defp deliver_to_controller(query, validated_response, _opts) do
    bandwidth = Query.compute_bandwidth(query)

    case AgentSupervisor.find_session(query.from) do
      {:ok, session_pid} ->
        case AgentSession.deliver_bctp_response(
               session_pid,
               query.id,
               query.category,
               query.to,
               validated_response,
               bandwidth
             ) do
          :ok ->
            Logger.info(
              "BCTP.Channel: delivered validated response for query #{query.id} " <>
                "to controller #{query.from} (channel_mode: :bctp)"
            )

          {:error, reason} ->
            Logger.warning(
              "BCTP.Channel: controller #{query.from} rejected delivery: #{inspect(reason)}"
            )
        end

      :error ->
        Logger.warning("BCTP.Channel: controller #{query.from} not running, cannot deliver")
    end

    :ok
  rescue
    _ ->
      Logger.warning("BCTP.Channel: failed to deliver to controller #{query.from}")
      :ok
  end

  @spec query_to_spec(Query.t()) :: map()
  defp query_to_spec(%Query{category: 1} = q), do: %{"fields" => q.fields}
  defp query_to_spec(%Query{category: 2} = q), do: %{"questions" => q.questions}

  defp query_to_spec(%Query{category: 3} = q),
    do: %{"directive" => q.directive, "max_words" => q.max_words}

  @spec anomaly_to_map(term()) :: map()
  defp anomaly_to_map(anomaly) when is_map(anomaly), do: anomaly
  defp anomaly_to_map(anomaly) when is_binary(anomaly), do: %{"message" => anomaly}
  defp anomaly_to_map(anomaly), do: %{"message" => inspect(anomaly)}
end
