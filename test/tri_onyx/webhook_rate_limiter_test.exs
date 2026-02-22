defmodule TriOnyx.WebhookRateLimiterTest do
  use ExUnit.Case

  alias TriOnyx.WebhookRateLimiter

  setup do
    suffix = :erlang.unique_integer([:positive])
    table_name = :"rate_limit_test_#{suffix}"
    limiter_name = :"limiter_test_#{suffix}"

    {:ok, pid} =
      WebhookRateLimiter.start_link(
        name: limiter_name,
        ets_table: table_name
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    %{table: table_name}
  end

  describe "check_rate/4" do
    test "allows requests under the limit", %{table: table} do
      assert :ok = WebhookRateLimiter.check_rate("ep1", "10.0.0.1", 5, table)
      assert :ok = WebhookRateLimiter.check_rate("ep1", "10.0.0.1", 5, table)
      assert :ok = WebhookRateLimiter.check_rate("ep1", "10.0.0.1", 5, table)
    end

    test "rejects requests over the limit", %{table: table} do
      # Fill up the bucket (limit = 3)
      assert :ok = WebhookRateLimiter.check_rate("ep2", "10.0.0.1", 3, table)
      assert :ok = WebhookRateLimiter.check_rate("ep2", "10.0.0.1", 3, table)
      assert :ok = WebhookRateLimiter.check_rate("ep2", "10.0.0.1", 3, table)

      # Should be rate limited now
      assert {:error, :rate_limited, retry_after} =
               WebhookRateLimiter.check_rate("ep2", "10.0.0.1", 3, table)

      assert is_integer(retry_after)
      assert retry_after > 0
    end

    test "tracks different endpoints independently", %{table: table} do
      # Fill up endpoint A
      for _ <- 1..3 do
        WebhookRateLimiter.check_rate("epA", "10.0.0.1", 3, table)
      end

      assert {:error, :rate_limited, _} =
               WebhookRateLimiter.check_rate("epA", "10.0.0.1", 3, table)

      # Endpoint B should still be allowed
      assert :ok = WebhookRateLimiter.check_rate("epB", "10.0.0.1", 3, table)
    end

    test "tracks different IPs independently", %{table: table} do
      # Fill up IP 10.0.0.1
      for _ <- 1..3 do
        WebhookRateLimiter.check_rate("ep3", "10.0.0.1", 3, table)
      end

      assert {:error, :rate_limited, _} =
               WebhookRateLimiter.check_rate("ep3", "10.0.0.1", 3, table)

      # Different IP should still be allowed
      assert :ok = WebhookRateLimiter.check_rate("ep3", "10.0.0.2", 3, table)
    end

    test "returns :ok when ETS table doesn't exist" do
      assert :ok = WebhookRateLimiter.check_rate("ep", "ip", 5, :nonexistent_table)
    end
  end
end
