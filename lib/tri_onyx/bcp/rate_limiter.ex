defmodule TriOnyx.BCP.RateLimiter do
  @moduledoc """
  Rate limiter for BCP channels.

  Tracks request counts per `{from_agent, to_agent, category}` triple with
  a caller-supplied window. Thin wrapper around `TriOnyx.RateLimiter`.
  """

  alias TriOnyx.RateLimiter

  @ets_table :bcp_rate_limits
  # BCP windows are configured per channel and can be long; keep buckets
  # around for an hour before periodic cleanup reaps them.
  @max_age_ms 3_600_000

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the BCP RateLimiter GenServer.

  ## Options

  - `:name` — GenServer registration name (default: `__MODULE__`)
  - `:ets_table` — override the ETS table name (for testing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts
    |> Keyword.put_new(:name, __MODULE__)
    |> Keyword.put_new(:ets_table, @ets_table)
    |> Keyword.put(:label, "BCP.RateLimiter")
    |> Keyword.put(:max_age_ms, @max_age_ms)
    |> RateLimiter.start_link()
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
    RateLimiter.check_rate(table, {from_agent, to_agent, category}, limit, window_ms)
  end
end
