defmodule TriOnyx.AuditLog do
  @moduledoc """
  Append-only JSONL audit logger for the TriOnyx gateway.

  Records all security-relevant events: session lifecycle, tool calls, taint
  changes, inter-agent messages, and trigger events. Each entry is a single
  JSON line written to a daily log file.

  Log location is configurable via `:tri_onyx, :audit_dir` (defaults to
  `~/.tri-onyx/audit`). Files are named `YYYY-MM-DD.jsonl`.

  The AuditLog is a GenServer that serializes writes to ensure ordering and
  atomicity of log entries. It opens a new file handle when the date rolls over.
  """

  use GenServer

  require Logger

  @type event_type ::
          :session_start
          | :session_stop
          | :tool_call
          | :tool_result
          | :information_change
          | :inter_agent_message
          | :messaging_policy_rejection
          | :trigger
          | :bcp_query
          | :bcp_response
          | :bcp_validation
          | :bcp_escalation

  @type event :: %{atom() => term()}

  # --- Public API ---

  @doc """
  Starts the AuditLog GenServer.

  ## Options

  - `:name` — GenServer registration name (default: `TriOnyx.AuditLog`)
  - `:audit_dir` — override the configured audit directory
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Logs an agent session start event.
  """
  @spec log_session_start(GenServer.server(), String.t(), String.t(), map()) :: :ok
  def log_session_start(server \\ __MODULE__, session_id, agent_name, risk_info) do
    GenServer.cast(server, {:log, %{
      type: :session_start,
      session_id: session_id,
      agent_name: agent_name,
      input_risk: risk_info[:input_risk],
      effective_risk: risk_info[:effective_risk],
      information_level: risk_info[:information_level] || :low
    }})
  end

  @doc """
  Logs an agent session stop event.
  """
  @spec log_session_stop(GenServer.server(), String.t(), String.t(), map()) :: :ok
  def log_session_stop(server \\ __MODULE__, session_id, agent_name, summary) do
    GenServer.cast(server, {:log, %{
      type: :session_stop,
      session_id: session_id,
      agent_name: agent_name,
      information_level: summary[:information_level],
      effective_risk: summary[:effective_risk],
      reason: summary[:reason]
    }})
  end

  @doc """
  Logs a tool call event (agent requesting a tool).
  """
  @spec log_tool_call(GenServer.server(), String.t(), String.t(), String.t(), map()) :: :ok
  def log_tool_call(server \\ __MODULE__, session_id, tool_use_id, tool_name, input) do
    GenServer.cast(server, {:log, %{
      type: :tool_call,
      session_id: session_id,
      tool_use_id: tool_use_id,
      tool_name: tool_name,
      input: input
    }})
  end

  @doc """
  Logs a tool result event.
  """
  @spec log_tool_result(GenServer.server(), String.t(), String.t(), boolean()) :: :ok
  def log_tool_result(server \\ __MODULE__, session_id, tool_use_id, is_error) do
    GenServer.cast(server, {:log, %{
      type: :tool_result,
      session_id: session_id,
      tool_use_id: tool_use_id,
      is_error: is_error
    }})
  end

  @doc """
  Logs an information level change.
  """
  @spec log_information_change(GenServer.server(), String.t(), String.t(), atom(), atom(), String.t()) ::
          :ok
  def log_information_change(server \\ __MODULE__, session_id, agent_name, old_level, new_level, source) do
    GenServer.cast(server, {:log, %{
      type: :information_change,
      session_id: session_id,
      agent_name: agent_name,
      old_level: old_level,
      new_level: new_level,
      source: source
    }})
  end

  @doc """
  Logs an inter-agent message event.
  """
  @spec log_inter_agent_message(GenServer.server(), String.t(), String.t(), String.t(), boolean()) ::
          :ok
  def log_inter_agent_message(server \\ __MODULE__, from_session, to_agent, message_type, sanitized?) do
    GenServer.cast(server, {:log, %{
      type: :inter_agent_message,
      from_session: from_session,
      to_agent: to_agent,
      message_type: message_type,
      sanitized: sanitized?
    }})
  end

  @doc """
  Logs a messaging policy rejection event.
  """
  @spec log_messaging_policy_rejection(GenServer.server(), String.t(), String.t(), atom(), String.t()) ::
          :ok
  def log_messaging_policy_rejection(server \\ __MODULE__, from_agent, to_agent, reason, detail) do
    GenServer.cast(server, {:log, %{
      type: :messaging_policy_rejection,
      from_agent: from_agent,
      to_agent: to_agent,
      reason: reason,
      detail: detail
    }})
  end

  @doc """
  Logs a trigger event.
  """
  @spec log_trigger(GenServer.server(), atom(), String.t(), atom()) :: :ok
  def log_trigger(server \\ __MODULE__, trigger_type, agent_name, trust_level) do
    GenServer.cast(server, {:log, %{
      type: :trigger,
      trigger_type: trigger_type,
      agent_name: agent_name,
      trust_level: trust_level
    }})
  end

  @doc """
  Logs a human review event.
  """
  @spec log_human_review(GenServer.server(), String.t(), [String.t()]) :: :ok
  def log_human_review(server \\ __MODULE__, reviewer, paths) do
    GenServer.cast(server, {:log, %{
      type: :human_review,
      reviewer: reviewer,
      paths: paths
    }})
  end

  @doc """
  Logs a BCP query initiation event.
  """
  @spec log_bcp_query(GenServer.server(), String.t(), String.t(), atom(), map()) :: :ok
  def log_bcp_query(server \\ __MODULE__, from_agent, to_agent, category, query_spec) do
    GenServer.cast(server, {:log, %{
      type: :bcp_query,
      from_agent: from_agent,
      to_agent: to_agent,
      category: category,
      query_spec: query_spec
    }})
  end

  @doc """
  Logs a BCP validated response event.
  """
  @spec log_bcp_response(GenServer.server(), String.t(), term(), map()) :: :ok
  def log_bcp_response(server \\ __MODULE__, query_id, raw_response, validation_result) do
    GenServer.cast(server, {:log, %{
      type: :bcp_response,
      query_id: query_id,
      raw_response: raw_response,
      validation_result: validation_result,
      normalized_response: validation_result[:normalized_response]
    }})
  end

  @doc """
  Logs a BCP validation outcome event.
  """
  @spec log_bcp_validation(GenServer.server(), String.t(), atom(), map()) :: :ok
  def log_bcp_validation(server \\ __MODULE__, query_id, category, validation_details) do
    GenServer.cast(server, {:log, %{
      type: :bcp_validation,
      query_id: query_id,
      category: category,
      pass: validation_details[:pass],
      anomalies: validation_details[:anomalies],
      rate_count: validation_details[:rate_count]
    }})
  end

  @doc """
  Logs a BCP category escalation event.
  """
  @spec log_bcp_escalation(GenServer.server(), String.t(), String.t(), atom(), atom()) :: :ok
  def log_bcp_escalation(server \\ __MODULE__, from_agent, to_agent, old_category, new_category) do
    GenServer.cast(server, {:log, %{
      type: :bcp_escalation,
      from_agent: from_agent,
      to_agent: to_agent,
      old_category: old_category,
      new_category: new_category
    }})
  end

  @doc """
  Writes an arbitrary event map to the audit log.
  """
  @spec log_event(GenServer.server(), map()) :: :ok
  def log_event(server \\ __MODULE__, event) when is_map(event) do
    GenServer.cast(server, {:log, event})
  end

  @doc """
  Reads audit log entries from files on or after the given date.

  Returns a list of decoded JSON maps. This reads directly from disk
  (not via the GenServer) to avoid blocking the write path.
  """
  @spec read_entries(Date.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def read_entries(since_date, opts \\ []) do
    audit_dir =
      Keyword.get(opts, :audit_dir) ||
        Application.get_env(:tri_onyx, :audit_dir, "~/.tri-onyx/audit")

    audit_dir = Path.expand(audit_dir)

    if File.dir?(audit_dir) do
      entries =
        audit_dir
        |> Path.join("*.jsonl")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.filter(fn path ->
          filename = Path.basename(path, ".jsonl")

          case Date.from_iso8601(filename) do
            {:ok, file_date} -> Date.compare(file_date, since_date) != :lt
            _ -> false
          end
        end)
        |> Enum.flat_map(&read_jsonl_file/1)

      {:ok, entries}
    else
      {:ok, []}
    end
  end

  @spec read_jsonl_file(String.t()) :: [map()]
  defp read_jsonl_file(path) do
    path
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      line = String.trim(line)

      if line == "" do
        []
      else
        case Jason.decode(line) do
          {:ok, entry} -> [entry]
          {:error, _} -> []
        end
      end
    end)
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    audit_dir =
      Keyword.get(opts, :audit_dir) ||
        Application.get_env(:tri_onyx, :audit_dir, "~/.tri-onyx/audit")

    audit_dir = Path.expand(audit_dir)

    state = %{
      audit_dir: audit_dir,
      current_date: nil,
      file_handle: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:log, event}, state) do
    today = Date.utc_today()

    state =
      if state.current_date != today do
        rotate_file(state, today)
      else
        state
      end

    entry =
      event
      |> Map.put(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!()

    case state.file_handle do
      nil ->
        Logger.warning("AuditLog: no file handle, dropping event: #{inspect(event.type)}")
        {:noreply, state}

      handle ->
        IO.write(handle, entry <> "\n")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("AuditLog: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{file_handle: handle}) when handle != nil do
    File.close(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Private ---

  @spec rotate_file(map(), Date.t()) :: map()
  defp rotate_file(state, date) do
    # Close previous handle if open
    if state.file_handle, do: File.close(state.file_handle)

    File.mkdir_p!(state.audit_dir)
    filename = Date.to_iso8601(date) <> ".jsonl"
    path = Path.join(state.audit_dir, filename)

    case File.open(path, [:append, :utf8]) do
      {:ok, handle} ->
        Logger.debug("AuditLog: opened #{path}")
        %{state | current_date: date, file_handle: handle}

      {:error, reason} ->
        Logger.error("AuditLog: failed to open #{path}: #{inspect(reason)}")
        %{state | current_date: date, file_handle: nil}
    end
  end
end
