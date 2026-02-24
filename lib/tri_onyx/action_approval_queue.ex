defmodule TriOnyx.ActionApprovalQueue do
  @moduledoc """
  GenServer for action approval queue.

  Holds pending approval items for gateway-mediated tools (e.g., SendEmail)
  that require human sign-off before execution. Operators interact with the
  queue through the HTTP API or connector reactions (👍/👎).

  The `await_decision/3` function allows a caller to block (with timeout)
  until a decision is made — agents cannot bypass the approval step.
  """

  use GenServer

  require Logger

  @type approval_id :: String.t()

  @type pending_item :: %{
          id: approval_id(),
          agent_name: String.t(),
          session_id: String.t(),
          tool_name: String.t(),
          tool_input: map(),
          submitted_at: DateTime.t()
        }

  @type decided_item :: %{
          item: pending_item(),
          decision: :approved | :rejected,
          reason: String.t() | nil,
          decided_at: DateTime.t()
        }

  @type state :: %{
          pending: %{approval_id() => pending_item()},
          decided: %{approval_id() => decided_item()},
          waiters: %{approval_id() => [GenServer.from()]}
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  Submits a tool action for human approval. Returns `{:ok, approval_id}`.
  """
  @spec submit(GenServer.server(), map()) :: {:ok, approval_id()}
  def submit(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:submit, attrs})
  end

  @doc """
  Approves a pending action. Returns `{:ok, item}` or `{:error, :not_found}`.
  """
  @spec approve(GenServer.server(), approval_id()) :: {:ok, pending_item()} | {:error, :not_found}
  def approve(server \\ __MODULE__, approval_id) do
    GenServer.call(server, {:approve, approval_id})
  end

  @doc """
  Rejects a pending action with a reason. Returns `{:ok, item}` or `{:error, :not_found}`.
  """
  @spec reject(GenServer.server(), approval_id(), String.t()) ::
          {:ok, pending_item()} | {:error, :not_found}
  def reject(server \\ __MODULE__, approval_id, reason) do
    GenServer.call(server, {:reject, approval_id, reason})
  end

  @doc """
  Lists all pending approval items.
  """
  @spec list_pending(GenServer.server()) :: [pending_item()]
  def list_pending(server \\ __MODULE__) do
    GenServer.call(server, :list_pending)
  end

  @doc """
  Blocks until the given approval_id is approved or rejected, or until timeout.

  Returns `{:approved, item}`, `{:rejected, reason}`, or `{:error, :timeout}`.
  """
  @spec await_decision(GenServer.server(), approval_id(), timeout()) ::
          {:approved, pending_item()} | {:rejected, String.t()} | {:error, :timeout | :not_found}
  def await_decision(server \\ __MODULE__, approval_id, timeout \\ 300_000) do
    GenServer.call(server, {:await_decision, approval_id}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # --- Server Callbacks ---

  @impl true
  def init(:ok) do
    {:ok, %{pending: %{}, decided: %{}, waiters: %{}}}
  end

  @impl true
  def handle_call({:submit, attrs}, _from, state) do
    id = generate_id()

    item = %{
      id: id,
      agent_name: Map.get(attrs, :agent_name, ""),
      session_id: Map.get(attrs, :session_id, ""),
      tool_name: Map.get(attrs, :tool_name, ""),
      tool_input: Map.get(attrs, :tool_input, %{}),
      submitted_at: DateTime.utc_now()
    }

    Logger.info(
      "Action approval submitted: #{id} agent=#{item.agent_name} tool=#{item.tool_name}"
    )

    new_state = put_in(state, [:pending, id], item)
    {:reply, {:ok, id}, new_state}
  end

  def handle_call({:approve, approval_id}, _from, state) do
    case Map.pop(state.pending, approval_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {item, remaining_pending} ->
        decided = %{
          item: item,
          decision: :approved,
          reason: nil,
          decided_at: DateTime.utc_now()
        }

        Logger.info("Action approval approved: #{approval_id}")

        state = %{state | pending: remaining_pending}
        state = put_in(state, [:decided, approval_id], decided)
        state = notify_waiters(state, approval_id, {:approved, item})

        {:reply, {:ok, item}, state}
    end
  end

  def handle_call({:reject, approval_id, reason}, _from, state) do
    case Map.pop(state.pending, approval_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {item, remaining_pending} ->
        decided = %{
          item: item,
          decision: :rejected,
          reason: reason,
          decided_at: DateTime.utc_now()
        }

        Logger.info("Action approval rejected: #{approval_id} reason=#{reason}")

        state = %{state | pending: remaining_pending}
        state = put_in(state, [:decided, approval_id], decided)
        state = notify_waiters(state, approval_id, {:rejected, reason})

        {:reply, {:ok, item}, state}
    end
  end

  def handle_call(:list_pending, _from, state) do
    items = Map.values(state.pending)
    {:reply, items, state}
  end

  def handle_call({:await_decision, approval_id}, from, state) do
    case Map.get(state.decided, approval_id) do
      %{decision: :approved, item: item} ->
        {:reply, {:approved, item}, state}

      %{decision: :rejected, reason: reason} ->
        {:reply, {:rejected, reason}, state}

      nil ->
        if Map.has_key?(state.pending, approval_id) do
          waiters = Map.get(state.waiters, approval_id, [])
          state = put_in(state, [:waiters, approval_id], [from | waiters])
          {:noreply, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  def handle_call(msg, _from, state) do
    Logger.warning("ActionApprovalQueue received unrecognized call: #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("ActionApprovalQueue received unrecognized message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private Helpers ---

  @spec notify_waiters(state(), approval_id(), term()) :: state()
  defp notify_waiters(state, approval_id, reply) do
    case Map.pop(state.waiters, approval_id) do
      {nil, _} ->
        state

      {waiters, remaining} ->
        Enum.each(waiters, fn from ->
          GenServer.reply(from, reply)
        end)

        %{state | waiters: remaining}
    end
  end

  defp generate_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, d, e]
    )
    |> to_string()
    |> String.downcase()
  end
end
