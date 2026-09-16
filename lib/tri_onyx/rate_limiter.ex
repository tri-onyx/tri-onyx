defmodule TriOnyx.RateLimiter do
  @moduledoc """
  Shared ETS-based fixed-window rate limiter core.

  Tracks request counts per caller-defined composite key using a fixed
  time window aligned to the epoch: a request at time `now` belongs to the
  window starting at `div(now, window_ms) * window_ms`. The bucket for a
  given `{key, window_start}` pair is a single counter.

  ## Design

  Uses a single ETS table per limiter instance. Each request atomically
  increments the counter for its `{key, window_start}` bucket — creating it
  at 0 first if absent — via a single `:ets.update_counter/4` call, and is
  allowed iff the returned count is within the limit.

  A previous version stored `{key, count, bucket_start}` and reset the
  bucket with a second, separate `:ets.insert/2` once `bucket_start` was
  found to be stale. That second write was not atomic with the read that
  decided to perform it: concurrent callers arriving just as a window
  expired could all read the same stale `bucket_start`, all decide to
  reset, and all write `count = 1` and return `:ok` — bypassing the limit
  entirely for an arbitrarily large burst timed at a window boundary.
  Keying the bucket by its window's start time instead removes the reset
  step (and the race) altogether: every caller in the same window
  increments the *same* ETS object, and `:ets.update_counter/4` (including
  its default-tuple creation) is atomic per object, so concurrent callers
  can never both observe the same pre-increment count and both be allowed
  past the limit.

  The GenServer exists only for ownership of the ETS table and periodic
  cleanup of past windows. The hot-path `check_rate/4` reads and updates
  ETS directly using `:ets.update_counter/4` for atomicity.

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
    window_start = div(now, window_ms) * window_ms
    bucket_key = {key, window_start}

    # A single atomic increment (creating the bucket at 0 first if absent)
    # per {key, window_start}. There is no separate reset step to race:
    # every caller in the same window shares one object, and
    # :ets.update_counter/4 — including the implicit default-tuple insert —
    # is atomic with respect to other operations on that object.
    count = :ets.update_counter(table, bucket_key, {2, 1}, {bucket_key, 0})

    if count <= limit do
      :ok
    else
      retry_after_ms = window_start + window_ms - now
      retry_after_s = max(div(retry_after_ms, 1000), 1)
      {:error, :rate_limited, retry_after_s}
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

    # match spec: [{{key, window_start}, count}] where window_start < cutoff
    match_spec = [{{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}]

    deleted = :ets.select_delete(table, match_spec)

    if deleted > 0 do
      Logger.debug("#{label}: cleaned up #{deleted} expired bucket(s)")
    end

    :ok
  end
end
