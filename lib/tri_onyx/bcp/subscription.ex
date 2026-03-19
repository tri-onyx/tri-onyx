defmodule TriOnyx.BCP.Subscription do
  @moduledoc """
  Stores and retrieves BCP subscription specs declared in Controller agent definitions.

  Subscriptions are static — declared in YAML, loaded at boot, never created at runtime.
  Stored in an ETS table keyed by {reader_name, subscription_id} for O(1) lookup
  when a Reader publishes.
  """

  alias TriOnyx.BCP.Query

  @subscriptions_table :bcp_subscriptions

  @type t :: %__MODULE__{
          id: String.t(),
          controller: String.t(),
          reader: String.t(),
          category: 1..3,
          fields: [map()] | nil,
          questions: [map()] | nil,
          directive: String.t() | nil,
          max_words: pos_integer() | nil
        }

  @enforce_keys [:id, :controller, :reader, :category]
  defstruct [:id, :controller, :reader, :category, :fields, :questions, :directive, :max_words]

  @doc "Ensures the ETS table exists."
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@subscriptions_table) do
      :undefined ->
        :ets.new(@subscriptions_table, [:set, :public, :named_table])
        :ok

      _ref ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Clears all subscriptions and registers new ones."
  @spec register_all([t()]) :: :ok
  def register_all(subscriptions) do
    ensure_table()
    :ets.delete_all_objects(@subscriptions_table)

    Enum.each(subscriptions, fn sub ->
      :ets.insert(@subscriptions_table, {{sub.reader, sub.id}, sub})
    end)

    :ok
  end

  @doc "Look up a subscription by reader name and subscription ID."
  @spec lookup(String.t(), String.t()) :: {:ok, t()} | :error
  def lookup(reader_name, subscription_id) do
    ensure_table()

    case :ets.lookup(@subscriptions_table, {reader_name, subscription_id}) do
      [{_key, sub}] -> {:ok, sub}
      [] -> :error
    end
  end

  @doc "Get all subscriptions targeting a given reader."
  @spec for_reader(String.t()) :: [t()]
  def for_reader(reader_name) do
    ensure_table()

    :ets.match_object(@subscriptions_table, {{reader_name, :_}, :_})
    |> Enum.map(fn {_key, sub} -> sub end)
  end

  @doc "Convert a subscription to an ephemeral BCP.Query for validation."
  @spec to_query(t()) :: {:ok, Query.t()} | {:error, term()}
  def to_query(%__MODULE__{} = sub) do
    attrs = %{
      category: sub.category,
      from: sub.controller,
      to: sub.reader,
      session_id:
        "sub-#{sub.id}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    }

    attrs = if sub.fields, do: Map.put(attrs, :fields, sub.fields), else: attrs
    attrs = if sub.questions, do: Map.put(attrs, :questions, sub.questions), else: attrs
    attrs = if sub.directive, do: Map.put(attrs, :directive, sub.directive), else: attrs
    attrs = if sub.max_words, do: Map.put(attrs, :max_words, sub.max_words), else: attrs

    Query.new(attrs)
  end
end
