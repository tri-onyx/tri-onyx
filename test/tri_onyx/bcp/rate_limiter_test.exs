defmodule TriOnyx.BCP.RateLimiterTest do
  use ExUnit.Case, async: true

  alias TriOnyx.BCP.RateLimiter

  setup do
    table = :"test_bcp_rates_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = RateLimiter.start_link(name: :"rl_#{table}", ets_table: table)
    on_exit(fn -> Process.alive?(pid) && GenServer.stop(pid) end)
    %{table: table}
  end

  describe "check_rate/6" do
    test "allows requests within limit", %{table: table} do
      assert :ok = RateLimiter.check_rate("a", "b", 1, 5, 60_000, table)
      assert :ok = RateLimiter.check_rate("a", "b", 1, 5, 60_000, table)
      assert :ok = RateLimiter.check_rate("a", "b", 1, 5, 60_000, table)
    end

    test "rejects when limit reached", %{table: table} do
      assert :ok = RateLimiter.check_rate("a", "b", 1, 2, 60_000, table)
      assert :ok = RateLimiter.check_rate("a", "b", 1, 2, 60_000, table)
      assert {:error, :rate_limited, _retry} = RateLimiter.check_rate("a", "b", 1, 2, 60_000, table)
    end

    test "different categories are tracked independently", %{table: table} do
      assert :ok = RateLimiter.check_rate("a", "b", 1, 1, 60_000, table)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate("a", "b", 1, 1, 60_000, table)

      # Category 2 still has budget
      assert :ok = RateLimiter.check_rate("a", "b", 2, 1, 60_000, table)
    end

    test "different channel pairs are tracked independently", %{table: table} do
      assert :ok = RateLimiter.check_rate("a", "b", 1, 1, 60_000, table)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate("a", "b", 1, 1, 60_000, table)

      # Different pair still has budget
      assert :ok = RateLimiter.check_rate("a", "c", 1, 1, 60_000, table)
    end

    test "window reset allows new requests", %{table: table} do
      # Use a 1ms window so it expires instantly
      assert :ok = RateLimiter.check_rate("a", "b", 1, 1, 1, table)
      Process.sleep(5)
      assert :ok = RateLimiter.check_rate("a", "b", 1, 1, 1, table)
    end

    test "returns retry_after in seconds", %{table: table} do
      assert :ok = RateLimiter.check_rate("a", "b", 1, 1, 60_000, table)
      assert {:error, :rate_limited, retry_after} = RateLimiter.check_rate("a", "b", 1, 1, 60_000, table)
      assert is_integer(retry_after)
      assert retry_after >= 1
    end
  end

  test "returns :ok when ETS table doesn't exist" do
    assert :ok = RateLimiter.check_rate("a", "b", 1, 5, 60_000, :nonexistent_table)
  end
end
