defmodule TriOnyx.RateLimiterTest do
  use ExUnit.Case

  alias TriOnyx.RateLimiter

  setup do
    suffix = :erlang.unique_integer([:positive])
    table = :"rate_limiter_test_#{suffix}"
    name = :"rate_limiter_test_server_#{suffix}"

    {:ok, pid} = RateLimiter.start_link(name: name, ets_table: table, max_age_ms: 60_000)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    %{table: table}
  end

  describe "check_rate/4" do
    test "allows requests under the limit", %{table: table} do
      assert :ok = RateLimiter.check_rate(table, "k", 3, 60_000)
      assert :ok = RateLimiter.check_rate(table, "k", 3, 60_000)
      assert :ok = RateLimiter.check_rate(table, "k", 3, 60_000)
    end

    test "rejects requests over the limit", %{table: table} do
      assert :ok = RateLimiter.check_rate(table, "k", 2, 60_000)
      assert :ok = RateLimiter.check_rate(table, "k", 2, 60_000)
      assert {:error, :rate_limited, retry_after} = RateLimiter.check_rate(table, "k", 2, 60_000)
      assert is_integer(retry_after)
      assert retry_after > 0
    end

    test "different keys are tracked independently", %{table: table} do
      assert :ok = RateLimiter.check_rate(table, "a", 1, 60_000)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate(table, "a", 1, 60_000)
      assert :ok = RateLimiter.check_rate(table, "b", 1, 60_000)
    end

    test "returns :ok when the ETS table doesn't exist" do
      assert :ok = RateLimiter.check_rate(:nonexistent_rate_limiter_table, "k", 1, 60_000)
    end

    test "a fresh window allows requests again after the old one elapses", %{table: table} do
      assert :ok = RateLimiter.check_rate(table, "k", 1, 10)
      assert {:error, :rate_limited, _} = RateLimiter.check_rate(table, "k", 1, 10)
      Process.sleep(20)
      assert :ok = RateLimiter.check_rate(table, "k", 1, 10)
    end

    test "a concurrent burst landing exactly as a window expires cannot exceed the limit", %{
      table: table
    } do
      # Security property: check_rate/4 must never let more than `limit`
      # callers through per window, even when a burst of concurrent
      # requests arrives at the exact instant an old window has just
      # elapsed. A prior implementation kept a single {key, count,
      # bucket_start} bucket and reset it via a *separate*, non-atomic
      # :ets.insert/2 once bucket_start was found stale — so every caller
      # in such a burst could independently observe the same stale
      # bucket_start, independently decide to reset, and independently
      # write count = 1 and return :ok, letting the whole burst through
      # regardless of `limit`. This repeats the experiment many times
      # (fresh key, tiny window) so real scheduler concurrency gets many
      # chances to hit that window-boundary race if it exists.
      limit = 1
      window_ms = 10
      burst_size = 40
      trials = 30
      parent = self()

      max_ok_in_a_trial =
        1..trials
        |> Enum.map(fn trial ->
          key = "burst-#{trial}"
          assert :ok = RateLimiter.check_rate(table, key, limit, window_ms)
          # Let the window elapse before the synchronized burst arrives.
          Process.sleep(15)

          # Spawn every racer first and have it block on a barrier so all
          # `burst_size` processes are already alive and scheduled before any
          # of them calls check_rate/4 — releasing them together (rather
          # than spawning-then-immediately-calling) maximizes how many
          # genuinely overlap inside the vulnerable window.
          tasks =
            for _ <- 1..burst_size do
              Task.async(fn ->
                send(parent, {:ready, self()})
                receive do: (:go -> :ok)
                RateLimiter.check_rate(table, key, limit, window_ms)
              end)
            end

          for _ <- 1..burst_size, do: receive(do: ({:ready, _pid} -> :ok))
          Enum.each(tasks, fn %Task{pid: pid} -> send(pid, :go) end)

          tasks
          |> Enum.map(&Task.await(&1, 1_000))
          |> Enum.count(&(&1 == :ok))
        end)
        |> Enum.max()

      assert max_ok_in_a_trial <= limit,
             "a burst of #{burst_size} concurrent requests arriving right as a " <>
               "rate-limit window expired got #{max_ok_in_a_trial} requests accepted " <>
               "in the worst trial, expected at most #{limit} — concurrent callers " <>
               "must never both observe the same expired window and both be let " <>
               "through by the reset"
    end
  end
end
