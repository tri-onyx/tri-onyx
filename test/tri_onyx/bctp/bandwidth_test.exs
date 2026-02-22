defmodule TriOnyx.BCTP.BandwidthTest do
  use ExUnit.Case, async: true

  alias TriOnyx.BCTP.{Bandwidth, Query}

  defp make_budget(opts \\ []) do
    defaults = [max_bits_per_session: 1000.0, max_cat2_queries: 5, max_cat3_queries: 2]
    Bandwidth.new(Keyword.merge(defaults, opts))
  end

  defp cat1_query(fields) do
    {:ok, q} =
      Query.new(%{
        category: 1,
        from: "controller",
        to: "reader",
        session_id: "sess-1",
        fields: fields
      })

    q
  end

  defp cat2_query(questions) do
    {:ok, q} =
      Query.new(%{
        category: 2,
        from: "controller",
        to: "reader",
        session_id: "sess-1",
        questions: questions
      })

    q
  end

  defp cat3_query(max_words) do
    {:ok, q} =
      Query.new(%{
        category: 3,
        from: "controller",
        to: "reader",
        session_id: "sess-1",
        directive: "Summarize",
        max_words: max_words
      })

    q
  end

  describe "new/1" do
    test "creates budget from keyword list" do
      budget = make_budget()
      assert budget.max_bits_per_session == 1000.0
      assert budget.max_cat2_queries == 5
      assert budget.max_cat3_queries == 2
      assert budget.used_bits == 0.0
      assert budget.cat2_count == 0
      assert budget.cat3_count == 0
      assert budget.query_log == []
    end

    test "creates budget from map" do
      budget =
        Bandwidth.new(%{
          max_bits_per_session: 500.0,
          max_cat2_queries: 3,
          max_cat3_queries: 1
        })

      assert budget.max_bits_per_session == 500.0
    end
  end

  describe "compute_bandwidth (via Query)" do
    test "boolean field costs 1 bit" do
      query = cat1_query([%{name: "flag", type: :boolean}])
      assert Query.compute_bandwidth(query) == 1.0
    end

    test "enum field costs log2(N) bits" do
      query = cat1_query([%{name: "color", type: :enum, options: ["red", "green", "blue", "yellow"]}])
      assert_in_delta Query.compute_bandwidth(query), 2.0, 0.001
    end

    test "integer field costs log2(range) bits" do
      query = cat1_query([%{name: "score", type: :integer, min: 0, max: 255}])
      assert_in_delta Query.compute_bandwidth(query), 8.0, 0.001
    end

    test "cat-2 question costs 11 * max_words bits" do
      query = cat2_query([%{name: "answer", format: :short_text, max_words: 10}])
      assert Query.compute_bandwidth(query) == 110.0
    end

    test "cat-3 directive costs 11 * max_words bits" do
      query = cat3_query(20)
      assert Query.compute_bandwidth(query) == 220.0
    end

    test "multiple fields sum correctly" do
      query =
        cat1_query([
          %{name: "a", type: :boolean},
          %{name: "b", type: :boolean},
          %{name: "c", type: :enum, options: ["x", "y"]}
        ])

      # 1 + 1 + log2(2) = 3.0
      assert_in_delta Query.compute_bandwidth(query), 3.0, 0.001
    end
  end

  describe "charge/2" do
    test "successful charge within budget" do
      budget = make_budget()
      query = cat1_query([%{name: "flag", type: :boolean}])

      assert {:ok, updated} = Bandwidth.charge(budget, query)
      assert updated.used_bits == 1.0
      assert query.id in updated.query_log
    end

    test "budget exceeded returns error" do
      budget = make_budget(max_bits_per_session: 5.0)
      query = cat2_query([%{name: "q", format: :short_text, max_words: 10}])

      # 11 * 10 = 110 bits > 5
      assert {:error, :budget_exceeded} = Bandwidth.charge(budget, query)
    end

    test "cat2 count limit returns error" do
      budget = make_budget(max_cat2_queries: 1)
      query = cat2_query([%{name: "q", format: :short_text, max_words: 1}])

      assert {:ok, updated} = Bandwidth.charge(budget, query)
      assert updated.cat2_count == 1

      assert {:error, :cat2_limit} = Bandwidth.charge(updated, query)
    end

    test "cat3 count limit returns error" do
      budget = make_budget(max_cat3_queries: 1)
      query = cat3_query(1)

      assert {:ok, updated} = Bandwidth.charge(budget, query)
      assert updated.cat3_count == 1

      assert {:error, :cat3_limit} = Bandwidth.charge(updated, query)
    end

    test "cat1 queries do not count against cat2/cat3 limits" do
      budget = make_budget(max_cat2_queries: 0, max_cat3_queries: 0)
      query = cat1_query([%{name: "flag", type: :boolean}])

      assert {:ok, updated} = Bandwidth.charge(budget, query)
      assert updated.cat2_count == 0
      assert updated.cat3_count == 0
    end

    test "multiple charges accumulate" do
      budget = make_budget()
      q1 = cat1_query([%{name: "a", type: :boolean}])
      q2 = cat1_query([%{name: "b", type: :boolean}])

      assert {:ok, b1} = Bandwidth.charge(budget, q1)
      assert {:ok, b2} = Bandwidth.charge(b1, q2)
      assert b2.used_bits == 2.0
      assert length(b2.query_log) == 2
    end
  end

  describe "remaining/1" do
    test "returns full budget when unused" do
      budget = make_budget(max_bits_per_session: 100.0)
      assert Bandwidth.remaining(budget) == 100.0
    end

    test "returns difference after charges" do
      budget = make_budget(max_bits_per_session: 100.0)
      query = cat1_query([%{name: "flag", type: :boolean}])

      {:ok, updated} = Bandwidth.charge(budget, query)
      assert Bandwidth.remaining(updated) == 99.0
    end

    test "never returns negative" do
      budget = %{make_budget(max_bits_per_session: 1.0) | used_bits: 5.0}
      assert Bandwidth.remaining(budget) == 0.0
    end
  end
end
