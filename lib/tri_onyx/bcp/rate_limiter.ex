defmodule TriOnyx.BCP.RateLimiter do
  @moduledoc """
  ETS-based fixed-window rate limiter for BCP channels.

  Tracks request counts per `{from_agent, to_agent, category}` triple using
  a fixed time window. Each bucket stores the count and the window start
  timestamp.

  ## Design

  Uses a single ETS table with composite keys. When a query arrives:

  1. Look up `{from_agent, to_agent, category}` in ETS
  2. If the current window has expired, reset the counter
  3. If the counter is below the limit, increment and allow
  4. Otherwise, reject with rate limit info

  This is a GenServer only for ownership of the ETS table and periodic
  cleanup. The hot-path `check_rate/5` reads and updates ETS directly
  using `:ets.update_counter/4` for atomicity.
  """

  use GenServer

  require Logger

  @ets_table :bcp_rate_limits
  @cleanup_interval_ms 300_000

  # --- Public API ---

  @doc """
  Starts the BCP RateLimiter GenServer.

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
  Checks whether a BCP query is within the rate limit for its category.

  Returns `:ok` if allowed, or `{:error, :rate_limited, retry_after_seconds}`
  if the limit is exceeded.

  ## Parameters

  - `from_agent` — the controller agent name
  - `to_agent` — the reader agent name
  - `category` — the BCP category (1, 2, or 3)
  - `limit` — max requests per window
  - `window_ms` — window duration in milliseconds
  - `table` — ETS table name (default: `:bcp_rate_limits`)
  """
  @spec check_rate(String.t(), String.t(), 1 | 2 | 3, pos_integer(), pos_integer(), atom()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check_rate(from_agent, to_agent, category, limit, window_ms, table \\ @ets_table) do
    key = {from_agent, to_agent, category}
    now = System.system_time(:millisecond)
    window_start_cutoff = now - window_ms

    case :ets.lookup(table, key) do
      [{^key, count, bucket_start}] when bucket_start > window_start_cutoff ->
        if count < limit do
          :ets.update_counter(table, key, {2, 1})
          :ok
        else
          retry_after_ms = window_ms - (now - bucket_start)
          retry_after_s = max(div(retry_after_ms, 1000), 1)
          {:error, :rate_limited, retry_after_s}
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

    Logger.info("BCP.RateLimiter started")
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_expired(state.table)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("BCP.RateLimiter: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  @spec cleanup_expired(atom()) :: :ok
  defp cleanup_expired(table) do
    # Use a generous cutoff — delete entries older than 1 hour
    cutoff = System.system_time(:millisecond) - 3_600_000

    # match spec: [{key, count, bucket_start}] where bucket_start < cutoff
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]

    deleted = :ets.select_delete(table, match_spec)

    if deleted > 0 do
      Logger.debug("BCP.RateLimiter: cleaned up #{deleted} expired bucket(s)")
    end

    :ok
  end
end
