defmodule TriOnyx.WebhookRateLimiter do
  @moduledoc """
  ETS-based token bucket rate limiter for webhook endpoints.

  Tracks request counts per `{endpoint_id, source_ip}` pair using a
  sliding window approximation. Each bucket stores the count and the
  window start timestamp.

  ## Design

  Uses a single ETS table with composite keys. When a request arrives:

  1. Look up `{endpoint_id, source_ip}` in ETS
  2. If the current window has expired, reset the counter
  3. If the counter is below the limit, increment and allow
  4. Otherwise, reject with rate limit info

  This is a GenServer only for ownership of the ETS table and periodic
  cleanup. The hot-path `check_rate/3` reads and updates ETS directly
  using `:ets.update_counter/4` for atomicity.
  """

  use GenServer

  require Logger

  @ets_table :webhook_rate_limits
  @window_seconds 60
  @cleanup_interval_ms 300_000

  # --- Public API ---

  @doc """
  Starts the WebhookRateLimiter GenServer.

  ## Options

  - `:name` — GenServer registration name (default: `__MODULE__`)
  - `:ets_table` — override the ETS table name (for testing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Checks whether the request is within the rate limit.

  Returns `:ok` if allowed, or `{:error, :rate_limited, retry_after_seconds}`
  if the limit is exceeded.

  ## Parameters

  - `endpoint_id` — the webhook endpoint ID
  - `source_ip` — the source IP address string
  - `limit` — max requests per minute for this endpoint
  - `table` — ETS table name (default: `:webhook_rate_limits`)
  """
  @spec check_rate(String.t(), String.t(), pos_integer(), atom()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check_rate(endpoint_id, source_ip, limit, table \\ @ets_table) do
    key = {endpoint_id, source_ip}
    now = System.system_time(:second)
    window_start = now - @window_seconds

    case :ets.lookup(table, key) do
      [{^key, count, bucket_start}] when bucket_start > window_start ->
        if count < limit do
          :ets.update_counter(table, key, {2, 1})
          :ok
        else
          retry_after = @window_seconds - (now - bucket_start)
          {:error, :rate_limited, max(retry_after, 1)}
        end

      _ ->
        # Window expired or no entry — start fresh
        :ets.insert(table, {key, 1, now})
        :ok
    end
  rescue
    ArgumentError ->
      # ETS table doesn't exist (e.g., rate limiter not started)
      :ok
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
        write_concurrency: true
      ])

    schedule_cleanup()

    Logger.info("WebhookRateLimiter started")
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_expired(state.table)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("WebhookRateLimiter: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  @spec cleanup_expired(atom()) :: :ok
  defp cleanup_expired(table) do
    cutoff = System.system_time(:second) - @window_seconds

    # Delete all entries where the bucket_start is before the cutoff.
    # match spec: [{key, count, bucket_start}] where bucket_start < cutoff
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]

    deleted = :ets.select_delete(table, match_spec)

    if deleted > 0 do
      Logger.debug("WebhookRateLimiter: cleaned up #{deleted} expired bucket(s)")
    end

    :ok
  end
end
