defmodule TriOnyx.AgentPort do
  @moduledoc """
  GenServer wrapping an Elixir Port that runs the Python agent runtime.

  Supports two execution modes:

  - **Docker mode** — when `:definition` and `:session_id` are provided, spawns
    a Docker container configured by `TriOnyx.Sandbox` with FUSE filesystem
    isolation, network sandboxing, and environment passthrough.
  - **Legacy mode** — when no `:definition` is provided, spawns
    `uv run runtime/agent_runner.py` directly as a subprocess (for development
    and testing without Docker).

  In both modes, the port communicates via the structured JSON protocol over
  stdin/stdout. Each message is a single JSON object on its own line (JSON
  Lines format).

  This module handles:
  - Spawning and monitoring the subprocess (Docker or direct)
  - Sending structured messages to the runtime via stdin
  - Parsing JSON messages from stdout line-by-line
  - Detecting process crashes and reporting them to the parent
  - Graceful shutdown with `docker stop` fallback for Docker mode

  The agent executes its own tools via the Claude Agent SDK. Events streamed
  back from the runtime are observational — used for taint tracking and audit
  logging, not for mediating tool execution.

  See `docs/protocol.md` for the full protocol specification.
  """

  use GenServer

  require Logger

  alias TriOnyx.AgentDefinition
  alias TriOnyx.Sandbox

  @type event ::
          {:ready}
          | {:interrupted, String.t()}
          | {:text, String.t()}
          | {:tool_use, String.t(), String.t(), map()}
          | {:tool_result, String.t(), String.t(), boolean()}
          | {:result, map()}
          | {:error, String.t()}
          | {:fuse_write, String.t(), String.t()}
          | {:send_message_request, String.t(), String.t(), String.t(), map()}
          | {:bcp_query_request, String.t(), String.t(), integer(), map()}
          | {:bcp_response, String.t(), map()}
          | {:bcp_subscription_publish, String.t(), String.t(), map()}
          | {:send_email_request, String.t(), String.t()}
          | {:move_email_request, String.t(), String.t(), String.t(), String.t()}
          | {:create_folder_request, String.t(), String.t()}
          | {:restart_agent_request, String.t(), String.t(), boolean()}
          | {:calendar_query_request, String.t(), map()}
          | {:calendar_create_request, String.t(), String.t()}
          | {:calendar_update_request, String.t(), String.t()}
          | {:calendar_delete_request, String.t(), String.t(), String.t()}
          | {:submit_item_request, String.t(), String.t(), String.t(), String.t(), map()}
          | {:log, String.t(), String.t()}
          | {:port_down, atom()}

  @type start_opt ::
          {:name, GenServer.name()}
          | {:notify, pid()}
          | {:runtime_path, String.t()}
          | {:definition, AgentDefinition.t()}
          | {:session_id, String.t()}
          | {:source_dir, String.t()}
          | {:image, String.t()}

  defstruct [:port, :notify, :buffer, :container_name]

  @default_runtime_path "runtime/agent_runner.py"

  # --- Public API ---

  @doc """
  Starts the AgentPort GenServer.

  ## Docker Mode Options

  When `:definition` is provided, the port spawns a Docker container:

  - `:definition` — parsed `AgentDefinition` struct (triggers Docker mode)
  - `:session_id` — unique session identifier (required in Docker mode)
  - `:source_dir` — host directory to bind-mount (default: cwd)
  - `:image` — Docker image name (default: `tri-onyx-agent:latest`)

  ## Legacy Mode Options

  When `:definition` is not provided, the port spawns `uv run` directly:

  - `:runtime_path` — path to agent_runner.py (default: `runtime/agent_runner.py`)

  ## Common Options

  - `:notify` — pid to receive `{:agent_event, pid(), event()}` messages (required)
  - `:name` — optional GenServer name
  """
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Sends a `start` message to configure the agent runtime.
  """
  @spec send_start(GenServer.server(), map()) :: :ok
  def send_start(server, agent_config) when is_map(agent_config) do
    GenServer.cast(server, {:send, %{"type" => "start", "agent" => agent_config}})
  end

  @doc """
  Sends a `prompt` message to trigger an agent session.
  """
  @spec send_prompt(GenServer.server(), String.t(), map()) :: :ok
  def send_prompt(server, content, metadata \\ %{}) when is_binary(content) do
    GenServer.cast(
      server,
      {:send, %{"type" => "prompt", "content" => content, "metadata" => metadata}}
    )
  end

  @doc """
  Sends a `shutdown` message to request graceful termination.
  """
  @spec send_shutdown(GenServer.server(), String.t()) :: :ok
  def send_shutdown(server, reason \\ "") do
    GenServer.cast(server, {:send, %{"type" => "shutdown", "reason" => reason}})
  end

  @doc """
  Sends an `interrupt` message to cancel the active prompt.
  """
  @spec send_interrupt(GenServer.server(), String.t()) :: :ok
  def send_interrupt(server, reason \\ "") do
    GenServer.cast(server, {:send, %{"type" => "interrupt", "reason" => reason}})
  end

  @doc """
  Sends a `memory_save` message to request the agent save memory before shutdown.
  """
  @spec send_memory_save(GenServer.server(), String.t()) :: :ok
  def send_memory_save(server, reason \\ "") do
    GenServer.cast(server, {:send, %{"type" => "memory_save", "reason" => reason}})
  end

  @doc """
  Sends a `send_message_response` back to the runtime with the routing result.
  """
  @spec send_message_response(GenServer.server(), String.t(), boolean(), String.t()) :: :ok
  def send_message_response(server, request_id, success, detail \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "send_message_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail
       }}
    )
  end

  @doc """
  Sends a `bcp_query` message to the runtime, delivering an incoming BCP query
  from a Controller agent to a Reader agent's runtime.
  """
  @spec send_bcp_query(GenServer.server(), String.t(), integer(), String.t(), map()) :: :ok
  def send_bcp_query(server, query_id, category, from_agent, spec) do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "bcp_query",
         "query_id" => query_id,
         "category" => category,
         "from_agent" => from_agent
       }
       |> Map.merge(spec)}
    )
  end

  @doc """
  Sends a `bcp_query_error` message to the runtime, informing the Controller
  agent that its BCP query could not be routed.
  """
  @spec send_bcp_query_error(GenServer.server(), String.t(), String.t(), String.t()) :: :ok
  def send_bcp_query_error(server, request_id, to_agent, reason) do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "bcp_query_error",
         "request_id" => request_id,
         "to_agent" => to_agent,
         "reason" => reason
       }}
    )
  end

  @doc """
  Sends a `bcp_validation_result` message to the runtime, informing the Reader
  agent whether its BCP response passed validation.
  """
  @spec send_bcp_validation_result(
          GenServer.server(),
          String.t() | nil,
          boolean(),
          String.t(),
          String.t() | nil
        ) :: :ok
  def send_bcp_validation_result(server, query_id, success, detail \\ "", subscription_id \\ nil) do
    msg = %{
      "type" => "bcp_validation_result",
      "success" => success,
      "detail" => detail
    }

    msg = if query_id, do: Map.put(msg, "query_id", query_id), else: msg
    msg = if subscription_id, do: Map.put(msg, "subscription_id", subscription_id), else: msg
    GenServer.cast(server, {:send, msg})
  end

  @doc """
  Sends a `bcp_response_delivery` message to the runtime, delivering a validated
  BCP response from a Reader agent back to a Controller agent's runtime.
  """
  @spec send_bcp_response_delivery(
          GenServer.server(),
          String.t() | nil,
          integer(),
          String.t(),
          map(),
          float(),
          keyword()
        ) :: :ok
  def send_bcp_response_delivery(server, query_id, category, from_agent, response, bandwidth_bits, opts \\ []) do
    subscription_id = Keyword.get(opts, :subscription_id)

    msg = %{
      "type" => "bcp_response_delivery",
      "category" => category,
      "from_agent" => from_agent,
      "response" => response,
      "bandwidth_bits" => bandwidth_bits
    }

    msg = if query_id, do: Map.put(msg, "query_id", query_id), else: msg
    msg = if subscription_id, do: Map.put(msg, "subscription_id", subscription_id), else: msg
    GenServer.cast(server, {:send, msg})
  end

  @doc """
  Sends a `bcp_subscriptions_active` message to the runtime, informing the Reader
  agent of all active BCP subscriptions targeting it.
  """
  @spec send_bcp_subscriptions_active(GenServer.server(), [TriOnyx.BCP.Subscription.t()]) :: :ok
  def send_bcp_subscriptions_active(server, subscriptions) do
    subs_json =
      Enum.map(subscriptions, fn sub ->
        base = %{
          "subscription_id" => sub.id,
          "controller" => sub.controller,
          "category" => sub.category
        }

        base = if sub.fields, do: Map.put(base, "fields", sub.fields), else: base
        base = if sub.questions, do: Map.put(base, "questions", sub.questions), else: base
        base = if sub.directive, do: Map.put(base, "directive", sub.directive), else: base
        base = if sub.max_words, do: Map.put(base, "max_words", sub.max_words), else: base
        base
      end)

    GenServer.cast(
      server,
      {:send, %{"type" => "bcp_subscriptions_active", "subscriptions" => subs_json}}
    )
  end

  @doc """
  Sends a `send_email_response` back to the runtime.
  """
  @spec send_send_email_response(GenServer.server(), String.t(), boolean(), String.t(), String.t()) ::
          :ok
  def send_send_email_response(server, request_id, success, detail \\ "", message_id \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "send_email_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail,
         "message_id" => message_id
       }}
    )
  end

  @doc """
  Sends a `move_email_response` back to the runtime.
  """
  @spec send_move_email_response(GenServer.server(), String.t(), boolean(), String.t()) :: :ok
  def send_move_email_response(server, request_id, success, detail \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "move_email_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail
       }}
    )
  end

  @doc """
  Sends a `create_folder_response` back to the runtime.
  """
  @spec send_create_folder_response(GenServer.server(), String.t(), boolean(), String.t()) :: :ok
  def send_create_folder_response(server, request_id, success, detail \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "create_folder_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail
       }}
    )
  end

  @doc """
  Sends a `restart_agent_response` back to the runtime with the result.
  """
  @spec send_restart_agent_response(GenServer.server(), String.t(), boolean(), String.t()) :: :ok
  def send_restart_agent_response(server, request_id, success, detail \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "restart_agent_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail
       }}
    )
  end

  @doc """
  Sends a `calendar_query_response` back to the runtime.
  """
  @spec send_calendar_query_response(GenServer.server(), String.t(), boolean(), String.t(), [map()]) :: :ok
  def send_calendar_query_response(server, request_id, success, detail \\ "", events \\ []) do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "calendar_query_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail,
         "events" => events
       }}
    )
  end

  @doc """
  Sends a `calendar_create_response` back to the runtime.
  """
  @spec send_calendar_create_response(GenServer.server(), String.t(), boolean(), String.t(), map()) :: :ok
  def send_calendar_create_response(server, request_id, success, detail \\ "", event \\ %{}) do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "calendar_create_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail,
         "event" => event
       }}
    )
  end

  @doc """
  Sends a `calendar_update_response` back to the runtime.
  """
  @spec send_calendar_update_response(GenServer.server(), String.t(), boolean(), String.t(), map()) :: :ok
  def send_calendar_update_response(server, request_id, success, detail \\ "", event \\ %{}) do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "calendar_update_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail,
         "event" => event
       }}
    )
  end

  @doc """
  Sends a `submit_item_response` back to the runtime.
  """
  @spec send_submit_item_response(GenServer.server(), String.t(), boolean(), String.t()) :: :ok
  def send_submit_item_response(server, request_id, success, detail \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "submit_item_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail
       }}
    )
  end

  @doc """
  Sends a `calendar_delete_response` back to the runtime.
  """
  @spec send_calendar_delete_response(GenServer.server(), String.t(), boolean(), String.t()) :: :ok
  def send_calendar_delete_response(server, request_id, success, detail \\ "") do
    GenServer.cast(
      server,
      {:send,
       %{
         "type" => "calendar_delete_response",
         "request_id" => request_id,
         "success" => success,
         "detail" => detail
       }}
    )
  end

  @doc """
  Stops the AgentPort, terminating the subprocess.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    notify = Keyword.fetch!(opts, :notify)

    case Keyword.get(opts, :definition) do
      %AgentDefinition{} = definition ->
        init_docker(notify, definition, opts)

      nil ->
        init_legacy(notify, opts)
    end
  end

  @impl GenServer
  def handle_cast({:send, message}, %{port: port} = state) when is_map(message) do
    json_line = Jason.encode!(message) <> "\n"
    Port.command(port, json_line)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port, buffer: buffer} = state) do
    # Accumulate data and process complete lines
    new_buffer = buffer <> data
    {lines, remaining} = split_lines(new_buffer)

    Enum.each(lines, fn line ->
      line = String.trim(line)

      if line != "" do
        case parse_event(line) do
          {:ok, event} ->
            send(state.notify, {:agent_event, self(), event})

          :skip ->
            :ok

          {:error, reason} ->
            Logger.warning("AgentPort: failed to parse message: #{inspect(reason)}, raw: #{line}")
        end
      end
    end)

    {:noreply, %{state | buffer: remaining}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.info("AgentPort: subprocess exited with status #{status}")
    send(state.notify, {:agent_event, self(), {:port_down, exit_reason(status)}})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info(msg, state) do
    Logger.warning("AgentPort: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{port: port, container_name: container_name})
      when is_port(port) and is_binary(container_name) do
    Logger.info("AgentPort: terminating Docker container #{container_name}")

    # Try graceful shutdown via stdin first
    try do
      Port.command(
        port,
        Jason.encode!(%{"type" => "shutdown", "reason" => "port terminating"}) <> "\n"
      )
    catch
      _, _ -> :ok
    end

    Port.close(port)

    # Fallback: force-stop the Docker container
    docker_stop(container_name)
    :ok
  end

  def terminate(_reason, %{port: port}) when is_port(port) do
    Logger.info("AgentPort: terminating, closing port")

    # Try graceful shutdown first
    try do
      Port.command(
        port,
        Jason.encode!(%{"type" => "shutdown", "reason" => "port terminating"}) <> "\n"
      )
    catch
      _, _ -> :ok
    end

    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Initialization Helpers ---

  @spec init_docker(pid(), AgentDefinition.t(), keyword()) ::
          {:ok, %__MODULE__{}} | {:stop, term()}
  defp init_docker(notify, definition, opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    # The gateway runs inside a container where the host repo is mounted at
    # /app. Docker bind mounts are resolved on the host, so we must translate
    # the container-local workspace path to its host equivalent.
    host_workspace = resolve_host_path(workspace_dir)

    sandbox_opts =
      opts
      |> Keyword.take([:image])
      |> Keyword.put(:workspace_dir, host_workspace)

    docker_args = Sandbox.build_docker_args(definition, session_id, sandbox_opts)
    container_name = "tri-onyx-#{definition.name}-#{session_id}"

    port =
      Port.open({:spawn_executable, find_docker()}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: docker_args
      ])

    Logger.info(
      "AgentPort started in Docker mode " <>
        "(port=#{inspect(port)}, container=#{container_name})"
    )

    {:ok, %__MODULE__{port: port, notify: notify, buffer: "", container_name: container_name}}
  end

  @spec init_legacy(pid(), keyword()) :: {:ok, %__MODULE__{}}
  defp init_legacy(notify, opts) do
    runtime_path = Keyword.get(opts, :runtime_path, @default_runtime_path)

    port =
      Port.open({:spawn_executable, find_uv()}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["run", "--script", runtime_path],
        env: build_env()
      ])

    Logger.info("AgentPort started in legacy mode (port=#{inspect(port)}, runtime=#{runtime_path})")

    {:ok, %__MODULE__{port: port, notify: notify, buffer: "", container_name: nil}}
  end

  # --- Private Helpers ---

  @spec split_lines(String.t()) :: {[String.t()], String.t()}
  defp split_lines(data) do
    case String.split(data, "\n", parts: :infinity) do
      [] ->
        {[], ""}

      parts ->
        {complete, [remaining]} = Enum.split(parts, -1)
        {complete, remaining}
    end
  end

  @spec parse_event(String.t()) :: {:ok, event()} | :skip | {:error, term()}
  defp parse_event(json_line) do
    case Jason.decode(json_line) do
      {:ok, %{"type" => "ready"}} ->
        {:ok, {:ready}}

      {:ok, %{"type" => "interrupted", "reason" => reason}} ->
        {:ok, {:interrupted, reason}}

      {:ok, %{"type" => "text", "content" => content}} ->
        {:ok, {:text, content}}

      {:ok, %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}} ->
        {:ok, {:tool_use, id, name, input}}

      {:ok,
       %{
         "type" => "tool_result",
         "tool_use_id" => id,
         "content" => content,
         "is_error" => is_error
       }} ->
        {:ok, {:tool_result, id, content, is_error == true}}

      {:ok, %{"type" => "result"} = result} ->
        {:ok,
         {:result,
          %{
            duration_ms: Map.get(result, "duration_ms", 0),
            num_turns: Map.get(result, "num_turns", 0),
            cost_usd: Map.get(result, "cost_usd", 0.0),
            is_error: Map.get(result, "is_error", false)
          }}}

      {:ok, %{"type" => "error", "message" => message}} ->
        {:ok, {:error, message}}

      {:ok,
       %{
         "type" => "send_message_request",
         "request_id" => req_id,
         "to" => to,
         "message_type" => msg_type,
         "payload" => payload
       }}
      when is_binary(req_id) and is_binary(to) and is_binary(msg_type) and is_map(payload) ->
        {:ok, {:send_message_request, req_id, to, msg_type, payload}}

      {:ok,
       %{
         "type" => "bcp_query_request",
         "request_id" => req_id,
         "to" => to,
         "category" => category,
         "spec" => spec
       }}
      when is_binary(req_id) and is_binary(to) and is_integer(category) and is_map(spec) ->
        {:ok, {:bcp_query_request, req_id, to, category, spec}}

      {:ok,
       %{
         "type" => "bcp_response",
         "subscription_id" => sub_id,
         "controller" => controller,
         "response" => response
       }}
      when is_binary(sub_id) and is_binary(controller) and is_map(response) ->
        {:ok, {:bcp_subscription_publish, sub_id, controller, response}}

      {:ok,
       %{
         "type" => "bcp_response",
         "query_id" => query_id,
         "response" => response
       }}
      when is_binary(query_id) and is_map(response) ->
        {:ok, {:bcp_response, query_id, response}}

      {:ok,
       %{
         "type" => "send_email_request",
         "request_id" => req_id,
         "draft_path" => draft_path
       }}
      when is_binary(req_id) and is_binary(draft_path) ->
        {:ok, {:send_email_request, req_id, draft_path}}

      {:ok,
       %{
         "type" => "move_email_request",
         "request_id" => req_id,
         "uid" => uid,
         "source_folder" => source_folder,
         "dest_folder" => dest_folder
       }}
      when is_binary(req_id) and is_binary(uid) and is_binary(source_folder) and
             is_binary(dest_folder) ->
        {:ok, {:move_email_request, req_id, uid, source_folder, dest_folder}}

      {:ok,
       %{
         "type" => "create_folder_request",
         "request_id" => req_id,
         "folder_name" => folder_name
       }}
      when is_binary(req_id) and is_binary(folder_name) ->
        {:ok, {:create_folder_request, req_id, folder_name}}

      {:ok,
       %{
         "type" => "restart_agent_request",
         "request_id" => req_id,
         "agent_name" => name,
         "force" => force
       }}
      when is_binary(req_id) and is_binary(name) and is_boolean(force) ->
        {:ok, {:restart_agent_request, req_id, name, force}}

      {:ok,
       %{
         "type" => "calendar_query_request",
         "request_id" => req_id,
         "params" => params
       }}
      when is_binary(req_id) and is_map(params) ->
        {:ok, {:calendar_query_request, req_id, params}}

      {:ok,
       %{
         "type" => "calendar_create_request",
         "request_id" => req_id,
         "draft_path" => draft_path
       }}
      when is_binary(req_id) and is_binary(draft_path) ->
        {:ok, {:calendar_create_request, req_id, draft_path}}

      {:ok,
       %{
         "type" => "calendar_update_request",
         "request_id" => req_id,
         "draft_path" => draft_path
       }}
      when is_binary(req_id) and is_binary(draft_path) ->
        {:ok, {:calendar_update_request, req_id, draft_path}}

      {:ok,
       %{
         "type" => "calendar_delete_request",
         "request_id" => req_id,
         "uid" => uid,
         "calendar" => calendar
       }}
      when is_binary(req_id) and is_binary(uid) and is_binary(calendar) ->
        {:ok, {:calendar_delete_request, req_id, uid, calendar}}

      {:ok,
       %{
         "type" => "submit_item_request",
         "request_id" => req_id,
         "item_type" => item_type,
         "title" => title,
         "url" => url
       } = payload}
      when is_binary(req_id) and is_binary(item_type) and is_binary(title) and
             is_binary(url) ->
        metadata = Map.get(payload, "metadata", %{})
        {:ok, {:submit_item_request, req_id, item_type, title, url, metadata}}

      {:ok, %{"type" => "log", "level" => level, "message" => message}}
      when is_binary(level) and is_binary(message) ->
        {:ok, {:log, level, message}}

      # FUSE filesystem events use "event" key instead of "type"
      {:ok, %{"event" => "write", "op" => op, "path" => path}} ->
        {:ok, {:fuse_write, op, path}}

      {:ok, %{"event" => _}} ->
        :skip

      {:ok, %{"type" => type}} ->
        Logger.warning("AgentPort: unknown message type: #{inspect(type)}")
        {:error, {:unknown_type, type}}

      {:ok, _other} ->
        {:error, :missing_type_field}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  @spec find_docker() :: charlist()
  defp find_docker do
    case System.find_executable("docker") do
      nil -> raise "docker executable not found in PATH"
      path -> String.to_charlist(path)
    end
  end

  @spec find_uv() :: charlist()
  defp find_uv do
    case System.find_executable("uv") do
      nil -> raise "uv executable not found in PATH"
      path -> String.to_charlist(path)
    end
  end

  @spec build_env() :: [{charlist(), charlist()}]
  defp build_env do
    # Pass through ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN if set
    env_vars = ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]

    env_vars
    |> Enum.filter(&System.get_env/1)
    |> Enum.map(fn key ->
      {String.to_charlist(key), String.to_charlist(System.get_env(key))}
    end)
  end

  @spec docker_stop(String.t()) :: :ok
  defp docker_stop(container_name) do
    Logger.info("AgentPort: issuing docker stop #{container_name}")

    # Fire-and-forget docker stop with a short timeout
    # Using System.cmd in a spawned process to avoid blocking terminate
    spawn(fn ->
      try do
        System.cmd("docker", ["stop", "--time", "5", container_name], stderr_to_stdout: true)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  @spec exit_reason(non_neg_integer()) :: atom()
  defp exit_reason(0), do: :normal
  defp exit_reason(_status), do: :abnormal

  # Translates a container-local path to the equivalent host path.
  # The gateway runs inside a container with the host repo mounted at /app.
  # Docker bind mounts are resolved by the host daemon, so we need the real
  # host path. Uses TRI_ONYX_HOST_ROOT if set, otherwise returns the path
  # as-is (for local development without containerized gateway).
  @spec resolve_host_path(String.t()) :: String.t()
  defp resolve_host_path(path) do
    abs_path = Path.expand(path)

    case System.get_env("TRI_ONYX_HOST_ROOT") do
      nil ->
        abs_path

      host_root ->
        # Strip the container mount prefix (/app) and prepend the host root
        case String.trim_trailing(abs_path, "/") do
          "/app" <> rest -> Path.join(host_root, rest)
          _ -> abs_path
        end
    end
  end
end
