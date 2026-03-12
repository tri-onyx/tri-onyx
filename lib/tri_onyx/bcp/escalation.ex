defmodule TriOnyx.BCP.Escalation do
  @moduledoc """
  Per-channel escalation state tracking for the Bandwidth-Constrained Protocol.

  Tracks how many times a communication channel has been escalated to a higher
  query category. Each channel has a configurable maximum number of escalations
  (default 2). Cat-2 to Cat-3 escalation requires human approval of the
  escalation decision itself, since Cat-3 allows free-text responses.

  This module is pure functional — no GenServer. State is held by the caller
  (typically the agent session or channel process).
  """

  @type escalation_record :: %{
          from: String.t(),
          to: String.t(),
          old_category: 1 | 2 | 3,
          new_category: 1 | 2 | 3,
          justification: String.t(),
          timestamp: DateTime.t()
        }

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          max: pos_integer(),
          history: [escalation_record()]
        }

  @enforce_keys [:max]
  defstruct count: 0,
            max: 2,
            history: []

  @doc """
  Creates a new escalation state from channel config.

  Accepts a keyword list or map with an optional `:max_escalations` key
  (defaults to 2).
  """
  @spec new(keyword() | map()) :: t()
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    max = Keyword.get(opts, :max_escalations, 2)
    %__MODULE__{max: max}
  end

  def new(opts) when is_map(opts) do
    max = Map.get(opts, :max_escalations, 2)
    %__MODULE__{max: max}
  end

  @doc """
  Requests an escalation from `old_category` to `new_category`.

  Checks that:
  1. The escalation count has not reached the maximum.
  2. The new category is strictly higher than the old category.

  Returns:
  - `{:ok, updated_state}` for escalations that do not require human approval
  - `{:ok, updated_state, :requires_approval}` for Cat-2 to Cat-3 escalations
  - `{:error, :escalation_limit_reached}` if the budget is exhausted
  - `{:error, :invalid_escalation}` if new_category <= old_category
  """
  @spec request_escalation(t(), String.t(), String.t(), %{
          old_category: 1 | 2 | 3,
          new_category: 1 | 2 | 3,
          justification: String.t()
        }) ::
          {:ok, t()}
          | {:ok, t(), :requires_approval}
          | {:error, :escalation_limit_reached | :invalid_escalation}
  def request_escalation(%__MODULE__{} = state, from, to, %{
        old_category: old_cat,
        new_category: new_cat,
        justification: justification
      })
      when is_binary(from) and is_binary(to) and is_binary(justification) do
    cond do
      new_cat <= old_cat ->
        {:error, :invalid_escalation}

      state.count >= state.max ->
        {:error, :escalation_limit_reached}

      true ->
        record = %{
          from: from,
          to: to,
          old_category: old_cat,
          new_category: new_cat,
          justification: justification,
          timestamp: DateTime.utc_now()
        }

        updated = %{
          state
          | count: state.count + 1,
            history: [record | state.history]
        }

        if old_cat == 2 and new_cat == 3 do
          {:ok, updated, :requires_approval}
        else
          {:ok, updated}
        end
    end
  end
end
