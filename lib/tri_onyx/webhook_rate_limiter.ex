defmodule TriOnyx.WebhookRateLimiter do
  @moduledoc """
  Rate limiter for webhook endpoints.

  Tracks request counts per `{endpoint_id, source_ip}` pair over a fixed
  60-second window. Thin wrapper around `TriOnyx.RateLimiter`.
  """

  alias TriOnyx.RateLimiter

  @ets_table :webhook_rate_limits
  @window_ms 60_000

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the WebhookRateLimiter GenServer.

  ## Options

  - `:name` — GenServer registration name (default: `__MODULE__`)
  - `:ets_table` — override the ETS table name (for testing)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts
    |> Keyword.put_new(:name, __MODULE__)
    |> Keyword.put_new(:ets_table, @ets_table)
    |> Keyword.put(:label, "WebhookRateLimiter")
    |> Keyword.put(:max_age_ms, @window_ms)
    |> RateLimiter.start_link()
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
    RateLimiter.check_rate(table, {endpoint_id, source_ip}, limit, @window_ms)
  end
end
