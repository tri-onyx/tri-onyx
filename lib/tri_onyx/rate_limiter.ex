defmodule TriOnyx.RateLimiter do
  @moduledoc """
  Shared ETS-based fixed-window rate limiter core.

  Tracks request counts per caller-defined composite key using a fixed
  time window. Each bucket stores the count and the window start
  timestamp (milliseconds).

  ## Design

  Uses a single ETS table per limiter instance. When a request arrives:

  1. Look up the key in ETS
  2. If the current window has expired, reset the counter
  3. If the counter is below the limit, increment and allow
  4. Otherwise, reject with rate limit info

  The GenServer exists only for ownership of the ETS table and periodic
  cleanup. The hot-path `check_rate/4` reads and updates ETS directly
  using `:ets.update_counter/4` for atomicity.

  Domain-specific limiters (`TriOnyx.WebhookRateLimiter`,
  `TriOnyx.BCP.RateLimiter`) wrap this module with their key shape and
  cleanup policy.
  """

  use GenServer

  require Logger

  @cleanup_interval_ms 300_000

  # --- Public API ---

  @doc """
  Starts a rate limiter GenServer.

  ## Options

  - `:name` — GenServer registration name (required)
  - `:ets_table` — the ETS table name (required)
  - `:label` — log prefix (default: `"RateLimiter"`)
  - `:max_age_ms` — entries older than this are removed by periodic cleanup (required)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Checks whether a request is within the rate limit.

  Returns `:ok` if allowed, or `{:error, :rate_limited, retry_after_seconds}`
  if the limit is exceeded. Allows everything if the table doesn't exist
  (limiter not started).
  """
  @spec check_rate(atom(), term(), pos_integer(), pos_integer()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  def check_rate(table, key, limit, window_ms) do
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
    table_name = Keyword.fetch!(opts, :ets_table)
    label = Keyword.get(opts, :label, "RateLimiter")
    max_age_ms = Keyword.fetch!(opts, :max_age_ms)

    table =
      :ets.new(table_name, [
        :set,
        :named_table,
        :public,
        write_concurrency: true
      ])

    schedule_cleanup()

    Logger.info("#{label} started")
    {:ok, %{table: table, label: label, max_age_ms: max_age_ms}}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    cleanup_expired(state)
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("#{state.label}: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # --- Private ---

  @spec schedule_cleanup() :: reference()
  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  @spec cleanup_expired(map()) :: :ok
  defp cleanup_expired(%{table: table, label: label, max_age_ms: max_age_ms}) do
    cutoff = System.system_time(:millisecond) - max_age_ms

    # match spec: [{key, count, bucket_start}] where bucket_start < cutoff
    match_spec = [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]

    deleted = :ets.select_delete(table, match_spec)

    if deleted > 0 do
      Logger.debug("#{label}: cleaned up #{deleted} expired bucket(s)")
    end

    :ok
  end
end
