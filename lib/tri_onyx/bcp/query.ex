defmodule TriOnyx.BCP.Query do
  @moduledoc """
  Structured query definition for the Bandwidth-Constrained Protocol.

  A query defines the exact shape of information a controller agent may extract
  from a reader agent. Queries are categorized into three tiers of increasing
  bandwidth (and decreasing determinism):

  - **Category 1** — Structured fields (boolean, enum, integer). Fully deterministic
    validation. No free-text.
  - **Category 2** — Semi-structured questions with constrained formats (person_name,
    date, email, short_text, short_list). Word-count enforced, anomaly-detected.
  - **Category 3** — Free-text directive with word limit. Always requires human
    approval.
  """

  @type field_type :: :boolean | :enum | :integer

  @type field :: %{
          name: String.t(),
          type: field_type(),
          options: [String.t()] | nil,
          min: integer() | nil,
          max: integer() | nil
        }

  @type question_format :: :person_name | :date | :email | :short_text | :short_list

  @type question :: %{
          name: String.t(),
          format: question_format(),
          max_words: pos_integer()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          category: 1 | 2 | 3,
          from: String.t(),
          to: String.t(),
          session_id: String.t(),
          context: String.t() | nil,
          fields: [field()] | nil,
          questions: [question()] | nil,
          directive: String.t() | nil,
          max_words: pos_integer() | nil,
          requires_approval: boolean()
        }

  @enforce_keys [:id, :category, :from, :to, :session_id]
  defstruct [
    :id,
    :category,
    :from,
    :to,
    :session_id,
    :context,
    :fields,
    :questions,
    :directive,
    :max_words,
    requires_approval: false
  ]

  @doc """
  Creates a new Query, using the provided `:id` or generating a UUID.
  """
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || generate_id()
    parse(Map.put(attrs, :id, id))
  end

  @doc """
  Parses a map into a Query struct, validating required fields.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)

    with {:ok, category} <- parse_category(attrs),
         {:ok, id} <- require_string(attrs, :id),
         {:ok, from} <- require_string(attrs, :from),
         {:ok, to} <- require_string(attrs, :to),
         {:ok, session_id} <- require_string(attrs, :session_id),
         {:ok, category_fields} <- parse_category_fields(category, attrs) do
      query =
        struct!(
          __MODULE__,
          Map.merge(
            %{
              id: id,
              category: category,
              from: from,
              to: to,
              session_id: session_id,
              context: Map.get(attrs, :context),
              requires_approval: Map.get(attrs, :requires_approval, category == 3)
            },
            category_fields
          )
        )

      {:ok, query}
    end
  end

  @doc """
  Computes the theoretical maximum bandwidth (in bits) for a query.

  - Boolean fields: 1 bit each
  - Enum fields: log2(number of options) bits each
  - Integer fields: log2(max - min + 1) bits each
  - Text-based questions/directives: ~11 bits per word (approximate entropy
    of English text per word)
  """
  @spec compute_bandwidth(t()) :: float()
  def compute_bandwidth(%__MODULE__{category: 1, fields: fields}) when is_list(fields) do
    Enum.reduce(fields, 0.0, fn field, acc ->
      acc + field_bits(field)
    end)
  end

  def compute_bandwidth(%__MODULE__{category: 2, questions: questions}) when is_list(questions) do
    Enum.reduce(questions, 0.0, fn question, acc ->
      acc + 11.0 * question.max_words
    end)
  end

  def compute_bandwidth(%__MODULE__{category: 3, max_words: max_words})
      when is_integer(max_words) do
    11.0 * max_words
  end

  def compute_bandwidth(_), do: 0.0

  # -- Private --

  defp field_bits(%{type: :boolean}), do: 1.0

  defp field_bits(%{type: :enum, options: options}) when is_list(options) do
    case length(options) do
      0 -> 0.0
      1 -> 0.0
      n -> :math.log2(n)
    end
  end

  defp field_bits(%{type: :integer, min: min, max: max})
       when is_integer(min) and is_integer(max) and max >= min do
    range = max - min + 1

    case range do
      1 -> 0.0
      n -> :math.log2(n)
    end
  end

  defp field_bits(_), do: 0.0

  defp parse_category(attrs) do
    case Map.get(attrs, :category) do
      cat when cat in [1, 2, 3] -> {:ok, cat}
      _ -> {:error, "category must be 1, 2, or 3"}
    end
  end

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      val when is_binary(val) and val != "" -> {:ok, val}
      _ -> {:error, "#{key} is required and must be a non-empty string"}
    end
  end

  defp parse_category_fields(1, attrs) do
    fields = Map.get(attrs, :fields, [])

    if is_list(fields) and length(fields) > 0 do
      parsed =
        Enum.map(fields, fn f ->
          f = normalize_keys(f)

          %{
            name: Map.get(f, :name),
            type: parse_field_type(Map.get(f, :type)),
            options: Map.get(f, :options),
            min: Map.get(f, :min),
            max: Map.get(f, :max)
          }
        end)

      {:ok, %{fields: parsed}}
    else
      {:error, "category 1 queries require at least one field"}
    end
  end

  defp parse_category_fields(2, attrs) do
    questions = Map.get(attrs, :questions, [])

    if is_list(questions) and length(questions) > 0 do
      parsed =
        Enum.map(questions, fn q ->
          q = normalize_keys(q)

          %{
            name: Map.get(q, :name),
            format: parse_question_format(Map.get(q, :format)),
            max_words: Map.get(q, :max_words, 10)
          }
        end)

      {:ok, %{questions: parsed}}
    else
      {:error, "category 2 queries require at least one question"}
    end
  end

  defp parse_category_fields(3, attrs) do
    directive = Map.get(attrs, :directive)
    max_words = Map.get(attrs, :max_words)

    if is_binary(directive) and directive != "" and is_integer(max_words) and max_words > 0 do
      {:ok, %{directive: directive, max_words: max_words}}
    else
      {:error, "category 3 queries require a directive string and positive max_words integer"}
    end
  end

  defp parse_field_type(:boolean), do: :boolean
  defp parse_field_type("boolean"), do: :boolean
  defp parse_field_type(:enum), do: :enum
  defp parse_field_type("enum"), do: :enum
  defp parse_field_type(:integer), do: :integer
  defp parse_field_type("integer"), do: :integer
  defp parse_field_type(other), do: other

  defp parse_question_format(:person_name), do: :person_name
  defp parse_question_format("person_name"), do: :person_name
  defp parse_question_format(:date), do: :date
  defp parse_question_format("date"), do: :date
  defp parse_question_format(:email), do: :email
  defp parse_question_format("email"), do: :email
  defp parse_question_format(:short_text), do: :short_text
  defp parse_question_format("short_text"), do: :short_text
  defp parse_question_format(:short_list), do: :short_list
  defp parse_question_format("short_list"), do: :short_list
  defp parse_question_format(other), do: other

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} when is_atom(k) -> {k, v}
    end)
  rescue
    ArgumentError -> map
  end

  defp generate_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c, d, e]
    )
    |> to_string()
    |> String.downcase()
  end
end
