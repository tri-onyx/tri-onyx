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
  - `POST /heartbeats/:agent_name/trigger` — manually trigger a heartbeat
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
  - `GET /api/workspace/tree` — workspace file tree with taint/sensitivity/git status
  - `GET /api/workspace/file?path=...` — file detail with git provenance and commit trailers

  Uses Bandit as the HTTP server.
  """

  use Plug.Router

  require Logger

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSession
  alias TriOnyx.InformationClassifier
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.AuditLog
  alias TriOnyx.ConnectorHandler
  alias TriOnyx.EventBus
  alias TriOnyx.GraphAnalyzer
  alias TriOnyx.RiskManifest
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
    |> send_json(status, response)
  end

  # --- Legacy Webhook Trigger (deprecated — use /hooks/:endpoint_id) ---

  post "/webhooks/:agent_name" do
    Logger.warning("Deprecated: POST /webhooks/#{agent_name} — use /hooks/:endpoint_id instead")
    body = conn.assigns[:raw_body] || ""
    {status, response} = Webhook.handle(agent_name, body)

    conn
    |> send_json(status, response)
  end

  # --- External Message Trigger ---

  post "/messages" do
    body = conn.assigns[:raw_body] || ""
    api_key = extract_bearer_token(conn)
    {status, response} = ExternalMessage.handle(body, api_key)

    conn
    |> send_json(status, response)
  end

  # --- Agent Management ---

  # IMPORTANT: /agents/schema MUST be defined before /agents/:name
  # because Plug matches routes in definition order and :name would swallow "schema".
  get "/agents/schema" do
    schema = AgentDefinition.schema()
    tool_groups =
      TriOnyx.ToolRegistry.display_entries()
      |> Enum.map(fn entry ->
        %{
          "key" => entry.key,
          "display" => entry.display,
          "variant" => entry.variant,
          "group" => entry.group,
          "note" => entry.note
        }
      end)

    agents = TriggerRouter.list_agents()
    known_agents = agents |> Enum.map(& &1.name) |> Enum.sort()

    # Slack channel ownership, consumed by connectors to route channel
    # messages, heartbeats, approvals, and inter-agent mirrors. Agents
    # with an explicit slack_channel bind to that ID; agents with only a
    # github_repo get a channel auto-provisioned by the connector from
    # the repo name.
    channel_bindings =
      agents
      |> Enum.filter(&(&1.slack_channel || &1.github_repo))
      |> Enum.map(
        &%{
          "agent" => &1.name,
          "slack_channel" => &1.slack_channel,
          "github_repo" => &1.github_repo
        }
      )
      |> Enum.sort_by(& &1["agent"])

    conn
    |> send_json(200, %{
      "fields" => schema.fields,
      "groups" => schema.groups,
      "tool_groups" => tool_groups,
      "known_tools" => TriOnyx.ToolRegistry.known_tools(),
      "tool_briefs" => TriOnyx.ToolRegistry.brief_specs(),
      "session_events" => %{
        "types" => TriOnyx.SessionEvents.event_types(),
        "chat_visible" => TriOnyx.SessionEvents.chat_visible(),
        "sse_meta" => TriOnyx.SessionEvents.sse_meta_types()
      },
      "known_agents" => known_agents,
      "channel_bindings" => channel_bindings,
      "risk_model" => risk_model_payload()
    })
  end

  get "/agents" do
    agents = TriggerRouter.list_agents()
    sessions = AgentSupervisor.list_sessions()
    all_defs = Map.new(agents, fn d -> {d.name, d} end)

    agent_list =
      Enum.map(agents, fn definition ->
        session = Enum.find(sessions, fn s -> s.definition.name == definition.name end)
        active_count = Enum.count(sessions, fn s -> s.definition.name == definition.name end)
        logged_sessions = SessionLogger.list_sessions(definition.name)

        base =
          definition
          |> serialize_definition_summary()
          |> Map.merge(%{
            "session_count" => length(logged_sessions),
            "active_session_count" => active_count
          })

        if session do
          Map.merge(base, session_risk_fields(session))
        else
          Map.merge(base, inactive_risk_fields(definition, all_defs))
        end
      end)

    conn
    |> send_json(200, %{"agents" => agent_list})
  end

  get "/agents/:name" do
    case TriggerRouter.get_agent(name) do
      {:ok, definition} ->
        sessions = AgentSupervisor.list_sessions()
        agent_sessions = Enum.filter(sessions, fn s -> s.definition.name == name end)
        session = List.first(agent_sessions)
        all_defs = Map.new(TriggerRouter.list_agents(), fn d -> {d.name, d} end)

        detail =
          definition
          |> serialize_definition_summary()
          |> Map.merge(%{
            "fs_read" => definition.fs_read,
            "fs_write" => definition.fs_write,
            "send_to" => definition.send_to,
            "receive_from" => definition.receive_from,
            "github_repo" => definition.github_repo,
            "github_read_repos" => definition.github_read_repos,
            "slack_channel" => definition.slack_channel,
            "bcp_channels" => serialize_bcp_channels(definition.bcp_channels),
            "capability_level" => to_string(RiskScorer.infer_capability(definition.tools, definition.network, definition))
          })

        active_sessions =
          Enum.map(agent_sessions, fn s ->
            %{
              "session_id" => s.id,
              "session_key" => s.session_key,
              "session_label" => s[:session_label],
              "status" => to_string(s.status),
              "started_at" => DateTime.to_iso8601(s.started_at),
              "effective_risk" => RiskScorer.format_risk(s.effective_risk)
            }
          end)

        detail = Map.put(detail, "active_sessions", active_sessions)

        detail =
          if session do
            detail
            |> Map.merge(session_risk_fields(session))
            |> Map.put("information_sources", session.information_sources)
          else
            Map.merge(detail, inactive_risk_fields(definition, all_defs))
          end

        conn
        |> send_json(200, detail)

      :error ->
        conn
        |> send_json(404, %{"error" => "agent_not_found", "name" => name})
    end
  end

  get "/agents/:name/definition" do
    if not valid_agent_name?(name) do
      send_invalid_name(conn)
    else
      agents_dir = TriOnyx.agents_dir()
      file_path = Path.join(agents_dir, "#{name}.md")

      if File.regular?(file_path) do
        content = File.read!(file_path)

        case AgentDefinition.parse(content) do
          {:ok, definition} ->
            frontmatter = %{
              "name" => definition.name,
              "description" => definition.description,
              "model" => definition.model,
              "tools" => definition.tools,
              "network" => format_network(definition.network),
              "fs_read" => definition.fs_read,
              "fs_write" => definition.fs_write,
              "send_to" => definition.send_to,
              "receive_from" => definition.receive_from,
              "restart_targets" => definition.restart_targets,
              "heartbeat_every" => format_duration(definition.heartbeat_every),
              "idle_timeout" => format_duration(definition.idle_timeout),
              "bcp_channels" => serialize_bcp_channels_for_edit(definition.bcp_channels),
              "cron_schedules" => serialize_cron_schedules_for_edit(definition.cron_schedules),
              "skills" => definition.skills,
              "plugins" => definition.plugins,
              "base_taint" => to_string(definition.base_taint),
              "max_effective_risk" => to_string(definition.max_effective_risk),
              "input_sources" => Enum.map(definition.input_sources, &to_string/1),
              "browser" => definition.browser,
              "docker_socket" => definition.docker_socket,
              "trionyx_repo" => definition.trionyx_repo,
              "github_repo" => definition.github_repo,
              "github_read_repos" => definition.github_read_repos,
              "slack_channel" => definition.slack_channel,
              "exclude_from_personalization" => definition.exclude_from_personalization,
              "reflection" => definition.reflection
            }

            conn
            |> send_json(200, %{
              "frontmatter" => frontmatter,
              "system_prompt" => definition.system_prompt
            })

          {:error, reason} ->
            conn
            |> send_json(500, %{
              "error" => "parse_failed",
              "message" => "Definition file exists but failed to parse: #{inspect(reason)}"
            })
        end
      else
        conn
        |> send_json(404, %{"error" => "agent_not_found", "name" => name})
      end
    end
  end

  get "/agents/:name/context" do
    case TriggerRouter.get_agent(name) do
      {:ok, definition} ->
        workspace_context = TriOnyx.Workspace.read_context(name)
        assembled = TriOnyx.Workspace.PromptAssembler.assemble(definition, workspace_context)

        conn
        |> send_json(200, %{"context" => assembled})

      :error ->
        conn
        |> send_json(404, %{"error" => "agent_not_found", "name" => name})
    end
  end

  post "/agents" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, params} when is_map(params) ->
        markdown = AgentDefinition.to_markdown(params)

        case AgentDefinition.parse(markdown) do
          {:ok, definition} ->
            agents_dir = TriOnyx.agents_dir()
            file_path = Path.join(agents_dir, "#{definition.name}.md")

            if File.regular?(file_path) do
              conn
              |> send_json(409, %{
                "error" => "already_exists",
                "message" => "Agent '#{definition.name}' already exists"
              })
            else
              File.write!(file_path, markdown)
              TriggerRouter.load_agents()

              conn
              |> send_json(201, %{
                "status" => "created",
                "name" => definition.name
              })
            end

          {:error, reason} ->
            conn
            |> send_json(400, %{
              "error" => "validation_failed",
              "details" => [AgentDefinition.format_error(reason)]
            })
        end

      _ ->
        conn
        |> bad_request("Expected JSON object")
    end
  end

  put "/agents/:name" do
    if not valid_agent_name?(name) do
      send_invalid_name(conn)
    else
      body = conn.assigns[:raw_body] || ""

      case Jason.decode(body) do
        {:ok, params} when is_map(params) ->
          agents_dir = TriOnyx.agents_dir()
          file_path = Path.join(agents_dir, "#{name}.md")

          if not File.regular?(file_path) do
            conn
            |> send_json(404, %{"error" => "agent_not_found", "name" => name})
          else
            params = Map.put(params, "name", name)
            markdown = AgentDefinition.to_markdown(params)

            case AgentDefinition.parse(markdown) do
              {:ok, _definition} ->
                File.write!(file_path, markdown)
                TriggerRouter.load_agents()

                conn
                |> send_json(200, %{
                  "status" => "updated",
                  "name" => name
                })

              {:error, reason} ->
                conn
                |> send_json(400, %{
                  "error" => "validation_failed",
                  "details" => [AgentDefinition.format_error(reason)]
                })
            end
          end

        _ ->
          conn
          |> bad_request("Expected JSON object")
      end
    end
  end

  delete "/agents/:name" do
    if not valid_agent_name?(name) do
      send_invalid_name(conn)
    else
      agents_dir = TriOnyx.agents_dir()
      file_path = Path.join(agents_dir, "#{name}.md")

      if not File.regular?(file_path) do
        conn
        |> send_json(404, %{"error" => "agent_not_found", "name" => name})
      else
        sessions = AgentSupervisor.list_sessions()
        active = Enum.any?(sessions, fn s -> s.definition.name == name end)

        if active do
          conn
          |> send_json(409, %{
            "error" => "agent_has_active_sessions",
            "message" => "Stop all sessions before deleting"
          })
        else
          File.rm!(file_path)
          TriggerRouter.load_agents()

          conn
          |> send_json(200, %{"status" => "deleted", "name" => name})
        end
      end
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
            |> send_json(
              201,
              %{
                "status" => "started",
                "agent" => name,
                "pid" => inspect(pid)
              }
            )

          {:error, reason} ->
            conn
            |> send_json(
              500,
              %{
                "error" => "start_failed",
                "reason" => inspect(reason)
              }
            )
        end

      :error ->
        conn
        |> send_json(404, %{"error" => "agent_not_found", "name" => name})
    end
  end

  post "/agents/:name/stop" do
    body = conn.assigns[:raw_body] || ""
    target_session_id =
      case Jason.decode(body) do
        {:ok, %{"session_id" => sid}} when is_binary(sid) and sid != "" -> sid
        _ -> nil
      end

    session_result =
      if target_session_id do
        AgentSupervisor.find_session_by_id(target_session_id)
      else
        AgentSupervisor.find_session(name)
      end

    case session_result do
      {:ok, pid} ->
        reason = get_stop_reason(conn)
        AgentSupervisor.stop_session(AgentSupervisor, pid, reason)

        conn
        |> send_json(200, %{"status" => "stopped", "agent" => name})

      :error ->
        conn
        |> send_json(
          404,
          %{
            "error" => "no_active_session",
            "agent" => name
          }
        )
    end
  end

  # --- Agent Prompt ---

  post "/agents/:name/prompt" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"content" => content} = payload} when is_binary(content) ->
        target_session_id = Map.get(payload, "session_id")

        session_result =
          if is_binary(target_session_id) and target_session_id != "" do
            AgentSupervisor.find_session_by_id(target_session_id)
          else
            AgentSupervisor.find_session(name)
          end

        case session_result do
          {:ok, pid} ->
            case AgentSession.send_prompt(pid, content) do
              :ok ->
                # Mirror the user's frontend message into the agent's bound
                # chat room (the connector resolves which room, if any) so
                # channel members see both sides of frontend conversations.
                TriOnyx.ConnectorHandler.broadcast_to_connectors(
                  Jason.encode!(%{
                    "type" => "prompt_mirror",
                    "agent_name" => name,
                    "source" => "web",
                    "content" => content
                  })
                )

                conn
                |> send_json(200, %{"status" => "sent", "agent" => name})

              {:error, :not_ready} ->
                conn
                |> send_json(
                  409,
                  %{
                    "error" => "not_ready",
                    "message" => "Agent session is not in ready state"
                  }
                )
            end

          :error ->
            conn
            |> send_json(
              404,
              %{
                "error" => "no_active_session",
                "agent" => name
              }
            )
        end

      _ ->
        conn
        |> bad_request("Expected JSON with \"content\" field")
    end
  end

  # --- SSE Event Stream ---

  get "/agents/:name/events" do
    conn = Plug.Conn.fetch_query_params(conn)
    target_session_id = conn.params["session_id"]

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    session_result =
      if is_binary(target_session_id) and target_session_id != "" do
        AgentSupervisor.find_session_by_id(target_session_id)
      else
        AgentSupervisor.find_session(name)
      end

    case session_result do
      {:ok, pid} ->
        status = AgentSession.get_status(pid)
        session_id = status.id

        EventBus.subscribe(session_id)

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
        EventBus.subscribe_agent(name)

        {:ok, conn} =
          Plug.Conn.chunk(
            conn,
            sse_encode("waiting", %{"agent" => name})
          )

        sse_wait_loop(conn, name)
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
        |> send_json(200, %{"entries" => entries, "count" => length(entries)})

      {:error, message} ->
        conn
        |> send_json(400, %{"error" => "invalid_date", "message" => message})
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
            |> send_json(200, %{"status" => "reviewed", "paths" => updated_paths})

          {:error, reason} ->
            conn
            |> send_json(
              500,
              %{
                "error" => "review_failed",
                "reason" => inspect(reason)
              }
            )
        end

      _ ->
        conn
        |> bad_request("Expected JSON with \"paths\" (list) and \"reviewer\" (string) fields")
    end
  end

  # --- Heartbeat Management ---

  get "/heartbeats" do
    heartbeats = Scheduler.list_heartbeats()
    enabled = Scheduler.enabled?()

    conn
    |> send_json(
      200,
      %{
        "heartbeats" => heartbeats,
        "enabled" => enabled
      }
    )
  end

  put "/heartbeats/enabled" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"enabled" => enabled}} when is_boolean(enabled) ->
        :ok = Scheduler.set_enabled(enabled)

        conn
        |> send_json(200, %{"enabled" => enabled})

      _ ->
        conn
        |> bad_request("Expected JSON with boolean \"enabled\" field")
    end
  end

  post "/heartbeats/:agent_name" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, %{"interval_ms" => interval_ms}}
      when is_integer(interval_ms) and interval_ms > 0 ->
        :ok = Scheduler.schedule_heartbeat(agent_name, interval_ms)

        conn
        |> send_json(
          200,
          %{
            "status" => "scheduled",
            "agent_name" => agent_name,
            "interval_ms" => interval_ms
          }
        )

      _ ->
        conn
        |> bad_request("Expected JSON with positive integer \"interval_ms\" field")
    end
  end

  post "/heartbeats/:agent_name/trigger" do
    case Scheduler.trigger_heartbeat(agent_name) do
      {:ok, _pid} ->
        conn
        |> send_json(200, %{"status" => "triggered", "agent_name" => agent_name})

      {:error, reason} ->
        conn
        |> send_json(
          500,
          %{
            "error" => "trigger_failed",
            "reason" => inspect(reason)
          }
        )
    end
  end

  delete "/heartbeats/:agent_name" do
    case Scheduler.cancel_heartbeat(agent_name) do
      :ok ->
        conn
        |> send_json(200, %{"status" => "cancelled", "agent_name" => agent_name})

      {:error, :not_found} ->
        conn
        |> send_json(
          404,
          %{
            "error" => "not_found",
            "agent_name" => agent_name
          }
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
    |> send_json(200, %{"approvals" => serialized})
  end

  post "/bcp/approvals/:id/approve" do
    case ApprovalQueue.approve(id) do
      {:ok, item} ->
        conn
        |> send_json(
          200,
          %{
            "status" => "approved",
            "id" => item.id,
            "from_agent" => item.from_agent,
            "to_agent" => item.to_agent
          }
        )

      {:error, :not_found} ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
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
        |> send_json(
          200,
          %{
            "status" => "rejected",
            "id" => item.id,
            "reason" => reason,
            "from_agent" => item.from_agent,
            "to_agent" => item.to_agent
          }
        )

      {:error, :not_found} ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
    end
  end

  # --- Action Approval Queue (delegates to unified ApprovalQueue) ---

  get "/actions/approvals" do
    items =
      ApprovalQueue.list_pending()
      |> Enum.filter(fn item -> Map.get(item, :kind) == "action" end)

    serialized =
      Enum.map(items, fn item ->
        %{
          "id" => item.id,
          "kind" => "action",
          "agent_name" => Map.get(item, :agent_name, ""),
          "session_id" => Map.get(item, :session_id, ""),
          "tool_name" => Map.get(item, :tool_name, ""),
          "tool_input" => Map.get(item, :tool_input, %{}),
          "submitted_at" => DateTime.to_iso8601(item.submitted_at)
        }
      end)

    conn
    |> send_json(200, %{"approvals" => serialized})
  end

  post "/actions/approvals/:id/approve" do
    case ApprovalQueue.approve(id) do
      {:ok, item} ->
        conn
        |> send_json(
          200,
          %{
            "status" => "approved",
            "id" => item.id,
            "agent_name" => Map.get(item, :agent_name, ""),
            "tool_name" => Map.get(item, :tool_name, "")
          }
        )

      {:error, :not_found} ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
    end
  end

  post "/actions/approvals/:id/reject" do
    body = conn.assigns[:raw_body] || ""

    reason =
      case Jason.decode(body) do
        {:ok, %{"reason" => r}} when is_binary(r) -> r
        _ -> "no reason provided"
      end

    case ApprovalQueue.reject(id, reason) do
      {:ok, item} ->
        conn
        |> send_json(
          200,
          %{
            "status" => "rejected",
            "id" => item.id,
            "reason" => reason,
            "agent_name" => Map.get(item, :agent_name, ""),
            "tool_name" => Map.get(item, :tool_name, "")
          }
        )

      {:error, :not_found} ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
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
    |> send_json(200, %{"connectors" => connectors})
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

    # The full risk model (2D matrix, level ordering, capability rule) is
    # built by risk_model_payload/0 so /agents/schema and this endpoint share
    # one serialization.
    risk_model = risk_model_payload()

    conn
    |> send_json(
      200,
      %{
        "tools" => tools,
        "triggers" => triggers,
        "risk_matrix" => risk_model["risk_matrix"],
        "risk_model" => risk_model
      }
    )
  end

  # --- Graph Analysis ---

  get "/graph/analysis" do
    definitions = TriggerRouter.list_agents()
    manifest = RiskManifest.snapshot()

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
            "rates" => serialize_rates(Map.get(edge, :rates))
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
        cap = RiskScorer.infer_capability(definition.tools, definition.network, definition)
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
    |> send_json(
      200,
      %{
        "agents" => enriched_analysis,
        "edges" => flat_edges,
        "biba_violations" => biba,
        "blp_violations" => blp
      }
    )
  end

  # --- Webhook Endpoint Management (local only) ---

  get "/webhook-endpoints" do
    endpoints = WebhookRegistry.list()

    conn
    |> send_json(
      200,
      %{
        "endpoints" => Enum.map(endpoints, &WebhookEndpoint.to_public_map/1),
        "count" => length(endpoints)
      }
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
            |> send_json(201, response)

          {:error, reason} ->
            conn
            |> send_json(
              400,
              %{
                "error" => "validation_failed",
                "reason" => inspect(reason)
              }
            )
        end

      _ ->
        conn
        |> send_json(400, %{"error" => "invalid_json"})
    end
  end

  get "/webhook-endpoints/:id" do
    case WebhookRegistry.lookup(id) do
      {:ok, endpoint} ->
        conn
        |> send_json(200, WebhookEndpoint.to_public_map(endpoint))

      :error ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
    end
  end

  put "/webhook-endpoints/:id" do
    body = conn.assigns[:raw_body] || ""

    case Jason.decode(body) do
      {:ok, params} when is_map(params) ->
        case WebhookRegistry.update(id, params) do
          {:ok, endpoint} ->
            conn
            |> send_json(200, WebhookEndpoint.to_public_map(endpoint))

          {:error, :not_found} ->
            conn
            |> send_json(404, %{"error" => "not_found", "id" => id})
        end

      _ ->
        conn
        |> send_json(400, %{"error" => "invalid_json"})
    end
  end

  delete "/webhook-endpoints/:id" do
    case WebhookRegistry.delete(id) do
      :ok ->
        conn
        |> send_json(200, %{"status" => "deleted", "id" => id})

      {:error, :not_found} ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
    end
  end

  post "/webhook-endpoints/:id/rotate-secret" do
    case WebhookRegistry.rotate_secret(id) do
      {:ok, endpoint} ->
        conn
        |> send_json(
          200,
          %{
            "new_secret" => endpoint.signing_secret,
            "previous_secret_valid_until" =>
              endpoint.rotated_at
              |> DateTime.add(3600, :second)
              |> DateTime.to_iso8601(),
            "message" => "Both old and new secrets will be accepted for 1 hour"
          }
        )

      {:error, :not_found} ->
        conn
        |> send_json(404, %{"error" => "not_found", "id" => id})
    end
  end

  # --- Session Logs ---

  get "/logs" do
    agents = SessionLogger.list_agents()

    conn
    |> send_json(200, %{"agents" => agents})
  end

  get "/logs/:agent_name" do
    sessions = SessionLogger.list_sessions(agent_name)

    conn
    |> send_json(200, %{"sessions" => sessions})
  end

  get "/logs/:agent_name/:session_id" do
    case SessionLogger.read_session(agent_name, session_id) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("application/x-ndjson")
        |> send_resp(200, content)

      {:error, :not_found} ->
        conn
        |> send_json(
          404,
          %{
            "error" => "not_found",
            "agent_name" => agent_name,
            "session_id" => session_id
          }
        )
    end
  end

  # --- Session Images ---

  get "/images/:agent_name/:session_id/:image_id" do
    images_dir = Path.join(["logs", agent_name, "#{session_id}_images"])
    file_path = Path.join(images_dir, image_id) |> Path.expand()
    safe_prefix = Path.expand(images_dir)

    content_types = %{
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg",
      ".gif" => "image/gif",
      ".webp" => "image/webp",
      ".svg" => "image/svg+xml"
    }

    cond do
      not String.starts_with?(file_path, safe_prefix) ->
        conn |> send_resp(403, "forbidden")

      not File.regular?(file_path) ->
        conn |> send_resp(404, "not found")

      true ->
        ext = Path.extname(image_id) |> String.downcase()
        content_type = Map.get(content_types, ext, "application/octet-stream")
        data = File.read!(file_path)

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_resp(200, data)
    end
  end

  # --- Session Audio (Speak tool output) ---

  get "/audio/:agent_name/:session_id/:audio_id" do
    audio_dir = Path.join(["logs", agent_name, "#{session_id}_audio"])
    file_path = Path.join(audio_dir, audio_id) |> Path.expand()
    safe_prefix = Path.expand(audio_dir)

    cond do
      not String.starts_with?(file_path, safe_prefix) ->
        conn |> send_resp(403, "forbidden")

      Path.extname(audio_id) != ".ogg" ->
        conn |> send_resp(403, "forbidden")

      not File.regular?(file_path) ->
        conn |> send_resp(404, "not found")

      true ->
        conn
        |> put_resp_content_type("audio/ogg")
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_resp(200, File.read!(file_path))
    end
  end

  # --- Session Pages (HTML artifacts) ---

  get "/pages/:commit/*page_path" do
    path = Enum.join(page_path, "/")
    ext = path |> Path.extname() |> String.downcase()

    cond do
      not Regex.match?(~r/\A[0-9a-f]{7,40}\z/, commit) ->
        conn |> send_resp(400, "invalid commit SHA")

      ext not in [".html", ".htm"] ->
        conn |> send_resp(403, "forbidden")

      true ->
        case Workspace.read_file_at_commit(commit, path) do
          {:ok, data} ->
            conn
            |> put_resp_content_type("text/html")
            |> put_resp_header("content-security-policy", "sandbox allow-scripts")
            |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
            |> send_resp(200, data)

          {:error, _} ->
            conn |> send_resp(404, "not found")
        end
    end
  end

  # --- Workspace Explorer ---

  get "/api/workspace/tree" do
    dir = Workspace.workspace_dir()
    safe = Workspace.git_safe_args(dir)
    manifest = RiskManifest.snapshot()

    # Get git status (porcelain format, NUL-delimited to avoid quoted paths)
    git_status_map =
      case System.cmd("git", safe ++ ["status", "--porcelain", "-z"], cd: dir, stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split(<<0>>, trim: true)
          |> Enum.reduce(%{}, fn entry, acc ->
            status = String.slice(entry, 0, 2) |> String.trim()
            path = String.slice(entry, 3..-1//1)
            Map.put(acc, path, status)
          end)

        _ ->
          %{}
      end

    # Get all tracked files (NUL-delimited to avoid quoted paths)
    tracked =
      case System.cmd("git", safe ++ ["ls-files", "-z"], cd: dir, stderr_to_stdout: true) do
        {output, 0} -> output |> String.split(<<0>>, trim: true) |> MapSet.new()
        _ -> MapSet.new()
      end

    # Combine: all tracked files + untracked from git status
    all_paths =
      MapSet.union(tracked, MapSet.new(Map.keys(git_status_map)))
      |> Enum.sort()

    files =
      Enum.map(all_paths, fn path ->
        entry = Map.get(manifest, path, %{})
        git_st = Map.get(git_status_map, path, "clean")

        %{
          "path" => path,
          "taint" => Map.get(entry, "taint_level"),
          "sensitivity" => Map.get(entry, "sensitivity_level"),
          "agent" => Map.get(entry, "agent"),
          "updated_at" => Map.get(entry, "updated_at"),
          "reviewed_by" => Map.get(entry, "reviewed_by"),
          "git_status" => git_st
        }
      end)

    conn
    |> send_json(200, %{"files" => files})
  end

  get "/api/workspace/file" do
    conn = Plug.Conn.fetch_query_params(conn)
    path = conn.params["path"]

    if is_nil(path) or path == "" do
      conn
      |> send_json(400, %{"error" => "missing path parameter"})
    else
      dir = Workspace.workspace_dir()
      safe = Workspace.git_safe_args(dir)
      manifest = RiskManifest.snapshot()
      entry = Map.get(manifest, path, %{})

      # Git status for this file
      git_st =
        case System.cmd("git", safe ++ ["status", "--porcelain", "--", path],
               cd: dir, stderr_to_stdout: true) do
          {output, 0} ->
            line = output |> String.split("\n", trim: true) |> List.first()
            if line, do: String.slice(line, 0, 2) |> String.trim(), else: "clean"
          _ -> "clean"
        end

      # Recent commits for this file (up to 10)
      commits =
        case System.cmd(
               "git",
               safe ++ ["log", "--format=%H%n%s%n%an%n%ai%n%B%n---END---", "-10", "--", path],
               cd: dir, stderr_to_stdout: true
             ) do
          {output, 0} when output != "" ->
            output
            |> String.split("---END---\n", trim: true)
            |> Enum.map(fn chunk ->
              lines = String.split(chunk, "\n")
              hash = Enum.at(lines, 0, "") |> String.slice(0, 8)
              subject = Enum.at(lines, 1, "")
              author = Enum.at(lines, 2, "")
              date = Enum.at(lines, 3, "")
              body = Enum.drop(lines, 4) |> Enum.join("\n") |> String.trim()

              trailers =
                body
                |> String.split("\n")
                |> Enum.filter(fn l ->
                  trimmed = String.trim(l)
                  String.starts_with?(trimmed, "Sc-") or
                    String.starts_with?(trimmed, "Taint-Level:") or
                    String.starts_with?(trimmed, "Sensitivity-Level:")
                end)
                |> Enum.map(fn l ->
                  trimmed = String.trim(l)
                  case String.split(trimmed, ":", parts: 2) do
                    [key, value] -> %{"key" => String.trim(key), "value" => String.trim(value)}
                    _ -> %{"key" => trimmed, "value" => ""}
                  end
                end)

              %{"hash" => hash, "subject" => subject, "author" => author, "date" => date, "trailers" => trailers}
            end)

          _ ->
            []
        end

      response =
        %{
          "path" => path,
          "taint_level" => Map.get(entry, "taint_level"),
          "sensitivity_level" => Map.get(entry, "sensitivity_level"),
          "agent" => Map.get(entry, "agent"),
          "updated_at" => Map.get(entry, "updated_at"),
          "reviewed_by" => Map.get(entry, "reviewed_by"),
          "reviewed_at" => Map.get(entry, "reviewed_at"),
          "git_status" => git_st,
          "commits" => commits
        }

      conn
      |> send_json(200, response)
    end
  end

  # --- Health Check ---

  get "/health" do
    conn
    |> send_json(
      200,
      %{
        "status" => "ok",
        "active_sessions" => AgentSupervisor.count_sessions()
      }
    )
  end

  # --- Catch-all ---

  match _ do
    conn
    |> send_json(404, %{"error" => "not_found"})
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

  @spec send_json(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  @spec bad_request(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp bad_request(conn, message) do
    send_json(conn, 400, %{"error" => "invalid_body", "message" => message})
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
  # Fully describes the risk model so consumers (the frontend graph, docs)
  # never hardcode any of it. All values are sourced from the authoritative
  # modules — never literals here:
  #   - `levels`: taint/sensitivity axis ordering (InformationClassifier)
  #   - `risk_levels`: risk severity ordering (RiskScorer)
  #   - `risk_matrix`: the 2D taint × sensitivity baseline (RiskScorer)
  #   - `capability_adjustment`: baseline_risk → adjusted_risk per capability
  @spec risk_model_payload() :: map()
  defp risk_model_payload do
    risk_matrix =
      RiskScorer.risk_matrix()
      |> Enum.map(fn {{taint, sensitivity}, risk} ->
        %{
          "taint" => to_string(taint),
          "sensitivity" => to_string(sensitivity),
          "risk" => to_string(risk)
        }
      end)

    capability_adjustment =
      RiskScorer.capability_adjustment()
      |> Map.new(fn {capability, mapping} ->
        {to_string(capability),
         Map.new(mapping, fn {baseline, adjusted} ->
           {to_string(baseline), to_string(adjusted)}
         end)}
      end)

    %{
      "levels" => Enum.map(InformationClassifier.levels(), &to_string/1),
      "risk_levels" => Enum.map(RiskScorer.risk_levels(), &to_string/1),
      "risk_matrix" => risk_matrix,
      "capability_adjustment" => capability_adjustment
    }
  end

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

  @spec serialize_definition_summary(TriOnyx.AgentDefinition.t()) :: map()
  defp serialize_definition_summary(definition) do
    %{
      "name" => definition.name,
      "description" => definition.description,
      "model" => definition.model,
      "tools" => definition.tools,
      "network" => format_network(definition.network)
    }
  end

  # Risk/status fields shared by every endpoint that reports an active session.
  @spec session_risk_fields(map()) :: map()
  defp session_risk_fields(session) do
    %{
      "session_id" => session.id,
      "status" => to_string(session.status),
      "taint_level" => to_string(session.taint_level),
      "sensitivity_level" => to_string(session.sensitivity_level),
      "information_level" => to_string(session.information_level),
      "taint_status" => deprecated_taint_status(session.taint_level),
      "input_risk" => to_string(session.input_risk),
      "effective_risk" => RiskScorer.format_risk(session.effective_risk),
      "started_at" => DateTime.to_iso8601(session.started_at)
    }
  end

  # Worst-case risk fields reported when an agent has no active session.
  @spec inactive_risk_fields(TriOnyx.AgentDefinition.t(), map()) :: map()
  defp inactive_risk_fields(definition, all_defs) do
    wc_taint = GraphAnalyzer.worst_case_taint(definition, all_defs)
    wc_sensitivity = GraphAnalyzer.worst_case_sensitivity(definition)

    %{
      "status" => "inactive",
      "taint_level" => to_string(wc_taint),
      "sensitivity_level" => to_string(wc_sensitivity),
      "information_level" =>
        to_string(InformationClassifier.higher_level(wc_taint, wc_sensitivity))
    }
  end

  @spec serialize_bcp_channels([TriOnyx.AgentDefinition.bcp_channel()]) :: [map()]
  defp serialize_bcp_channels(channels) do
    Enum.map(channels, fn ch ->
      Map.put(serialize_bcp_channel_base(ch), "max_category", ch.max_category)
    end)
  end

  defp serialize_bcp_channel_base(ch) do
    %{
      "peer" => ch.peer,
      "role" => to_string(ch.role),
      "rates" => serialize_rates(ch.rates)
    }
  end

  @spec serialize_rates(map() | nil) :: map() | nil
  defp serialize_rates(nil), do: nil

  defp serialize_rates(rates) when is_map(rates) do
    Map.new(rates, fn {key, value} ->
      {to_string(key), serialize_single_rate(value)}
    end)
  end

  defp serialize_single_rate(:denied), do: 0

  defp serialize_single_rate(%{limit: limit, window_ms: window_ms}) do
    unit =
      cond do
        window_ms <= 1_000 -> "second"
        window_ms <= 60_000 -> "minute"
        true -> "hour"
      end

    "#{limit}/#{unit}"
  end

  @spec format_duration(pos_integer() | nil) :: String.t() | nil
  defp format_duration(nil), do: nil
  defp format_duration(ms) when is_integer(ms) do
    cond do
      rem(ms, 3_600_000) == 0 -> "#{div(ms, 3_600_000)}h"
      rem(ms, 60_000) == 0 -> "#{div(ms, 60_000)}m"
      rem(ms, 1_000) == 0 -> "#{div(ms, 1_000)}s"
      true -> "#{ms}"
    end
  end

  defp serialize_bcp_channels_for_edit(channels) do
    Enum.map(channels, fn ch ->
      base = serialize_bcp_channel_base(ch)

      case ch.subscriptions do
        [] -> base
        subs ->
          Map.put(base, "subscriptions",
            Enum.map(subs, fn s ->
              sub = %{"id" => s.id, "category" => s.category}
              sub = if s.fields, do: Map.put(sub, "fields", s.fields), else: sub
              sub = if s.questions, do: Map.put(sub, "questions", s.questions), else: sub
              sub = if s.directive, do: Map.put(sub, "directive", s.directive), else: sub
              sub = if s.max_words, do: Map.put(sub, "max_words", s.max_words), else: sub
              sub
            end)
          )
      end
    end)
  end

  defp serialize_cron_schedules_for_edit(schedules) do
    Enum.map(schedules, fn s ->
      base = %{"schedule" => s.schedule, "message" => s.message}
      if s.label, do: Map.put(base, "label", s.label), else: base
    end)
  end

  @agent_name_re ~r/^[a-zA-Z0-9]([a-zA-Z0-9_-]*[a-zA-Z0-9])?$/

  defp valid_agent_name?(name) when is_binary(name) do
    byte_size(name) > 0 and byte_size(name) <= 64 and Regex.match?(@agent_name_re, name)
  end

  defp send_invalid_name(conn) do
    conn
    |> send_json(400, %{
      "error" => "invalid_name",
      "message" => "Agent name must be 1-64 alphanumeric characters, hyphens, or underscores"
    })
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

  @spec sse_wait_loop(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp sse_wait_loop(conn, agent_name) do
    receive do
      {:event_bus_agent, ^agent_name, %{"type" => "session_start", "session_id" => session_id} = event} ->
        EventBus.subscribe(session_id)

        case Plug.Conn.chunk(conn, sse_encode("session_start", event)) do
          {:ok, conn} -> sse_loop(conn)
          {:error, _reason} -> conn
        end
    after
      30_000 ->
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> sse_wait_loop(conn, agent_name)
          {:error, _reason} -> conn
        end
    end
  end

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
