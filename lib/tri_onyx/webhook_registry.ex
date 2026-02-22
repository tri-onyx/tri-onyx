defmodule TriOnyx.WebhookRegistry do
  @moduledoc """
  GenServer that manages webhook endpoint configurations.

  Stores endpoints in an ETS table for fast concurrent reads on the hot
  path (incoming webhook requests), and persists them to a JSON file for
  durability across restarts.

  ## Storage

  - ETS table: `:webhook_endpoints` (`:set`, `read_concurrency: true`)
  - Disk: `~/.tri-onyx/webhooks.json` (configurable via `:tri_onyx, :webhooks_file`)

  ## Hot Path

  `lookup/1` reads directly from ETS — no GenServer call. This is critical
  because every incoming webhook request needs to look up the endpoint
  configuration, and we don't want the GenServer to be a bottleneck.

  ## Mutations

  All mutations (create, update, delete, rotate) go through the GenServer
  to serialize writes and ensure consistency between ETS and disk.
  """

  use GenServer

  require Logger

  alias TriOnyx.WebhookEndpoint

  @ets_table :webhook_endpoints

  # --- Public API ---

  @doc """
  Starts the WebhookRegistry GenServer.

  ## Options

  - `:name` — GenServer registration name (default: `__MODULE__`)
  - `:webhooks_file` — override the configured file path
  - `:ets_table` — override the ETS table name (for testing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Looks up a webhook endpoint by ID. Reads directly from ETS (no GenServer call).

  Returns `{:ok, endpoint}` or `:error`.
  """
  @spec lookup(String.t(), atom()) :: {:ok, WebhookEndpoint.t()} | :error
  def lookup(endpoint_id, table \\ @ets_table) do
    case :ets.lookup(table, endpoint_id) do
      [{^endpoint_id, endpoint}] -> {:ok, endpoint}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc """
  Lists all webhook endpoints.
  """
  @spec list(GenServer.server()) :: [WebhookEndpoint.t()]
  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  Creates a new webhook endpoint. Returns `{:ok, endpoint}` with the
  generated ID and signing secret, or `{:error, reason}`.
  """
  @spec create(GenServer.server(), map()) :: {:ok, WebhookEndpoint.t()} | {:error, term()}
  def create(server \\ __MODULE__, params) do
    GenServer.call(server, {:create, params})
  end

  @doc """
  Updates an existing webhook endpoint. Only `label`, `agents`, `enabled`,
  `rate_limit`, and `allowed_ips` can be updated. Returns `{:ok, endpoint}`
  or `{:error, reason}`.
  """
  @spec update(GenServer.server(), String.t(), map()) ::
          {:ok, WebhookEndpoint.t()} | {:error, term()}
  def update(server \\ __MODULE__, endpoint_id, params) do
    GenServer.call(server, {:update, endpoint_id, params})
  end

  @doc """
  Deletes a webhook endpoint by ID.
  """
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def delete(server \\ __MODULE__, endpoint_id) do
    GenServer.call(server, {:delete, endpoint_id})
  end

  @doc """
  Rotates the signing secret for the given endpoint. The old secret
  remains valid for 1 hour. Returns `{:ok, endpoint}` with the new
  secret, or `{:error, reason}`.
  """
  @spec rotate_secret(GenServer.server(), String.t()) ::
          {:ok, WebhookEndpoint.t()} | {:error, term()}
  def rotate_secret(server \\ __MODULE__, endpoint_id) do
    GenServer.call(server, {:rotate_secret, endpoint_id})
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :ets_table, @ets_table)

    table =
      :ets.new(table_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    webhooks_file =
      Keyword.get(opts, :webhooks_file) ||
        Application.get_env(:tri_onyx, :webhooks_file, "~/.tri-onyx/webhooks.json")

    webhooks_file = Path.expand(webhooks_file)

    state = %{
      table: table,
      webhooks_file: webhooks_file
    }

    load_from_disk(state)

    count = :ets.info(table, :size)
    Logger.info("WebhookRegistry started with #{count} endpoint(s)")

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:list, _from, state) do
    endpoints =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, endpoint} -> endpoint end)
      |> Enum.sort_by(& &1.created_at, {:asc, DateTime})

    {:reply, endpoints, state}
  end

  def handle_call({:create, params}, _from, state) do
    case WebhookEndpoint.new(params) do
      {:ok, endpoint} ->
        :ets.insert(state.table, {endpoint.id, endpoint})
        persist_to_disk(state)
        Logger.info("WebhookRegistry: created endpoint '#{endpoint.label}' (#{endpoint.id})")
        {:reply, {:ok, endpoint}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:update, endpoint_id, params}, _from, state) do
    case :ets.lookup(state.table, endpoint_id) do
      [{^endpoint_id, existing}] ->
        updated = apply_updates(existing, params)
        :ets.insert(state.table, {endpoint_id, updated})
        persist_to_disk(state)
        Logger.info("WebhookRegistry: updated endpoint #{endpoint_id}")
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, endpoint_id}, _from, state) do
    case :ets.lookup(state.table, endpoint_id) do
      [{^endpoint_id, _}] ->
        :ets.delete(state.table, endpoint_id)
        persist_to_disk(state)
        Logger.info("WebhookRegistry: deleted endpoint #{endpoint_id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:rotate_secret, endpoint_id}, _from, state) do
    case :ets.lookup(state.table, endpoint_id) do
      [{^endpoint_id, existing}] ->
        rotated = WebhookEndpoint.rotate_secret(existing)
        :ets.insert(state.table, {endpoint_id, rotated})
        persist_to_disk(state)
        Logger.info("WebhookRegistry: rotated secret for endpoint #{endpoint_id}")
        {:reply, {:ok, rotated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl GenServer
  def handle_info(msg, state) do
    Logger.warning("WebhookRegistry: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  @spec apply_updates(WebhookEndpoint.t(), map()) :: WebhookEndpoint.t()
  defp apply_updates(endpoint, params) do
    endpoint
    |> maybe_update_field(params, "label", :label, &is_binary/1)
    |> maybe_update_field(params, "agents", :agents, &valid_agent_list?/1)
    |> maybe_update_field(params, "enabled", :enabled, &is_boolean/1)
    |> maybe_update_field(params, "rate_limit", :rate_limit, &(is_integer(&1) and &1 > 0))
    |> maybe_update_allowed_ips(params)
  end

  @spec maybe_update_field(WebhookEndpoint.t(), map(), String.t(), atom(), (term() -> boolean())) ::
          WebhookEndpoint.t()
  defp maybe_update_field(endpoint, params, key, field, validator) do
    case Map.get(params, key) do
      nil -> endpoint
      value -> if validator.(value), do: Map.put(endpoint, field, value), else: endpoint
    end
  end

  @spec maybe_update_allowed_ips(WebhookEndpoint.t(), map()) :: WebhookEndpoint.t()
  defp maybe_update_allowed_ips(endpoint, params) do
    case Map.fetch(params, "allowed_ips") do
      {:ok, nil} -> %{endpoint | allowed_ips: nil}
      {:ok, ips} when is_list(ips) -> %{endpoint | allowed_ips: ips}
      _ -> endpoint
    end
  end

  @spec valid_agent_list?(term()) :: boolean()
  defp valid_agent_list?(agents) do
    is_list(agents) and length(agents) > 0 and
      Enum.all?(agents, &(is_binary(&1) and byte_size(&1) > 0))
  end

  @spec load_from_disk(map()) :: :ok
  defp load_from_disk(state) do
    case File.read(state.webhooks_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) ->
            Enum.each(list, fn map ->
              case WebhookEndpoint.from_map(map) do
                {:ok, endpoint} ->
                  :ets.insert(state.table, {endpoint.id, endpoint})

                {:error, reason} ->
                  Logger.warning(
                    "WebhookRegistry: skipping invalid endpoint: #{inspect(reason)}"
                  )
              end
            end)

          {:ok, _} ->
            Logger.warning("WebhookRegistry: webhooks file is not a JSON array")

          {:error, reason} ->
            Logger.warning("WebhookRegistry: failed to parse webhooks file: #{inspect(reason)}")
        end

      {:error, :enoent} ->
        Logger.debug("WebhookRegistry: no webhooks file found, starting empty")

      {:error, reason} ->
        Logger.warning("WebhookRegistry: failed to read webhooks file: #{inspect(reason)}")
    end

    :ok
  end

  @spec persist_to_disk(map()) :: :ok
  defp persist_to_disk(state) do
    endpoints =
      state.table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, endpoint} -> WebhookEndpoint.to_map(endpoint) end)

    dir = Path.dirname(state.webhooks_file)
    File.mkdir_p!(dir)

    # Write to a temp file first, then rename for atomicity
    tmp_file = state.webhooks_file <> ".tmp"

    case File.write(tmp_file, Jason.encode!(endpoints, pretty: true)) do
      :ok ->
        File.rename!(tmp_file, state.webhooks_file)

      {:error, reason} ->
        Logger.error("WebhookRegistry: failed to write webhooks file: #{inspect(reason)}")
        File.rm(tmp_file)
    end

    :ok
  end
end
