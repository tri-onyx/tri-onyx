defmodule TriOnyx.BCTP.Bandwidth do
  @moduledoc """
  Bandwidth budget tracking for BCTP sessions.

  Each inter-agent communication channel has a bandwidth budget that limits
  the total information that can flow through it. The budget tracks:

  - Total bits used vs. maximum allowed per session
  - Category-2 query count (semi-structured responses are more expensive to audit)
  - Category-3 query count (free-text always requires human approval)

  The gateway charges the budget *before* executing a query. If the budget
  would be exceeded, the query is rejected.
  """

  alias TriOnyx.BCTP.Query

  @type t :: %__MODULE__{
          max_bits_per_session: float(),
          max_cat2_queries: non_neg_integer(),
          max_cat3_queries: non_neg_integer(),
          used_bits: float(),
          cat2_count: non_neg_integer(),
          cat3_count: non_neg_integer(),
          query_log: [String.t()]
        }

  @enforce_keys [:max_bits_per_session, :max_cat2_queries, :max_cat3_queries]
  defstruct [
    :max_bits_per_session,
    :max_cat2_queries,
    :max_cat3_queries,
    used_bits: 0.0,
    cat2_count: 0,
    cat3_count: 0,
    query_log: []
  ]

  @doc """
  Creates a new bandwidth budget from a keyword list or map.

  Required keys: :max_bits_per_session, :max_cat2_queries, :max_cat3_queries
  """
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end

  def new(opts) when is_map(opts) do
    struct!(
      __MODULE__,
      Map.take(opts, [:max_bits_per_session, :max_cat2_queries, :max_cat3_queries])
    )
  end

  @doc """
  Charges a query against the budget.

  Computes the bandwidth cost via `Query.compute_bandwidth/1` and checks:
  1. Total bits would not exceed max_bits_per_session
  2. Category-2 count would not exceed max_cat2_queries
  3. Category-3 count would not exceed max_cat3_queries

  Returns `{:ok, updated_budget}` or `{:error, reason}`.
  """
  @spec charge(t(), Query.t()) ::
          {:ok, t()} | {:error, :budget_exceeded | :cat2_limit | :cat3_limit}
  def charge(%__MODULE__{} = budget, %Query{} = query) do
    bits = Query.compute_bandwidth(query)

    with :ok <- check_category_limit(budget, query),
         :ok <- check_bits(budget, bits) do
      updated =
        budget
        |> Map.update!(:used_bits, &(&1 + bits))
        |> increment_category(query.category)
        |> Map.update!(:query_log, &[query.id | &1])

      {:ok, updated}
    end
  end

  @doc """
  Returns the remaining bits in the budget.
  """
  @spec remaining(t()) :: float()
  def remaining(%__MODULE__{max_bits_per_session: max, used_bits: used}) do
    max(max - used, 0.0)
  end

  # -- Private --

  defp check_bits(%__MODULE__{max_bits_per_session: max, used_bits: used}, bits) do
    if used + bits <= max do
      :ok
    else
      {:error, :budget_exceeded}
    end
  end

  defp check_category_limit(%__MODULE__{cat2_count: count, max_cat2_queries: max}, %Query{
         category: 2
       }) do
    if count < max, do: :ok, else: {:error, :cat2_limit}
  end

  defp check_category_limit(%__MODULE__{cat3_count: count, max_cat3_queries: max}, %Query{
         category: 3
       }) do
    if count < max, do: :ok, else: {:error, :cat3_limit}
  end

  defp check_category_limit(_, _), do: :ok

  defp increment_category(budget, 2), do: Map.update!(budget, :cat2_count, &(&1 + 1))
  defp increment_category(budget, 3), do: Map.update!(budget, :cat3_count, &(&1 + 1))
  defp increment_category(budget, _), do: budget
end
