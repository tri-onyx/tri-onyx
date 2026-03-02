defmodule TriOnyx.Router do
  @moduledoc """
  Plug-based HTTP router for the TriOnyx gateway.

  Routes:

  - `POST /hooks/:endpoint_id` — authenticated webhook ingress (internet-facing)
  - `POST /webhooks/:agent_name` — legacy webhook trigger (deprecated, no auth)
  - `POST /messages` — external message trigger (verified)
  - `GET /agents` — list active agents with risk scores
  - `GET /agents/:name` — agent detail with taint status
  - `POST /agents/:name/start` — manually start an agent session
  - `POST /agents/:name/stop` — stop an agent session
  - `POST /agents/:name/prompt` — send a prompt to a running agent
  - `GET /agents/:name/events` — SSE stream for agent session events
  - `GET /webhook-endpoints` — list webhook endpoints
  - `POST /webhook-endpoints` — create webhook endpoint
  - `GET /webhook-endpoints/:id` — webhook endpoint detail
  - `PUT /webhook-endpoints/:id` — update webhook endpoint
  - `DELETE /webhook-endpoints/:id` — delete webhook endpoint
  - `POST /webhook-endpoints/:id/rotate-secret` — rotate signing secret
  - `GET /bcp/approvals` — list pending BCP approval items
  - `POST /bcp/approvals/:id/approve` — approve a pending BCP item
  - `POST /bcp/approvals/:id/reject` — reject a pending BCP item with reason
  - `GET /api/matrix` — classification matrix (taint, sensitivity, risk)
  - `GET /connectors/ws` — WebSocket upgrade for external connectors
  - `GET /connectors` — list active connectors
  - `GET /graph/analysis` — graph analysis with risk propagation and policy violations
  - `GET /logs` — list agents with session logs
  - `GET /logs/:agent_name` — list sessions for an agent
  - `GET /logs/:agent_name/:session_id` — return JSONL session log

  Uses Bandit as the HTTP server.
  """

  use Plug.Router

  require Logger

  alias TriOnyx.AgentSession
  alias TriOnyx.InformationClassifier
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.AuditLog
  alias TriOnyx.ConnectorHandler
  alias TriOnyx.EventBus
  alias TriOnyx.GraphAnalyzer
  alias TriOnyx.RiskScorer
  alias TriOnyx.SessionLogger
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Triggers.ExternalMessage
  alias TriOnyx.Workspace
  alias TriOnyx.Triggers.Scheduler
  alias TriOnyx.BCP.ApprovalQueue
  alias TriOnyx.Triggers.Webhook
  alias TriOnyx.WebhookEndpoint
  alias TriOnyx.WebhookReceiver
  alias TriOnyx.WebhookRegistry

  plug Plug.Logger, log: :debug
  plug :cors
  plug Plug.Static, at: "/", from: Path.expand("../../webgui", __DIR__), only: ~w(matrix.html graph.html log-viewer.html frontend.html)
  plug :match
  plug :fetch_raw_body
  plug :dispatch

  # --- Authenticated Webhook Ingress ---

  post "/hooks/:endpoint_id" do
    body = conn.assigns[:raw_body] || ""
    headers = conn.req_headers
    source_ip = extract_source_ip(conn)

    {status, response} = WebhookReceiver.handle(endpoint_id, body, headers, source_ip)

    conn =
      if match?({429, _}, {status, response}) do
        retry_after = Map.get(response, "retry_after", 60)
        Plug.Conn.put_resp_header(conn, "retry-after", Integer.to_string(retry_after))
      else
        conn
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
  end

  # --- Legacy Webhook Trigger (deprecated — use /hooks/:endpoint_id) ---

  post "/webhooks/:agent_name" do
    Logger.warning("Deprecated: POST /webhooks/#{agent_name} — use /hooks/:endpoint_id instead")
    body = conn.assigns[:raw_body] || ""
    {status, response} = Webhook.handle(agent_name, body)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
  end

  # --- External Message Trigger ---

  post "/messages" do
    body = conn.assigns[:raw_body] || ""
    api_key = extract_bearer_token(conn)
    {status, response} = ExternalMessage.handle(body, api_key)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
  end

  # --- Agent Management ---

  get "/agents" do
    agents = TriggerRouter.list_agents()
    sessions = AgentSupervisor.list_sessions()
    all_defs = Map.new(agents, fn d -> {d.name, d} end)

    agent_list =
      Enum.map(agents, fn definition ->
        session = Enum.find(sessions, fn s -> s.definition.name == definition.name end)

        base = %{
          "name" => definition.name,
          "description" => definition.description,
          "model" => definition.model,
          "tools" => definition.tools,
          "network" => format_network(definition.network)
        }

        if session do
          Map.merge(base, %{
            "session_id" => session.id,
            "status" => to_string(session.status),
            "taint_level" => to_string(session.taint_level),
            "sensitivity_level" => to_string(session.sensitivity_level),
            "information_level" => to_string(session.information_level),
            "taint_status" => deprecated_taint_status(session.taint_level),
            "input_risk" => to_string(session.input_risk),
            "effective_risk" => RiskScorer.format_risk(session.effective_risk),
            "started_at" => DateTime.to_iso8601(session.started_at)
          })
        else
          wc_taint = GraphAnalyzer.worst_case_taint(definition, all_defs)
          wc_sensitivity = GraphAnalyzer.worst_case_sensitivity(definition)

          Map.merge(base, %{
            "status" => "inactive",
            "taint_level" => to_string(wc_taint),
            "sensitivity_level" => to_string(wc_sensitivity),
            "information_level" =>
              to_string(InformationClassifier.higher_level(wc_taint, wc_sensitivity))
          })
        end
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"agents" => agent_list}))
  end

  get "/agents/:name" do
    case TriggerRouter.get_agent(name) do
      {:ok, definition} ->
        sessions = AgentSupervisor.list_sessions()
        session = Enum.find(sessions, fn s -> s.definition.name == name end)
        all_defs = Map.new(TriggerRouter.list_agents(), fn d -> {d.name, d} end)

        detail = %{
          "name" => definition.name,
          "description" => definition.description,
          "model" => definition.model,
          "tools" => definition.tools,
          "network" => format_network(definition.network),
          "fs_read" => definition.fs_read,
          "fs_write" => definition.fs_write,
          "send_to" => definition.send_to,
          "receive_from" => definition.receive_from,
          "bcp_channels" => serialize_bcp_channels(definition.bcp_channels),
          "capability_level" => to_string(RiskScorer.infer_capability(definition.tools, definition.network))
        }

        detail =
          if session do
            Map.merge(detail, %{
              "session_id" => session.id,
              "status" => to_string(session.status),
              "taint_level" => to_string(session.taint_level),
              "sensitivity_level" => to_string(session.sensitivity_level),
              "information_level" => to_string(session.information_level),
              "information_sources" => session.information_sources,
              "taint_status" => deprecated_taint_status(session.taint_level),
              "input_risk" => to_string(session.input_risk),
              "effective_risk" => RiskScorer.format_risk(session.effective_risk),
              "started_at" => DateTime.to_iso8601(session.started_at)
            })
          else
            wc_taint = GraphAnalyzer.worst_case_taint(definition, all_defs)
            wc_sensitivity = GraphAnalyzer.worst_case_sensitivity(definition)

            Map.merge(detail, %{
              "status" => "inactive",
              "taint_level" => to_string(wc_taint),
              "sensitivity_level" => to_string(wc_sensitivity),
              "information_level" =>
                to_string(InformationClassifier.higher_level(wc_taint, wc_sensitivity))
            })
          end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(detail))

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "agent_not_found", "name" => name}))
    end
  end

  post "/agents/:name/start" do
    case TriggerRouter.get_agent(name) do
      {:ok, definition} ->
        trigger_type = get_trigger_type(conn)

        case AgentSupervisor.start_session(
               definition: definition,
               trigger_type: trigger_type
             ) do
          {:ok, pid} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              201,
              Jason.encode!(%{
                "status" => "started",
                "agent" => name,
                "pid" => inspect(pid)
              })
            )

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(%{
                "error" => "start_failed",
                "reason" => inspect(reason)
              })
            )
        end

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "agent_not_found", "name" => name}))
    end
  end

  post "/agents/:name/stop" do
    case AgentSupervisor.find_session(name) do
      {:ok, pid} ->
        reason = get_stop_reason(conn)
        AgentSupervisor.stop_session(AgentSupervisor, pid, reason)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"status" => "stopped", "agent" => name}))

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{
            "error" => "no_active_session",
            "agent" => name
          })
        )
    end
  end

  # --- Agent Prompt ---

  post "/agents/:name/prompt" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"content" => content}} when is_binary(content) ->
        case AgentSupervisor.find_session(name) do
          {:ok, pid} ->
            case AgentSession.send_prompt(pid, content) do
              :ok ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{"status" => "sent", "agent" => name}))

              {:error, :not_ready} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(
                  409,
                  Jason.encode!(%{
                    "error" => "not_ready",
                    "message" => "Agent session is not in ready state"
                  })
                )
            end

          :error ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              404,
              Jason.encode!(%{
                "error" => "no_active_session",
                "agent" => name
              })
            )
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_body",
            "message" => "Expected JSON with \"content\" field"
          })
        )
    end
  end

  # --- SSE Event Stream ---

  get "/agents/:name/events" do
    case AgentSupervisor.find_session(name) do
      {:ok, pid} ->
        status = AgentSession.get_status(pid)
        session_id = status.id

        EventBus.subscribe(session_id)

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Send initial connected event
        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            sse_encode("connected", %{
              "session_id" => session_id,
              "agent" => name,
              "status" => to_string(status.status)
            })
          )

        sse_loop(conn)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{
            "error" => "no_active_session",
            "agent" => name
          })
        )
    end
  end

  # --- Audit Log Query ---

  get "/audit" do
    conn = Plug.Conn.fetch_query_params(conn)
    since_param = conn.params["since"]

    case parse_date(since_param) do
      {:ok, since_date} ->
        {:ok, entries} = AuditLog.read_entries(since_date)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"entries" => entries, "count" => length(entries)}))

      {:error, message} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "invalid_date", "message" => message}))
    end
  end

  # --- Human Review ---

  post "/review" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"paths" => paths, "reviewer" => reviewer}}
      when is_list(paths) and is_binary(reviewer) ->
        case Workspace.review_artifacts(paths, reviewer) do
          {:ok, updated_paths} ->
            AuditLog.log_human_review(reviewer, updated_paths)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{"status" => "reviewed", "paths" => updated_paths}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              500,
              Jason.encode!(%{
                "error" => "review_failed",
                "reason" => inspect(reason)
              })
            )
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_body",
            "message" => "Expected JSON with \"paths\" (list) and \"reviewer\" (string) fields"
          })
        )
    end
  end

  # --- Heartbeat Management ---

  get "/heartbeats" do
    heartbeats = Scheduler.list_heartbeats()
    enabled = Scheduler.enabled?()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "heartbeats" => heartbeats,
        "enabled" => enabled
      })
    )
  end

  put "/heartbeats/enabled" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"enabled" => enabled}} when is_boolean(enabled) ->
        :ok = Scheduler.set_enabled(enabled)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"enabled" => enabled}))

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_body",
            "message" => "Expected JSON with boolean \"enabled\" field"
          })
        )
    end
  end

  post "/heartbeats/:agent_name" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"interval_ms" => interval_ms}}
      when is_integer(interval_ms) and interval_ms > 0 ->
        :ok = Scheduler.schedule_heartbeat(agent_name, interval_ms)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "status" => "scheduled",
            "agent_name" => agent_name,
            "interval_ms" => interval_ms
          })
        )

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(%{
            "error" => "invalid_body",
            "message" => "Expected JSON with positive integer \"interval_ms\" field"
          })
        )
    end
  end

  delete "/heartbeats/:agent_name" do
    case Scheduler.cancel_heartbeat(agent_name) do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"status" => "cancelled", "agent_name" => agent_name}))

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{
            "error" => "not_found",
            "agent_name" => agent_name
          })
        )
    end
  end

  # --- BCP Approval Queue ---

  get "/bcp/approvals" do
    items = ApprovalQueue.list_pending()

    serialized =
      Enum.map(items, fn item ->
        %{
          "id" => item.id,
          "from_agent" => item.from_agent,
          "to_agent" => item.to_agent,
          "justification" => item.justification,
          "query" => item.query,
          "submitted_at" => DateTime.to_iso8601(item.submitted_at)
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"approvals" => serialized}))
  end

  post "/bcp/approvals/:id/approve" do
    case ApprovalQueue.approve(id) do
      {:ok, item} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "status" => "approved",
            "id" => item.id,
            "from_agent" => item.from_agent,
            "to_agent" => item.to_agent
          })
        )

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  post "/bcp/approvals/:id/reject" do
    body = conn.assigns[:raw_body] || ""

    reason =
      case Jason.decode(body) do
        {:ok, %{"reason" => r}} when is_binary(r) -> r
        _ -> "no reason provided"
      end

    case ApprovalQueue.reject(id, reason) do
      {:ok, item} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "status" => "rejected",
            "id" => item.id,
            "reason" => reason,
            "from_agent" => item.from_agent,
            "to_agent" => item.to_agent
          })
        )

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  # --- Action Approval Queue ---

  get "/actions/approvals" do
    alias TriOnyx.ActionApprovalQueue

    items = ActionApprovalQueue.list_pending()

    serialized =
      Enum.map(items, fn item ->
        %{
          "id" => item.id,
          "agent_name" => item.agent_name,
          "session_id" => item.session_id,
          "tool_name" => item.tool_name,
          "tool_input" => item.tool_input,
          "submitted_at" => DateTime.to_iso8601(item.submitted_at)
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"approvals" => serialized}))
  end

  post "/actions/approvals/:id/approve" do
    alias TriOnyx.ActionApprovalQueue

    case ActionApprovalQueue.approve(id) do
      {:ok, item} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "status" => "approved",
            "id" => item.id,
            "agent_name" => item.agent_name,
            "tool_name" => item.tool_name
          })
        )

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  post "/actions/approvals/:id/reject" do
    alias TriOnyx.ActionApprovalQueue

    body = conn.assigns[:raw_body] || ""

    reason =
      case Jason.decode(body) do
        {:ok, %{"reason" => r}} when is_binary(r) -> r
        _ -> "no reason provided"
      end

    case ActionApprovalQueue.reject(id, reason) do
      {:ok, item} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "status" => "rejected",
            "id" => item.id,
            "reason" => reason,
            "agent_name" => item.agent_name,
            "tool_name" => item.tool_name
          })
        )

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  # --- Connector WebSocket ---

  get "/connectors/ws" do
    conn
    |> WebSockAdapter.upgrade(ConnectorHandler, [], timeout: 60_000)
    |> halt()
  end

  get "/connectors" do
    connectors = ConnectorHandler.list_connectors()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"connectors" => connectors}))
  end

  # --- Classification Matrix ---

  get "/api/matrix" do
    alias TriOnyx.TaintMatrix
    alias TriOnyx.SensitivityMatrix
    alias TriOnyx.ToolRegistry

    trigger_taints = TaintMatrix.all_trigger_taints()
    trigger_sensitivities = SensitivityMatrix.all_trigger_sensitivities()

    # Build tools from display entries so group/variant/note/key are included.
    # Read/controlled and Read/external get their taint from the context-aware TaintMatrix call.
    tools =
      ToolRegistry.display_entries()
      |> Enum.map(fn entry ->
        taint =
          case entry.key do
            "Read/controlled" -> TaintMatrix.tool_taint("Read", :controlled)
            "Read/external"   -> TaintMatrix.tool_taint("Read", :external)
            "Bash/isolated"   -> TaintMatrix.tool_taint("Bash", :isolated)
            "Bash/network"    -> TaintMatrix.tool_taint("Bash", :network)
            key               -> TaintMatrix.tool_taint(key)
          end

        sensitivity =
          case entry.key do
            "Read/" <> _ -> SensitivityMatrix.tool_sensitivity("Read")
            "Bash/" <> _ -> SensitivityMatrix.tool_sensitivity("Bash")
            key          -> SensitivityMatrix.tool_sensitivity(key)
          end

        capability =
          case entry.key do
            "Read/" <> _     -> ToolRegistry.capability_level("Read")
            "Bash/isolated"  -> :medium
            "Bash/network"   -> :high
            key              -> ToolRegistry.capability_level(key)
          end

        %{
          "key"         => entry.key,
          "display"     => entry.display,
          "variant"     => entry.variant,
          "note"        => entry.note,
          "group"       => entry.group,
          "taint"       => to_string(taint),
          "sensitivity" => to_string(sensitivity),
          "capability"  => to_string(capability)
        }
      end)

    # Triggers in a stable display order
    trigger_order = ~w(webhook unverified_input inter_agent external_message verified_input cron heartbeat)
    trigger_notes = %{
      "webhook"              => "untrusted external HTTP payload",
      "unverified_input" => "unverified email or chat message",
      "inter_agent"          => "sender taint propagated at runtime",
      "external_message"     => "API-key authenticated programmatic message",
      "verified_input"   => "chat platform message with verified sender identity",
      "cron"                 => "internal schedule (no external input)",
      "heartbeat"            => "internal timer (no external input)"
    }

    triggers =
      trigger_order
      |> Enum.map(fn type ->
        atom = String.to_existing_atom(type)
        %{
          "type"        => type,
          "taint"       => to_string(Map.get(trigger_taints, atom, :low)),
          "sensitivity" => to_string(Map.get(trigger_sensitivities, atom, :low)),
          "note"        => Map.get(trigger_notes, type, "")
        }
      end)

    # Serialize the 2D risk matrix
    risk_matrix =
      RiskScorer.risk_matrix()
      |> Enum.map(fn {{taint, sensitivity}, risk} ->
        %{
          "taint" => to_string(taint),
          "sensitivity" => to_string(sensitivity),
          "risk" => to_string(risk)
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "tools" => tools,
        "triggers" => triggers,
        "risk_matrix" => risk_matrix
      })
    )
  end

  # --- Graph Analysis ---

  get "/graph/analysis" do
    definitions = TriggerRouter.list_agents()
    manifest = Workspace.read_risk_manifest()

    # Build two-axis worst-case levels, override with live session data
    all_defs = Map.new(definitions, fn d -> {d.name, d} end)

    worst_case_taints =
      definitions
      |> Enum.map(fn def -> {def.name, GraphAnalyzer.worst_case_taint(def, all_defs)} end)
      |> Map.new()

    worst_case_sensitivities =
      definitions
      |> Enum.map(fn def -> {def.name, GraphAnalyzer.worst_case_sensitivity(def)} end)
      |> Map.new()

    live_sessions = AgentSupervisor.list_sessions()

    live_taints =
      live_sessions
      |> Enum.map(fn session -> {session.definition.name, session.taint_level} end)
      |> Map.new()

    live_sensitivities =
      live_sessions
      |> Enum.map(fn session -> {session.definition.name, session.sensitivity_level} end)
      |> Map.new()

    taint_levels =
      Map.merge(worst_case_taints, live_taints, fn _k, wc, live ->
        InformationClassifier.higher_level(wc, live)
      end)

    sensitivity_levels =
      Map.merge(worst_case_sensitivities, live_sensitivities, fn _k, wc, live ->
        InformationClassifier.higher_level(wc, live)
      end)

    # Combined levels map for backward compat with analyze/2
    info_levels =
      definitions
      |> Enum.map(fn def ->
        t = Map.get(taint_levels, def.name, :low)
        s = Map.get(sensitivity_levels, def.name, :low)
        {def.name, %{taint: t, sensitivity: s}}
      end)
      |> Map.new()

    analysis = GraphAnalyzer.analyze(definitions, manifest, info_levels)
    biba = GraphAnalyzer.biba_violations(analysis, definitions, info_levels)
    blp = GraphAnalyzer.bell_lapadula_violations(definitions, manifest, info_levels)

    # Build violation lookup sets for flat edges
    biba_set =
      MapSet.new(biba, fn v -> {v["writer"], v["reader"]} end)

    blp_set =
      MapSet.new(blp, fn v -> {v["writer"], v["reader"]} end)

    # Build flat edge list from analysis incoming_edges
    flat_edges =
      analysis
      |> Enum.flat_map(fn {target_name, %{incoming_edges: edges}} ->
        Enum.map(edges, fn edge ->
          edge_type = Map.get(edge, :edge_type, :filesystem)
          %{
            "from" => edge.from,
            "to" => target_name,
            "edge_type" => to_string(edge_type),
            "paths" => edge.paths,
            "biba_violation" => MapSet.member?(biba_set, {edge.from, target_name}),
            "blp_violation" => MapSet.member?(blp_set, {edge.from, target_name}),
            "max_category" => Map.get(edge, :max_category),
            "budget_bits" => Map.get(edge, :budget_bits)
          }
        end)
      end)

    # Add per-agent enrichments: effective_risk, worst_case levels, tool_drivers
    enriched_analysis =
      serialize_analysis(analysis)
      |> Map.new(fn {name, data} ->
        definition = all_defs[name]
        prop_t = data["propagated_taint"]
        prop_s = data["propagated_sensitivity"]
        wc_t = Map.get(worst_case_taints, name, :low)
        wc_s = Map.get(worst_case_sensitivities, name, :low)

        merged_t = Map.get(taint_levels, name, :low)
        merged_s = Map.get(sensitivity_levels, name, :low)
        eff_t = if prop_t, do: String.to_existing_atom(prop_t), else: merged_t
        eff_s = if prop_s, do: String.to_existing_atom(prop_s), else: merged_s
        cap = RiskScorer.infer_capability(definition.tools, definition.network)
        eff_risk = RiskScorer.effective_risk(eff_t, eff_s, cap)

        drivers = GraphAnalyzer.rating_drivers(definition, all_defs)

        # Merge topology edge sources into driver lists
        entry = analysis[name] || %{}
        edge_taint_sources =
          Map.get(entry, :taint_sources, [])
          |> Enum.map(fn src ->
            %{source: "edge:#{src.from}", level: src.contributed, kind: :input, edge_type: src.edge_type}
          end)

        edge_sensitivity_sources =
          Map.get(entry, :sensitivity_sources, [])
          |> Enum.map(fn src ->
            %{source: "edge:#{src.from}", level: src.contributed, kind: :input, edge_type: src.edge_type}
          end)

        merged_taint = drivers.taint_sources ++ edge_taint_sources
        merged_sensitivity = drivers.sensitivity_sources ++ edge_sensitivity_sources

        serialize_source = fn d ->
          base = %{"source" => d.source, "level" => to_string(d.level), "kind" => to_string(d.kind)}
          if Map.has_key?(d, :edge_type), do: Map.put(base, "edge_type", to_string(d.edge_type)), else: base
        end

        {name, Map.merge(data, %{
          "effective_risk" => RiskScorer.format_risk(eff_risk),
          "worst_case_taint" => to_string(wc_t),
          "worst_case_sensitivity" => to_string(wc_s),
          "taint_sources" => Enum.map(merged_taint, serialize_source),
          "sensitivity_sources" => Enum.map(merged_sensitivity, serialize_source),
          "capability_drivers" => Enum.map(drivers.capability_drivers, fn d -> %{"tool" => d.tool, "level" => to_string(d.level)} end)
        })}
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "agents" => enriched_analysis,
        "edges" => flat_edges,
        "biba_violations" => biba,
        "blp_violations" => blp
      })
    )
  end

  # --- Webhook Endpoint Management (local only) ---

  get "/webhook-endpoints" do
    endpoints = WebhookRegistry.list()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "endpoints" => Enum.map(endpoints, &WebhookEndpoint.to_public_map/1),
        "count" => length(endpoints)
      })
    )
  end

  post "/webhook-endpoints" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, params} when is_map(params) ->
        case WebhookRegistry.create(params) do
          {:ok, endpoint} ->
            # Return full details including secret (only shown on creation)
            response =
              WebhookEndpoint.to_public_map(endpoint)
              |> Map.put("signing_secret", endpoint.signing_secret)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(201, Jason.encode!(response))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              400,
              Jason.encode!(%{
                "error" => "validation_failed",
                "reason" => inspect(reason)
              })
            )
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "invalid_json"}))
    end
  end

  get "/webhook-endpoints/:id" do
    case WebhookRegistry.lookup(id) do
      {:ok, endpoint} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(WebhookEndpoint.to_public_map(endpoint)))

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  put "/webhook-endpoints/:id" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, params} when is_map(params) ->
        case WebhookRegistry.update(id, params) do
          {:ok, endpoint} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(WebhookEndpoint.to_public_map(endpoint)))

          {:error, :not_found} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{"error" => "invalid_json"}))
    end
  end

  delete "/webhook-endpoints/:id" do
    case WebhookRegistry.delete(id) do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{"status" => "deleted", "id" => id}))

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  post "/webhook-endpoints/:id/rotate-secret" do
    case WebhookRegistry.rotate_secret(id) do
      {:ok, endpoint} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "new_secret" => endpoint.signing_secret,
            "previous_secret_valid_until" =>
              endpoint.rotated_at
              |> DateTime.add(3600, :second)
              |> DateTime.to_iso8601(),
            "message" => "Both old and new secrets will be accepted for 1 hour"
          })
        )

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"error" => "not_found", "id" => id}))
    end
  end

  # --- Session Logs ---

  get "/logs" do
    agents = SessionLogger.list_agents()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"agents" => agents}))
  end

  get "/logs/:agent_name" do
    sessions = SessionLogger.list_sessions(agent_name)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{"sessions" => sessions}))
  end

  get "/logs/:agent_name/:session_id" do
    case SessionLogger.read_session(agent_name, session_id) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> send_resp(200, content)

      {:error, :not_found} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(%{
            "error" => "not_found",
            "agent_name" => agent_name,
            "session_id" => session_id
          })
        )
    end
  end

  # --- Health Check ---

  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "status" => "ok",
        "active_sessions" => AgentSupervisor.count_sessions()
      })
    )
  end

  # --- Catch-all ---

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"error" => "not_found"}))
  end

  # --- Body Reading Plug ---

  @doc false
  def fetch_raw_body(conn, _opts) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        Plug.Conn.assign(conn, :raw_body, body)

      {:more, _partial, conn} ->
        Plug.Conn.assign(conn, :raw_body, "")

      {:error, _reason} ->
        Plug.Conn.assign(conn, :raw_body, "")
    end
  end

  # --- Private Helpers ---

  @spec extract_source_ip(Plug.Conn.t()) :: String.t()
  defp extract_source_ip(conn) do
    # Prefer CF-Connecting-IP (set by Cloudflare Tunnel), then X-Forwarded-For,
    # then fall back to the raw peer address.
    case Plug.Conn.get_req_header(conn, "cf-connecting-ip") do
      [ip | _] ->
        String.trim(ip)

      [] ->
        case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
          [forwarded | _] ->
            forwarded |> String.split(",") |> List.first() |> String.trim()

          [] ->
            conn.remote_ip |> :inet.ntoa() |> List.to_string()
        end
    end
  end

  @spec extract_bearer_token(Plug.Conn.t()) :: String.t() | nil
  defp extract_bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  @spec get_trigger_type(Plug.Conn.t()) :: atom()
  defp get_trigger_type(conn) do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"trigger_type" => type}} when is_binary(type) ->
        String.to_existing_atom(type)

      _ ->
        :external_message
    end
  rescue
    ArgumentError -> :external_message
  end

  @spec get_stop_reason(Plug.Conn.t()) :: String.t()
  defp get_stop_reason(conn) do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> reason
      _ -> "operator requested via API"
    end
  end

  @spec parse_date(String.t() | nil) :: {:ok, Date.t()} | {:error, String.t()}
  defp parse_date(nil) do
    # Default to today if no since param
    {:ok, Date.utc_today()}
  end

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, _date} = result -> result
      {:error, _} -> {:error, "Expected ISO 8601 date format (YYYY-MM-DD), got: #{date_string}"}
    end
  end

  # Deprecated: maps taint_level to old binary taint_status for backwards compat
  @spec deprecated_taint_status(atom()) :: String.t()
  defp deprecated_taint_status(:low), do: "clean"
  defp deprecated_taint_status(:medium), do: "tainted"
  defp deprecated_taint_status(:high), do: "tainted"

  @spec serialize_analysis(map()) :: map()
  defp serialize_analysis(analysis) do
    Map.new(analysis, fn {name, entry} ->
      {name,
       %{
         "max_input_taint" => to_string(entry.max_input_taint),
         "max_input_sensitivity" => to_string(entry.max_input_sensitivity),
         "max_input_risk" => to_string(entry.max_input_risk),
         "capability_level" => to_string(entry.capability_level),
         "risk_chain" => entry.risk_chain,
         "propagated_taint" => if(entry[:propagated_taint], do: to_string(entry.propagated_taint), else: nil),
         "propagated_sensitivity" => if(entry[:propagated_sensitivity], do: to_string(entry.propagated_sensitivity), else: nil)
       }}
    end)
  end

  @spec serialize_bcp_channels([TriOnyx.AgentDefinition.bcp_channel()]) :: [map()]
  defp serialize_bcp_channels(channels) do
    Enum.map(channels, fn ch ->
      %{
        "peer" => ch.peer,
        "role" => to_string(ch.role),
        "max_category" => ch.max_category,
        "budget_bits" => ch.budget_bits,
        "max_cat2_queries" => ch.max_cat2_queries,
        "max_cat3_queries" => ch.max_cat3_queries
      }
    end)
  end

  @spec format_network(TriOnyx.AgentDefinition.network_policy()) :: String.t() | [String.t()]
  defp format_network(:none), do: "none"
  defp format_network(:outbound), do: "outbound"
  defp format_network(hosts) when is_list(hosts), do: hosts

  # --- CORS Plug ---

  @doc false
  def cors(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
    |> send_resp(204, "")
    |> halt()
  end

  def cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, PUT, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type, authorization")
  end

  # --- SSE Helpers ---

  @spec sse_loop(Plug.Conn.t()) :: Plug.Conn.t()
  defp sse_loop(conn) do
    receive do
      {:event_bus, _session_id, event} ->
        event_type = Map.get(event, "type", "message")

        case Plug.Conn.chunk(conn, sse_encode(event_type, event)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _reason} -> conn
        end
    after
      30_000 ->
        # Send keepalive comment to prevent proxy/browser timeout
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_loop(conn)
          {:error, _reason} -> conn
        end
    end
  end

  @spec sse_encode(String.t(), map()) :: String.t()
  defp sse_encode(event_type, data) do
    "event: #{event_type}\ndata: #{Jason.encode!(data)}\n\n"
  end
end
